defmodule Nous.CodeRuntime.Failure do
  @moduledoc """
  Why a program did not produce a value.

  A failure is **data**, never an exception. A program that throws, loops forever,
  floods stdout, or dies with its substrate is a normal outcome of running
  model-authored code: the model gets told what happened and writes a better
  program. Raising would make the tool call an error and lose that loop.

  The `kind`s are distinct because the model — and the operator reading a log —
  can act differently on each:

    * `:exception` — the program raised. Its own bug; the message is the guest's.
    * `:timeout` — the wall-clock budget expired. Possibly an infinite loop,
      possibly just slow; the program ran and may have had side effects.
    * `:abort` — cancelled from outside (`c:Nous.CodeRuntime.cancel/2`), e.g. the
      agent run was cancelled. Not the program's fault.
    * `:substrate_exit` — the runtime died underneath us. Ours to fix, not the
      model's, and the one kind that should page somebody.
    * `:invalid_output` — the program returned something unrepresentable.
    * `:output_limit` — it produced more output than the ledger allows. The
      retained prefix is still in `Result.logs`, because truncated evidence beats
      none.
  """

  alias __MODULE__

  @type kind ::
          :exception
          | :timeout
          | :abort
          | :substrate_exit
          | :invalid_output
          | :output_limit

  @type t :: %Failure{kind: kind(), message: String.t()}

  @enforce_keys [:kind, :message]
  defstruct [:kind, :message]

  @kinds [:exception, :timeout, :abort, :substrate_exit, :invalid_output, :output_limit]

  @doc """
  Every failure kind.
  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Build a failure. Unknown kinds are rejected at construction, where the bug is,
  rather than surfacing as an unmatched clause somewhere downstream.
  """
  @spec new(kind(), String.t()) :: t()
  def new(kind, message) when kind in @kinds and is_binary(message) do
    %Failure{kind: kind, message: message}
  end
end

defmodule Nous.CodeRuntime.Result do
  @moduledoc """
  What a program produced.

  `value` is the program's return value, already decoded. `logs` are its output
  lines in order. `error` is `nil` on success, otherwise a
  `Nous.CodeRuntime.Failure`.

  **`logs` are populated even when `error` is set.** A program that printed six
  lines and then looped forever until the deadline has told you where it got to,
  and throwing that away in favour of a bare `:timeout` is how a debuggable
  failure becomes a mystery. Providers must stream output eagerly rather than
  collecting it at the end, or a killed run loses everything it said.
  """

  alias Nous.CodeRuntime.Failure
  alias __MODULE__

  @type t :: %Result{
          value: term(),
          logs: [String.t()],
          error: Failure.t() | nil
        }

  defstruct value: nil, logs: [], error: nil

  @doc """
  A successful result.
  """
  @spec ok(term(), [String.t()]) :: t()
  def ok(value, logs \\ []) when is_list(logs) do
    %Result{value: value, logs: logs, error: nil}
  end

  @doc """
  A failed result, carrying whatever the program managed to say first.
  """
  @spec failed(Failure.kind(), String.t(), [String.t()]) :: t()
  def failed(kind, message, logs \\ []) when is_list(logs) do
    %Result{value: nil, logs: logs, error: Failure.new(kind, message)}
  end

  @doc """
  Whether the program produced a value.

  ## Examples

      iex> Nous.CodeRuntime.Result.ok(42) |> Nous.CodeRuntime.Result.success?()
      true

      iex> Nous.CodeRuntime.Result.failed(:timeout, "deadline") |> Nous.CodeRuntime.Result.success?()
      false

  """
  @spec success?(t()) :: boolean()
  def success?(%Result{error: nil}), do: true
  def success?(%Result{}), do: false
end
