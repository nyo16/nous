defmodule Nous.Eval.Task do
  @moduledoc """
  Loads a `use Nous.Eval` task module and calls its callbacks with checked
  results.

  `load/2` fails closed: a module that is not loaded, does not declare
  `@behaviour Nous.Eval`, lacks a required callback, or returns an invalid
  dataset or scorer list is an `{:error, message}`, before any sample runs.
  The other functions wrap one callback each and turn a raise or a
  wrong-shaped return into `{:error, message}`.
  """

  alias Nous.Eval.Dataset
  alias Nous.Eval.Scorer.Spec

  @type t :: %__MODULE__{module: module(), dataset: Dataset.t(), scorers: [Spec.t()]}

  @enforce_keys [:module, :dataset]
  defstruct [:module, :dataset, scorers: []]

  @doc """
  Loads and validates a task module: its dataset (built or loaded through
  `Nous.Eval.Dataset`) and its default scorers (as `Nous.Eval.Scorer.Spec`s).

  `opts` are passed to `Nous.Eval.Dataset.new/2` / `Nous.Eval.Dataset.load/2`
  (e.g. `:split_ratios`); a ready `%Nous.Eval.Dataset{}` is used as is.
  """
  @spec load(module(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(module, opts \\ []) when is_list(opts) do
    with :ok <- check_task(module),
         {:ok, dataset} <- dataset(module, opts),
         {:ok, scorers} <- scorers(module) do
      {:ok, %__MODULE__{module: module, dataset: dataset, scorers: scorers}}
    end
  end

  @doc "Runs the task's `c:Nous.Eval.setup/1`; `{:ok, nil}` when it has none."
  @spec setup(t(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def setup(%__MODULE__{module: module}, opts \\ []) do
    if exported?(module, :setup, 1) do
      case call(module, :setup, [opts]) do
        {:ok, {:ok, state}} ->
          {:ok, state}

        {:ok, {:error, reason}} ->
          {:error, "#{inspect(module)}.setup/1 failed: #{inspect(reason)}"}

        {:ok, other} ->
          bad_return(module, "setup/1", "{:ok, state} | {:error, reason}", other)

        error ->
          error
      end
    else
      {:ok, nil}
    end
  end

  @doc "Runs the task's `c:Nous.Eval.teardown/1`, if any."
  @spec teardown(t(), term()) :: :ok | {:error, String.t()}
  def teardown(%__MODULE__{module: module}, state) do
    if exported?(module, :teardown, 1) do
      with {:ok, _} <- call(module, :teardown, [state]), do: :ok
    else
      :ok
    end
  end

  @doc "The deps for every sample, from `c:Nous.Eval.deps/1`; `%{}` when it has none."
  @spec deps(t(), term()) :: {:ok, map()} | {:error, String.t()}
  def deps(%__MODULE__{module: module}, state) do
    if exported?(module, :deps, 1) do
      case call(module, :deps, [state]) do
        {:ok, deps} when is_map(deps) and not is_struct(deps) -> {:ok, deps}
        {:ok, other} -> bad_return(module, "deps/1", "a map", other)
        error -> error
      end
    else
      {:ok, %{}}
    end
  end

  @doc """
  Builds the agent for one sample with `c:Nous.Eval.agent/1`.

  `context` must carry `:case`, `:sample`, `:seed`, `:deps` and `:state`
  (see `t:Nous.Eval.context/0`).
  """
  @spec agent(t(), Nous.Eval.context()) :: {:ok, Nous.Agent.t()} | {:error, String.t()}
  def agent(%__MODULE__{module: module}, context) when is_map(context) do
    case Enum.reject([:case, :sample, :seed, :deps, :state], &Map.has_key?(context, &1)) do
      [] ->
        case call(module, :agent, [context]) do
          {:ok, %Nous.Agent{} = agent} -> {:ok, agent}
          {:ok, other} -> bad_return(module, "agent/1", "a %Nous.Agent{}", other)
          error -> error
        end

      missing ->
        {:error, "agent context is missing #{Enum.map_join(missing, ", ", &inspect/1)}"}
    end
  end

  defp check_task(module) when is_atom(module) do
    cond do
      Code.ensure_loaded(module) != {:module, module} ->
        {:error, "#{inspect(module)} is not a loaded module"}

      Nous.Eval not in behaviours(module) ->
        {:error, "#{inspect(module)} is not a Nous.Eval task (add `use Nous.Eval`)"}

      not exported?(module, :agent, 1) ->
        {:error, "#{inspect(module)} does not define agent/1"}

      not exported?(module, :dataset, 0) ->
        {:error, "#{inspect(module)} does not define dataset/0"}

      true ->
        :ok
    end
  end

  defp check_task(other), do: {:error, "a task is a module, got #{inspect(other)}"}

  defp behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  defp dataset(module, opts) do
    case call(module, :dataset, []) do
      {:ok, %Dataset{} = dataset} ->
        {:ok, dataset}

      {:ok, path} when is_binary(path) ->
        Dataset.load(path, opts)

      {:ok, cases} when is_list(cases) ->
        Dataset.new(cases, Keyword.put_new(opts, :name, inspect(module)))

      {:ok, other} ->
        bad_return(module, "dataset/0", "a dataset, a case list or a file path", other)

      error ->
        error
    end
  end

  defp scorers(module) do
    declared =
      if exported?(module, :scorers, 0), do: call(module, :scorers, []), else: {:ok, []}

    with {:ok, list} <- declared do
      case Dataset.scorer_specs(list) do
        {:ok, specs} -> {:ok, specs}
        {:error, message} -> {:error, "#{inspect(module)}.scorers/0: #{message}"}
      end
    end
  end

  defp exported?(module, fun, arity), do: function_exported?(module, fun, arity)

  defp call(module, fun, args) do
    {:ok, apply(module, fun, args)}
  rescue
    exception ->
      {:error,
       "#{inspect(module)}.#{fun}/#{length(args)} raised: #{Exception.message(exception)}"}
  catch
    kind, reason ->
      {:error, "#{inspect(module)}.#{fun}/#{length(args)} #{kind}: #{inspect(reason)}"}
  end

  defp bad_return(module, fun, expected, got) do
    {:error, "#{inspect(module)}.#{fun} must return #{expected}, got #{inspect(got)}"}
  end
end
