defmodule Nous.CodeRuntime do
  @moduledoc """
  Runs a model-authored *program* that calls tools, instead of a chain of
  individual tool calls.

  A program can loop, branch and fan out in one round trip. The substrate that
  executes it is a provider behind this behaviour, and the behaviour exists
  *before* any provider precisely so the choice of substrate is reversible: the
  spike that evaluated wasm found working mechanisms but a ~1.9 s per-run
  compilation floor, and an out-of-process or embedded JS runtime has a different
  cost and isolation profile again. None of that changes the shape below.

  ## Shape

      {:ok, request} = Nous.CodeRuntime.Request.new(program, bindings, self())
      {:ok, ref} = MyProvider.start_run(request, config)
      receive do
        {:code_run, ^ref, %Nous.CodeRuntime.Result{} = result} -> result
      end

  ## Two rules that are the whole point

  **Failure is a field, never a raise.** `c:start_run/2` returns
  `{:error, {:contract, message}}` for *seam misuse only* — a disposed runtime, a
  malformed binding, a program that is not a string. Everything the program itself
  does, including throwing, looping until the deadline, flooding output, or dying
  with its substrate, arrives as `%Result{error: %Failure{}}`. Running
  model-authored code that fails is the normal case, not an exception: the model
  reads the failure and writes a better program.

  **The request carries no tuning knobs.** Budgets — wall clock, memory,
  instruction count — are provider configuration, validated when the provider is
  configured. A program cannot ask for a longer deadline for itself, and neither
  can a caller that a later refactor lets the model influence.

  ## What a provider owes the caller

    * a real kill. A deadline that leaves a program running is not a deadline, and
      "the caller stopped waiting" is not the same as "the work stopped". Whether
      that is achievable is a property of the substrate, and a provider that
      cannot do it MUST say so in its own moduledoc rather than implying it can.
    * eager log streaming, so a killed run still reports what it managed to say.
    * bindings called with the caller's authority and nothing more. Bindings are
      derived from `Nous.Permissions.filter_tools/2`; a provider must not offer the
      guest any other route into Elixir. A substrate whose guest can reach an
      arbitrary-module dispatch function has to have that route removed before any
      model-authored code runs, because it bypasses permissions, approval and
      every path guard at once.
  """

  alias Nous.CodeRuntime.{Request, Result}

  @typedoc """
  Opaque handle for one run, returned by `c:start_run/2` and accepted by
  `c:cancel/2`.
  """
  @type ref :: term()

  @typedoc """
  Provider configuration. Its shape belongs to the provider, which validates it.
  """
  @type config :: term()

  @typedoc """
  Seam misuse. Never used for anything the program did.
  """
  @type contract_error :: {:contract, String.t()}

  @doc """
  The language a program is written in, e.g. `"javascript"`.

  Used to pick the SDK generator and to tell the model what to write, so it must
  name the language as the model knows it, not the substrate.
  """
  @callback language(config()) :: String.t()

  @doc """
  A short, honest description of the isolation the substrate provides, e.g.
  `"wasm component, no filesystem or network"` or
  `"embedded V8 isolate, I/O denied, no execution interrupt"`.

  This is surfaced to operators. Overstating it here is worse than having weak
  isolation, because it is what somebody will read before deciding what to let an
  agent do.
  """
  @callback isolation(config()) :: String.t()

  @doc """
  Start a run. Returns a `ref` immediately; the result is delivered to
  `request.owner` as `{:code_run, ref, %Nous.CodeRuntime.Result{}}`.

  Returns `{:error, {:contract, _}}` only for seam misuse.
  """
  @callback start_run(Request.t(), config()) :: {:ok, ref()} | {:error, contract_error()}

  @doc """
  Cancel a run. Idempotent, and safe to call after the run has finished.

  The owner still receives a result — a cancelled run reports
  `%Failure{kind: :abort}` — because a caller that has already committed to
  waiting for one message should not have to special-case cancellation.
  """
  @callback cancel(ref(), reason :: term()) :: :ok

  @doc """
  Await a result for `ref`, for callers that would rather block than receive.

  Returns `{:error, :timeout}` if nothing arrives in `timeout` ms. That is a
  *receive* timeout and says nothing about the run, which may still be going:
  cancel it if you are giving up.
  """
  @spec await(ref(), timeout()) :: {:ok, Result.t()} | {:error, :timeout}
  def await(ref, timeout \\ 30_000) do
    receive do
      {:code_run, ^ref, %Result{} = result} -> {:ok, result}
    after
      timeout -> {:error, :timeout}
    end
  end
end
