defmodule Nous.Tools.RunCode do
  @moduledoc """
  Code Mode's transport tool: runs a model-authored program that calls tools.

  One `run_code` call replaces a chain of individual tool calls — the program
  loops, branches and fans out in a single round trip, and only what it logs or
  returns re-enters the conversation. The tools it may call are declared in the
  SDK carried in this tool's description (see `Nous.CodeMode.Sdk`), and are
  reached through bindings derived from the same permission policy that governs
  a direct call (`Nous.CodeMode.bindings/4`).

  ## No provider configured

  Phase C of the Code Mode plan — the runtime provider — is blocked on an
  upstream change, so **this repository ships no provider today**. With none
  configured this tool returns a clear error naming the configuration it needs;
  it does not crash, and it does not pretend to have run anything:

      config :nous, :code_runtime, {MyApp.CodeRuntime, budget_ms: 5_000}

  `Nous.CodeMode` accounts for that state too: `mode: :both` quietly behaves as
  `:native` when nothing is configured, so this error is only reachable when an
  operator explicitly asked for `mode: :code`.

  ## Result shape

  A run that finishes returns `%{logs: [String.t()], result: json}`. A run that
  fails returns `%{logs: [String.t()], error: %{kind: String.t(), message:
  String.t()}}` — failure is data, not a tool error, because a program that
  throws is the normal case: the model reads the failure and writes a better
  program. `{:error, _}` is reserved for a call that never ran at all — no
  provider, a missing `description`, a request the seam refused.

  Logs are returned whether the run succeeded or failed, so a program killed by
  its deadline still reports what it managed to say.

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
  alias Nous.CodeRuntime
  alias Nous.CodeRuntime.{Failure, Request, Result}
  alias Nous.RunContext

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

  ## Options

    * `:tools` — every tool in scope *before* the permission policy filtered
      it. Granted ones become real closures, denied ones error stubs.
    * `:policy` — the `Nous.Permissions.Policy` that decides which is which.
    * `:dispatch` — a `t:Nous.CodeMode.dispatch/0` for sub-calls; defaults to a
      direct tool execution.
    * `:runtime` — `{module, config}` overriding `config :nous, :code_runtime`.
  """
  @spec run(RunContext.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(%RunContext{} = ctx, args, opts) when is_map(args) and is_list(opts) do
    with {:ok, program} <- fetch_program(args),
         {:ok, description} <- fetch_description(args),
         {:ok, {module, config}} <- resolve_runtime(opts),
         {:ok, request} <- build_request(program, ctx, opts),
         {:ok, ref} <- start_run(module, request, config) do
      Logger.info("run_code: #{description}")
      collect(module, ref)
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

  defp build_request(program, ctx, opts) do
    bindings =
      CodeMode.bindings(
        Keyword.get(opts, :tools, []),
        Keyword.get(opts, :policy),
        ctx,
        dispatch: Keyword.get(opts, :dispatch)
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
