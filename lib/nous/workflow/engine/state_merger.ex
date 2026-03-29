defmodule Nous.Workflow.Engine.StateMerger do
  @moduledoc """
  Merge strategies for combining parallel branch results back into workflow state.

  After parallel branches complete, their results need to be merged into a
  single state. Three built-in strategies are provided:

  - `:deep_merge` — deep-merges all branch result maps into `state.data`
  - `:list_collect` — collects branch results into a list under a key
  - Custom function — `fn branch_results, state -> updated_state`
  """

  alias Nous.Workflow.State

  @type strategy :: :deep_merge | :list_collect | (list(), State.t() -> State.t())

  @doc """
  Merge parallel branch results into the workflow state.

  ## Parameters

  - `results` — list of `{branch_id, result}` tuples from completed branches
  - `state` — current workflow state
  - `strategy` — merge strategy atom or custom function
  - `opts` — additional options (`:result_key` for `:list_collect`)
  """
  @spec merge([{String.t(), term()}], State.t(), strategy(), keyword()) :: State.t()
  def merge(results, state, strategy, opts \\ [])

  def merge(results, state, :deep_merge, _opts) do
    Enum.reduce(results, state, fn {branch_id, result}, acc ->
      acc = State.put_result(acc, branch_id, result)

      case result do
        map when is_map(map) -> State.update_data(acc, &deep_merge(&1, map))
        _ -> acc
      end
    end)
  end

  def merge(results, state, :list_collect, opts) do
    result_key = Keyword.get(opts, :result_key, :parallel_results)

    collected = Enum.map(results, fn {_branch_id, result} -> result end)

    state =
      Enum.reduce(results, state, fn {branch_id, result}, acc ->
        State.put_result(acc, branch_id, result)
      end)

    State.update_data(state, &Map.put(&1, result_key, collected))
  end

  def merge(results, state, merge_fn, _opts) when is_function(merge_fn, 2) do
    state =
      Enum.reduce(results, state, fn {branch_id, result}, acc ->
        State.put_result(acc, branch_id, result)
      end)

    merge_fn.(results, state)
  end

  # ---------------------------------------------------------------------------
  # Deep merge helper
  # ---------------------------------------------------------------------------

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  defp deep_merge(_left, right), do: right
end
