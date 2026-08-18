defmodule Nous.CodeRuntime.Binding do
  @moduledoc """
  One global the program can call, and the functions hanging off it.

  A binding is how a tool reaches model-authored code. `functions` maps the name
  the program calls to the closure that serves it — already scoped to the caller,
  because the closure is built from `Nous.Permissions.filter_tools/2`'s output.
  A denied tool still appears here, bound to a stub that returns an error, so the
  program gets a comprehensible failure instead of an undefined-function crash.

  `error_class` names the exception the substrate should raise inside the guest
  when a call fails, so a program can `try`/`catch` in its own idiom.

  There is exactly one permission mechanism. A binding is not a second one: it
  carries no allow/deny decisions of its own, only the closures that survived the
  policy.
  """

  alias __MODULE__

  @type fun_name :: String.t()

  @type t :: %Binding{
          global: String.t(),
          functions: %{fun_name() => (map() -> {:ok, term()} | {:error, term()})},
          error_class: String.t()
        }

  @enforce_keys [:global, :functions]
  defstruct global: nil, functions: %{}, error_class: "Error"
end

defmodule Nous.CodeRuntime.Request do
  @moduledoc """
  What to run, what it may call, and who gets the answer.

  Deliberately absent: **tuning knobs**. There is no timeout, no memory cap and no
  instruction budget here. Budgets are provider configuration, validated when the
  provider is configured, because a per-request budget is a per-request way for a
  caller — and therefore, one refactor later, for a model — to ask for more rope.
  A program cannot request a longer deadline for itself.

  `owner` is the process that receives `{:code_run, ref, %Nous.CodeRuntime.Result{}}`.
  """

  alias Nous.CodeRuntime.Binding
  alias __MODULE__

  @type t :: %Request{
          program: String.t(),
          bindings: [Binding.t()],
          owner: pid()
        }

  @enforce_keys [:program, :owner]
  defstruct program: nil, bindings: [], owner: nil

  @doc """
  Build a request, validating the shape a provider is entitled to assume.

  Returns `{:error, {:contract, message}}` rather than raising: a malformed
  request is seam misuse by Nous itself, and the tool call that carried it should
  fail cleanly rather than take down the run.
  """
  @spec new(String.t(), [Binding.t()], pid()) :: {:ok, t()} | {:error, {:contract, String.t()}}
  def new(program, bindings, owner)

  def new(program, _bindings, _owner) when not is_binary(program) do
    {:error, {:contract, "program must be a string"}}
  end

  def new(program, bindings, owner) when is_list(bindings) and is_pid(owner) do
    case Enum.find(bindings, &(not valid_binding?(&1))) do
      nil -> {:ok, %Request{program: program, bindings: bindings, owner: owner}}
      bad -> {:error, {:contract, "invalid binding: #{inspect(bad)}"}}
    end
  end

  def new(_program, bindings, owner) do
    {:error,
     {:contract,
      "bindings must be a list and owner a pid, got #{inspect(bindings)} / #{inspect(owner)}"}}
  end

  defp valid_binding?(%Binding{global: global, functions: functions})
       when is_binary(global) and is_map(functions) do
    Enum.all?(functions, fn {name, fun} -> is_binary(name) and is_function(fun, 1) end)
  end

  defp valid_binding?(_other), do: false
end
