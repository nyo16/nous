defmodule Nous.Tools.RunCode do
  @moduledoc """
  Code Mode's transport tool: runs a model-authored program that calls tools.

  One `run_code` call replaces a chain of individual tool calls — the program
  loops, branches and fans out in a single round trip, and only what it logs or
  returns re-enters the conversation. The tools it may call are declared in the
  SDK carried in this tool's description (see `Nous.CodeMode.Sdk`), and are
  reached through bindings derived from the same permission policy that governs
  a direct call (`Nous.CodeMode.bindings/4`).

  ## The runtime provider

  `Nous.CodeRuntime.JS` ships in this repository and runs programs in an
  embedded V8 isolate. It needs the optional `:tyrex` dependency:

      {:tyrex, "~> 0.4"}

      config :nous, :code_runtime, {Nous.CodeRuntime.JS, timeout_ms: 30_000}

  Any other provider behind `Nous.CodeRuntime` works the same way. With none
  configured this tool returns a clear error naming the configuration it needs;
  it does not crash, and it does not pretend to have run anything. `mode: :both`
  quietly behaves as `:native` when nothing is configured, so that error is only
  reachable when an operator explicitly asked for `mode: :code`.

  ## Approval is per sub-call, not per program

  Approving a `run_code` call approves running *that program*. It does not
  approve whatever the program then decides to call: each sub-call to a tool with
  `requires_approval: true` consults the approval handler on its own, with the
  real tool name and the real arguments. With no handler in the context such a
  tool is refused rather than run — the same default-deny `Nous.ToolExecutor`
  applies at every other entry point.

  ## Result shape

  A run that finishes returns `%{logs: [String.t()], result: json}`. A run that
  fails returns `%{logs: [String.t()], error: %{kind: String.t(), message:
  String.t()}}` — failure is data, not a tool error, because a program that
  throws is the normal case: the model reads the failure and writes a better
  program. `{:error, _}` is reserved for a call that never ran at all — no
  provider, a missing `description`, a request the seam refused.

  Logs are returned whether the run succeeded or failed, so a program killed by
  its deadline still reports what it managed to say.

  ## Sub-calls go through one lane

  Every tool call the program makes is submitted to a `Nous.CodeMode.Scheduler`
  started for this run and torn down with it: one driver lane with a
  `max_parallel` ceiling, an exclusivity barrier for tools that do not declare
  themselves `concurrency_safe?/1`, and two independent argument snapshots per
  call. The bindings never reach `Nous.ToolExecutor` on their own.

  The scheduler records each sub-dispatch as a bookkeeping `:tool_call` event the
  moment it starts. A tool is handed a `%Nous.RunContext{}`, which carries no
  session log, so those events leave here as `:log_event` operations on a
  `Nous.Tool.ContextUpdate` — this tool's third return shape — and the agent
  runner appends them to the real `Nous.Agent.Context`. Being bookkeeping, they
  project to no message: a program making forty tool calls adds forty audit
  records and nothing whatsoever to what the model reads.

  ## Approval and audit

  `description` is required and must be non-empty. It is what a human reads in
  an approval prompt and what an audit log records; an empty one turns both into
  a shrug, so it is rejected. The tool's own `requires_approval` is false —
  gate it through `Nous.Permissions` (it is an `:execute`-category tool) rather
  than here, because every tool the program calls is *also* gated, and a second
  unconditional prompt in front of the first buys nothing.
  """

  use Nous.Tool.Schema

  alias Nous.CodeMode
  alias Nous.CodeMode.Scheduler
  alias Nous.CodeRuntime
  alias Nous.CodeRuntime.{Failure, Request, Result}
  alias Nous.RunContext
  alias Nous.Tool.ContextUpdate

  require Logger

  tool "run_code",
    description:
      "Run a program that calls tools. Prefer this over a chain of individual tool calls " <>
        "when the work loops, branches, or fans out: the whole program runs in one round " <>
        "trip and only what it logs or returns comes back. Tools are called through the " <>
        "`tools` object declared below.",
    category: :execute do
    param(:code, :string,
      required: true,
      doc:
        "The program to run, in the language declared by the SDK below. Return the value you " <>
          "want to see; log anything else you need to read."
    )

    param(:description, :string,
      required: true,
      doc:
        "One sentence, in plain language, describing what this program does. A human may read " <>
          "it before approving the call, and it is recorded in the audit log."
    )
  end

  @impl Nous.Tool.Behaviour
  def execute(ctx, args), do: run(ctx, args, [])

  @doc """
  Run a program, with the tool set and dispatch this call is scoped to.

  `Nous.CodeMode.run_code_tool/3` builds the closure that supplies `opts`; the
  bare `execute/2` above is the same call with none, which is what a direct
  `Nous.ToolExecutor.execute/3` outside the runner gets.

  Returns `{:ok, output, %Nous.Tool.ContextUpdate{}}` when the program made at
  least one sub-call, carrying one `:log_event` operation per sub-dispatch in
  submission order; a program that called nothing returns the plain `{:ok,
  output}`, because an update with no operations is noise.

  ## Options

    * `:tools` — every tool in scope *before* the permission policy filtered
      it. Granted ones become real closures, denied ones error stubs.
    * `:policy` — the `Nous.Permissions.Policy` that decides which is which.
    * `:dispatch` — a `t:Nous.CodeMode.dispatch/0` the scheduler runs sub-calls
      through; defaults to `Nous.CodeMode.direct_dispatch/3`. It replaces what
      the lane calls, never the lane itself.
    * `:call_id` — the model's tool-call id, so each sub-dispatch event
      correlates back to this call. Defaults to a minted per-run token.
    * `:runtime` — `{module, config}` overriding `config :nous, :code_runtime`.
  """
  @spec run(RunContext.t(), map(), keyword()) ::
          {:ok, map()} | {:ok, map(), ContextUpdate.t()} | {:error, String.t()}
  def run(%RunContext{} = ctx, args, opts) when is_map(args) and is_list(opts) do
    with {:ok, program} <- fetch_program(args),
         {:ok, description} <- fetch_description(args),
         {:ok, {module, config}} <- resolve_runtime(opts),
         {:ok, scheduler} <- start_scheduler(opts) do
      # `after`, not a stop on the success path only: a provider that raises, a
      # program that tears its own run down, and a caught exit must all leave no
      # lane behind, because one leaked GenServer per run_code call is one per
      # model turn. The single teardown `after` cannot reach — `Nous.ToolExecutor`
      # killing this process when the tool times out — is covered by the link
      # `Scheduler.start_link/1` made instead.
      try do
        outcome =
          with {:ok, request} <- build_request(program, ctx, opts, scheduler),
               {:ok, ref} <- start_run(module, request, config) do
            Logger.info("run_code: #{description}")
            collect(module, ref)
          end

        with_sub_dispatch_events(outcome, scheduler)
      after
        Scheduler.stop(scheduler)
      end
    end
  end

  # ---------------------------------------------------------------------------

  defp fetch_program(args) do
    case fetch(args, "code", :code) do
      program when is_binary(program) ->
        {:ok, program}

      _other ->
        {:error, "run_code requires a `code` parameter containing the program to run."}
    end
  end

  # Presence is already enforced by the JSON schema; emptiness is not, and an
  # empty description is exactly as useless as a missing one to the human it
  # exists for.
  defp fetch_description(args) do
    case fetch(args, "description", :description) do
      description when is_binary(description) ->
        if String.trim(description) == "" do
          {:error,
           "run_code requires a non-empty `description`: one sentence describing what the " <>
             "program does, for the approval prompt and the audit log."}
        else
          {:ok, description}
        end

      _other ->
        {:error,
         "run_code requires a `description` parameter: one sentence describing what the " <>
           "program does, for the approval prompt and the audit log."}
    end
  end

  defp resolve_runtime(opts) do
    case Keyword.get(opts, :runtime) do
      {module, config} when is_atom(module) -> {:ok, {module, config}}
      nil -> CodeMode.runtime()
      other -> {:error, "invalid :runtime option #{inspect(other)}; expected {module, config}"}
    end
  end

  # The lane every sub-call goes through. `start_link`, not a supervised child:
  # the lane's lifetime IS this call's, and the link is what covers the teardown
  # an `after` clause cannot (an untrappable kill from the tool executor).
  defp start_scheduler(opts) do
    case Scheduler.start_link(
           dispatch: Keyword.get(opts, :dispatch) || (&CodeMode.direct_dispatch/3),
           call_id: Keyword.get(opts, :call_id) || run_correlation_id()
         ) do
      {:ok, scheduler} ->
        {:ok, scheduler}

      {:error, {:contract, message}} ->
        {:error, "run_code could not start its sub-call scheduler: #{message}"}

      {:error, reason} ->
        {:error, "run_code could not start its sub-call scheduler: #{inspect(reason)}"}
    end
  end

  # A sub-dispatch event's correlation id names its parent call, and this tool
  # cannot see the model's tool-call id: `Nous.ToolExecutor` hands a tool its
  # arguments and a `%RunContext{}`, never the call they came from. A per-run
  # token keeps two `run_code` calls in the same turn from both minting
  # `"code:0"`, which is what leaving `:call_id` nil would do.
  defp run_correlation_id do
    "run_code-" <> (6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  # The bridge from the scheduler's audit trail to the session log. There is no
  # `Nous.Agent.Context` at this depth to append to, so the events ride out as
  # `:log_event` operations and the runner appends them where a log exists.
  defp with_sub_dispatch_events({:ok, output}, scheduler) do
    case Scheduler.logged_events(scheduler) do
      [] -> {:ok, output}
      events -> {:ok, output, Enum.reduce(events, ContextUpdate.new(), &log_event/2)}
    end
  end

  # Reachable: a provider may call a binding from `start_run/2` and then refuse
  # the request. `{:error, _}` has no third slot to carry events in, so name what
  # is being lost rather than dropping an audit trail in silence.
  defp with_sub_dispatch_events({:error, _reason} = error, scheduler) do
    case Scheduler.logged_events(scheduler) do
      [] ->
        error

      events ->
        Logger.warning(
          "run_code failed after #{length(events)} sub-dispatch(es) " <>
            "(#{Enum.map_join(events, ", ", fn {_type, data} -> data.name end)}); their " <>
            "session events are dropped: a failed run_code returns no context update"
        )

        error
    end
  end

  defp log_event({type, data}, update), do: ContextUpdate.log_event(update, type, data)

  defp build_request(program, ctx, opts, scheduler) do
    bindings =
      CodeMode.bindings(
        Keyword.get(opts, :tools, []),
        Keyword.get(opts, :policy),
        ctx,
        dispatch: Scheduler.dispatch_fun(scheduler)
      )

    case Request.new(program, bindings, self()) do
      {:ok, request} -> {:ok, request}
      {:error, {:contract, message}} -> {:error, "run_code could not build a request: #{message}"}
    end
  end

  defp start_run(module, request, config) do
    case module.start_run(request, config) do
      {:ok, ref} ->
        {:ok, ref}

      {:error, {:contract, message}} ->
        {:error, "the code runtime refused the request: #{message}"}

      other ->
        {:error,
         "code runtime #{inspect(module)} returned #{inspect(other)} from start_run/2; " <>
           "expected {:ok, ref} or {:error, {:contract, message}}"}
    end
  end

  defp collect(module, ref) do
    case CodeRuntime.await(ref, CodeMode.await_timeout_ms()) do
      {:ok, %Result{error: nil} = result} ->
        {:ok, %{logs: result.logs, result: result.value}}

      {:ok, %Result{error: %Failure{} = failure} = result} ->
        {:ok,
         %{logs: result.logs, error: %{kind: to_string(failure.kind), message: failure.message}}}

      {:error, :timeout} ->
        # The receive gave up; the run may not have. Cancelling is the whole
        # difference between a deadline and a caller that stopped listening.
        module.cancel(ref, :timeout)

        {:ok,
         %{
           logs: [],
           error: %{
             kind: "timeout",
             message: "the program did not finish within #{CodeMode.await_timeout_ms()}ms"
           }
         }}
    end
  end

  # Arguments arrive string-keyed from a provider and may be atom-keyed from an
  # internal caller. Both keys are literals here — nothing builds an atom from
  # a map the model filled in.
  defp fetch(args, string_key, atom_key) do
    case Map.fetch(args, string_key) do
      {:ok, value} -> value
      :error -> Map.get(args, atom_key)
    end
  end
end
