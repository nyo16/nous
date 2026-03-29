defmodule Nous.Workflow.Graph do
  @moduledoc """
  Directed graph definition for workflow execution.

  Uses dual adjacency maps (`out_edges` and `in_edges`) for efficient
  forward traversal and topological sort. Provides an `Ecto.Multi`-style
  builder API for constructing graphs via pipes.

  ## Architecture

  - Node IDs are atoms in the builder API, stored as strings internally
  - Dual adjacency maps give O(1) neighbor lookups in both directions
  - Pure maps, no ETS — immutable, process-safe
  - Metadata lives directly on node/edge structs, no separate stores

  ## Examples

      graph =
        Nous.Workflow.Graph.new("my_pipeline")
        |> Nous.Workflow.Graph.add_node(:fetch, :agent_step, %{agent: fetcher, prompt: "..."})
        |> Nous.Workflow.Graph.add_node(:process, :transform, %{transform_fn: &process/1})
        |> Nous.Workflow.Graph.add_node(:store, :tool_step, %{tool: store_tool, args: %{}})
        |> Nous.Workflow.Graph.chain([:fetch, :process, :store])
  """

  alias Nous.Workflow.{Node, Edge}

  @type node_id :: String.t()

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          nodes: %{node_id() => Node.t()},
          out_edges: %{node_id() => [Edge.t()]},
          in_edges: %{node_id() => [Edge.t()]},
          entry_node: node_id() | nil,
          allows_cycles: boolean(),
          metadata: map()
        }

  defstruct id: nil,
            name: nil,
            nodes: %{},
            out_edges: %{},
            in_edges: %{},
            entry_node: nil,
            allows_cycles: false,
            metadata: %{}

  @doc """
  Create a new empty graph.

  ## Options

  - `:name` — human-readable name (defaults to the id)
  - `:allows_cycles` — whether cycles are permitted (default: `false`)

  ## Examples

      iex> graph = Nous.Workflow.Graph.new("research")
      iex> graph.id
      "research"
      iex> graph.nodes
      %{}

  """
  @spec new(String.t(), keyword()) :: t()
  def new(id, opts \\ []) when is_binary(id) do
    %__MODULE__{
      id: id,
      name: Keyword.get(opts, :name, id),
      allows_cycles: Keyword.get(opts, :allows_cycles, false)
    }
  end

  @doc """
  Add a node to the graph.

  The first node added becomes the entry node automatically.

  ## Parameters

  - `node_id` — atom or string identifier for the node
  - `type` — one of the valid `Nous.Workflow.Node` types
  - `config` — type-specific configuration map
  - `opts` — optional node fields (`:label`, `:error_strategy`, `:timeout`, `:metadata`)

  ## Examples

      graph
      |> Nous.Workflow.Graph.add_node(:fetch, :agent_step, %{agent: my_agent, prompt: "..."})
      |> Nous.Workflow.Graph.add_node(:process, :transform, %{transform_fn: &clean/1}, label: "Clean data")

  """
  @spec add_node(t(), atom() | String.t(), Node.node_type(), map(), keyword()) :: t()
  def add_node(%__MODULE__{} = graph, node_id, type, config \\ %{}, opts \\ []) do
    id = to_string(node_id)

    if Map.has_key?(graph.nodes, id) do
      raise ArgumentError, "node #{inspect(id)} already exists in graph"
    end

    node =
      Node.new(%{
        id: id,
        type: type,
        label: Keyword.get(opts, :label, id),
        config: config,
        error_strategy: Keyword.get(opts, :error_strategy, :fail_fast),
        timeout: Keyword.get(opts, :timeout),
        metadata: Keyword.get(opts, :metadata, %{})
      })

    entry = if graph.entry_node == nil, do: id, else: graph.entry_node

    %{
      graph
      | nodes: Map.put(graph.nodes, id, node),
        out_edges: Map.put_new(graph.out_edges, id, []),
        in_edges: Map.put_new(graph.in_edges, id, []),
        entry_node: entry
    }
  end

  @doc """
  Connect two nodes with an edge.

  ## Options

  - `:condition` — function `(state -> boolean)` for conditional edges
  - `:label` — human-readable edge label
  - `:metadata` — arbitrary edge metadata

  When `:condition` is provided, the edge type is `:conditional`.
  Otherwise, it defaults to `:sequential`.

  ## Examples

      graph
      |> Nous.Workflow.Graph.connect(:a, :b)
      |> Nous.Workflow.Graph.connect(:b, :c, condition: fn s -> s.data.ready end)

  """
  @spec connect(t(), atom() | String.t(), atom() | String.t(), keyword()) :: t()
  def connect(%__MODULE__{} = graph, from, to, opts \\ []) do
    from_id = to_string(from)
    to_id = to_string(to)

    validate_node_exists!(graph, from_id, "connect from")
    validate_node_exists!(graph, to_id, "connect to")

    condition = Keyword.get(opts, :condition)

    edge_type =
      cond do
        condition != nil -> :conditional
        Keyword.get(opts, :default, false) -> :default
        true -> :sequential
      end

    edge =
      Edge.new(%{
        from_id: from_id,
        to_id: to_id,
        type: edge_type,
        condition: condition,
        label: Keyword.get(opts, :label),
        metadata: Keyword.get(opts, :metadata, %{})
      })

    %{
      graph
      | out_edges: Map.update!(graph.out_edges, from_id, &[edge | &1]),
        in_edges: Map.update!(graph.in_edges, to_id, &[edge | &1])
    }
  end

  @doc """
  Connect a list of nodes in sequence: A → B → C → D.

  ## Examples

      graph
      |> Nous.Workflow.Graph.chain([:plan, :search, :synthesize, :report])

  """
  @spec chain(t(), [atom() | String.t()]) :: t()
  def chain(%__MODULE__{} = graph, node_ids) when is_list(node_ids) do
    node_ids
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [from, to], acc -> connect(acc, from, to) end)
  end

  @doc """
  Set the entry node explicitly (overrides the auto-detected first node).
  """
  @spec set_entry(t(), atom() | String.t()) :: t()
  def set_entry(%__MODULE__{} = graph, node_id) do
    id = to_string(node_id)
    validate_node_exists!(graph, id, "set_entry")
    %{graph | entry_node: id}
  end

  @doc """
  Returns the successor node IDs for a given node (via out_edges).
  """
  @spec successors(t(), node_id()) :: [node_id()]
  def successors(%__MODULE__{} = graph, node_id) do
    graph.out_edges
    |> Map.get(node_id, [])
    |> Enum.map(& &1.to_id)
  end

  @doc """
  Returns the predecessor node IDs for a given node (via in_edges).
  """
  @spec predecessors(t(), node_id()) :: [node_id()]
  def predecessors(%__MODULE__{} = graph, node_id) do
    graph.in_edges
    |> Map.get(node_id, [])
    |> Enum.map(& &1.from_id)
  end

  @doc """
  Returns the number of nodes in the graph.
  """
  @spec node_count(t()) :: non_neg_integer()
  def node_count(%__MODULE__{nodes: nodes}), do: map_size(nodes)

  @doc """
  Returns all node IDs in the graph.
  """
  @spec node_ids(t()) :: [node_id()]
  def node_ids(%__MODULE__{nodes: nodes}), do: Map.keys(nodes)

  @doc """
  Returns terminal nodes (nodes with no outgoing edges).
  """
  @spec terminal_nodes(t()) :: [node_id()]
  def terminal_nodes(%__MODULE__{} = graph) do
    Enum.filter(Map.keys(graph.nodes), fn id ->
      graph.out_edges |> Map.get(id, []) |> Enum.empty?()
    end)
  end

  defp validate_node_exists!(graph, node_id, context) do
    unless Map.has_key?(graph.nodes, node_id) do
      raise ArgumentError,
            "#{context}: node #{inspect(node_id)} does not exist in graph. " <>
              "Available nodes: #{inspect(Map.keys(graph.nodes))}"
    end
  end
end
