defmodule Nous.Workflow.State do
  @moduledoc """
  Typed state that flows between workflow nodes.

  Each node receives the state as input and returns an updated version.
  User data lives in `data`, while `node_results` provides access to
  any previous node's raw output by ID.

  ## Fields

  | Field | Type | Description |
  |-------|------|-------------|
  | `data` | `map()` | User-defined workflow data |
  | `node_results` | `map()` | Results keyed by node ID |
  | `metadata` | `map()` | Workflow-level metadata (hooks, notify_pid, etc.) |
  | `errors` | `list()` | Errors recorded during execution |
  | `started_at` | `DateTime.t()` | When the workflow started |
  | `updated_at` | `DateTime.t()` | Last state update |

  ## Examples

      state = Nous.Workflow.State.new(%{query: "research topic"})
      state.data.query
      #=> "research topic"
  """

  @type t :: %__MODULE__{
          data: map(),
          node_results: %{String.t() => term()},
          metadata: map(),
          errors: [{String.t(), term()}],
          started_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct data: %{},
            node_results: %{},
            metadata: %{},
            errors: [],
            started_at: nil,
            updated_at: nil

  @doc """
  Create a new workflow state from initial data.

  ## Examples

      iex> state = Nous.Workflow.State.new(%{query: "test"})
      iex> state.data.query
      "test"
      iex> state.node_results
      %{}

  """
  @spec new(map()) :: t()
  def new(data \\ %{}) when is_map(data) do
    now = DateTime.utc_now()

    %__MODULE__{
      data: data,
      started_at: now,
      updated_at: now
    }
  end

  @doc """
  Record a node's result in the state.
  """
  @spec put_result(t(), String.t(), term()) :: t()
  def put_result(%__MODULE__{} = state, node_id, result) do
    %{
      state
      | node_results: Map.put(state.node_results, node_id, result),
        updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Record an error for a node.
  """
  @spec put_error(t(), String.t(), term()) :: t()
  def put_error(%__MODULE__{} = state, node_id, error) do
    %{state | errors: [{node_id, error} | state.errors], updated_at: DateTime.utc_now()}
  end

  @doc """
  Update the user data map.
  """
  @spec update_data(t(), (map() -> map())) :: t()
  def update_data(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    %{state | data: fun.(state.data), updated_at: DateTime.utc_now()}
  end
end
