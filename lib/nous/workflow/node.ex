defmodule Nous.Workflow.Node do
  @moduledoc """
  A node in a workflow graph.

  Nodes represent discrete execution steps: running agents, executing tools,
  branching on conditions, parallel fan-out, data transformation, and
  human-in-the-loop checkpoints.

  ## Node Types

  | Type | Purpose |
  |------|---------|
  | `:agent_step` | Run a `Nous.Agent` via `AgentRunner.run/3` |
  | `:tool_step` | Execute a single tool via `ToolExecutor.execute/3` |
  | `:branch` | Conditional routing based on state predicates |
  | `:parallel` | Static fan-out to named branches, fan-in with merge |
  | `:parallel_map` | Dynamic fan-out over a runtime-computed list |
  | `:transform` | Pure function on workflow state |
  | `:human_checkpoint` | Pause for human review/approval |
  | `:subworkflow` | Nested workflow invocation |

  ## Examples

      Nous.Workflow.Node.new(%{
        id: "fetch_data",
        type: :agent_step,
        label: "Fetch research data",
        config: %{agent: researcher_agent, prompt: "Find data on..."}
      })
  """

  @type node_type ::
          :agent_step
          | :tool_step
          | :branch
          | :parallel
          | :parallel_map
          | :transform
          | :human_checkpoint
          | :subworkflow

  @type error_strategy ::
          :fail_fast
          | {:retry, max :: pos_integer(), delay_ms :: non_neg_integer()}
          | :skip
          | {:fallback, node_id :: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          type: node_type(),
          label: String.t(),
          config: map(),
          error_strategy: error_strategy(),
          timeout: non_neg_integer() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :type,
    :label,
    :timeout,
    config: %{},
    error_strategy: :fail_fast,
    metadata: %{}
  ]

  @valid_types ~w(agent_step tool_step branch parallel parallel_map transform human_checkpoint subworkflow)a

  @doc """
  Create a new workflow node.

  Required: `:id`, `:type`, and `:label`.

  ## Examples

      iex> node = Nous.Workflow.Node.new(%{id: "step1", type: :transform, label: "Clean data"})
      iex> node.type
      :transform
      iex> node.error_strategy
      :fail_fast

  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    type = Map.fetch!(attrs, :type)

    unless type in @valid_types do
      raise ArgumentError,
            "invalid node type: #{inspect(type)}, must be one of #{inspect(@valid_types)}"
    end

    %__MODULE__{
      id: attrs |> Map.fetch!(:id) |> to_string(),
      type: type,
      label: Map.fetch!(attrs, :label),
      config: Map.get(attrs, :config, %{}),
      error_strategy: Map.get(attrs, :error_strategy, :fail_fast),
      timeout: Map.get(attrs, :timeout),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @doc """
  Returns the list of valid node types.
  """
  @spec valid_types() :: [node_type()]
  def valid_types, do: @valid_types
end
