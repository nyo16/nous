defmodule DeepResearch.ResearchGraph do
  @moduledoc """
  DAG-based research workflow using libgraph.

  Nodes represent research tasks with types:
  - :plan - Initial planning/decomposition
  - :research - Web/academic search
  - :analyze - Pattern extraction and synthesis
  - :critique - Gap identification
  - :review - Verification
  - :write - Report generation

  Edges define dependencies (from must complete before to).
  """

  @type node_type :: :plan | :research | :analyze | :critique | :review | :write

  @type node_config :: %{
          type: node_type(),
          agent: module(),
          prompt: String.t(),
          sub_question: String.t() | nil,
          status: :pending | :running | :completed | :failed
        }

  @doc """
  Create a new empty research DAG.
  """
  def new do
    Graph.new(type: :directed)
  end

  @doc """
  Add a research task node with metadata.

  ## Examples

      graph = ResearchGraph.new()
      graph = ResearchGraph.add_task(graph, "research:agi_approaches", :research, %{
        prompt: "Search for current AGI approaches",
        sub_question: "What are the leading approaches to AGI?"
      })
  """
  def add_task(graph, id, type, config \\ %{}) do
    labels = [
      type: type,
      status: :pending,
      prompt: Map.get(config, :prompt, ""),
      sub_question: Map.get(config, :sub_question),
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    ]

    Graph.add_vertex(graph, id, labels)
  end

  @doc """
  Add a dependency: `from` must complete before `to` can start.
  """
  def add_dependency(graph, from, to) do
    Graph.add_edge(graph, from, to)
  end

  @doc """
  Add multiple dependencies from a list of edges.
  """
  def add_dependencies(graph, edges) when is_list(edges) do
    Enum.reduce(edges, graph, fn {from, to}, g ->
      add_dependency(g, from, to)
    end)
  end

  @doc """
  Get execution order via topological sort.
  Returns {:ok, order} or {:error, :cycle_detected}.
  """
  def execution_order(graph) do
    case Graph.topsort(graph) do
      false -> {:error, :cycle_detected}
      order -> {:ok, order}
    end
  end

  @doc """
  Get all nodes that are ready to execute.
  A node is ready if all its dependencies (in_neighbors) are in the completed set.
  """
  def ready_nodes(graph, completed) do
    Graph.vertices(graph)
    |> Enum.filter(fn node ->
      # Skip already completed nodes
      not MapSet.member?(completed, node) and
        # All dependencies must be completed
        Enum.all?(Graph.in_neighbors(graph, node), &MapSet.member?(completed, &1))
    end)
  end

  @doc """
  Check if a set of nodes can be executed in parallel.
  Nodes can run in parallel if none of them can reach another.
  """
  def parallelizable?(graph, nodes) do
    nodes = MapSet.new(nodes)

    Enum.all?(nodes, fn n1 ->
      reachable = Graph.reachable(graph, [n1]) |> MapSet.new()
      # n1's reachable set should not include any other node in the set
      MapSet.disjoint?(MapSet.delete(nodes, n1), reachable)
    end)
  end

  @doc """
  Get node metadata/labels.
  """
  def get_node(graph, node_id) do
    case Graph.vertex_labels(graph, node_id) do
      [] -> nil
      labels -> Map.new(labels)
    end
  end

  @doc """
  Update node status.
  """
  def update_status(graph, node_id, status) do
    Graph.label_vertex(graph, node_id, status: status)
  end

  @doc """
  Get all nodes of a specific type.
  """
  def nodes_by_type(graph, type) do
    Graph.vertices(graph)
    |> Enum.filter(fn node ->
      labels = Graph.vertex_labels(graph, node)
      Keyword.get(labels, :type) == type
    end)
  end

  @doc """
  Get the number of nodes in the graph.
  """
  def node_count(graph) do
    Graph.num_vertices(graph)
  end

  @doc """
  Get the number of edges in the graph.
  """
  def edge_count(graph) do
    Graph.num_edges(graph)
  end

  @doc """
  Check if all nodes are completed.
  """
  def all_completed?(graph, completed) do
    Graph.vertices(graph)
    |> Enum.all?(&MapSet.member?(completed, &1))
  end

  @doc """
  Add a new research node dynamically (e.g., when Critic identifies a gap).
  Connects it as a dependency to the specified downstream nodes.
  """
  def add_dynamic_research(graph, id, config, depends_on \\ [], feeds_into \\ []) do
    graph = add_task(graph, id, :research, config)

    # Add edges from dependencies
    graph =
      Enum.reduce(depends_on, graph, fn dep, g ->
        add_dependency(g, dep, id)
      end)

    # Add edges to downstream nodes
    Enum.reduce(feeds_into, graph, fn downstream, g ->
      add_dependency(g, id, downstream)
    end)
  end

  @doc """
  Visualize the graph structure as a string.
  """
  def to_string(graph) do
    vertices = Graph.vertices(graph)
    edges = Graph.edges(graph)

    vertex_lines =
      vertices
      |> Enum.map(fn v ->
        labels = Graph.vertex_labels(graph, v)
        type = Keyword.get(labels, :type, :unknown)
        status = Keyword.get(labels, :status, :pending)
        "  [#{v}] type=#{type}, status=#{status}"
      end)
      |> Enum.join("\n")

    edge_lines =
      edges
      |> Enum.map(fn %{v1: v1, v2: v2} -> "  #{v1} -> #{v2}" end)
      |> Enum.join("\n")

    """
    Research DAG (#{length(vertices)} nodes, #{length(edges)} edges):

    Nodes:
    #{vertex_lines}

    Dependencies:
    #{edge_lines}
    """
  end

  @doc """
  Build a standard research graph from a list of sub-questions.

  Creates:
  - plan:root node
  - research:N nodes for each sub-question (parallel)
  - analyze:N nodes after each research
  - critique:coverage node after all analysis
  - review:verify node after critique
  - write:report node at the end
  """
  def build_from_sub_questions(sub_questions) do
    graph = new()

    # Add plan node
    graph = add_task(graph, "plan:root", :plan, %{prompt: "Initial planning"})

    # Add research and analyze nodes for each sub-question
    {graph, research_ids, analyze_ids} =
      sub_questions
      |> Enum.with_index(1)
      |> Enum.reduce({graph, [], []}, fn {sq, idx}, {g, r_ids, a_ids} ->
        r_id = "research:sq#{idx}"
        a_id = "analyze:sq#{idx}"

        g = add_task(g, r_id, :research, %{prompt: "Research: #{sq}", sub_question: sq})
        g = add_task(g, a_id, :analyze, %{prompt: "Analyze findings for: #{sq}", sub_question: sq})

        # plan -> research -> analyze
        g = add_dependency(g, "plan:root", r_id)
        g = add_dependency(g, r_id, a_id)

        {g, [r_id | r_ids], [a_id | a_ids]}
      end)

    # Add critique node (depends on all analyze nodes)
    graph = add_task(graph, "critique:coverage", :critique, %{prompt: "Analyze coverage and gaps"})

    graph =
      Enum.reduce(analyze_ids, graph, fn a_id, g ->
        add_dependency(g, a_id, "critique:coverage")
      end)

    # Add review node
    graph = add_task(graph, "review:verify", :review, %{prompt: "Verify all findings"})
    graph = add_dependency(graph, "critique:coverage", "review:verify")

    # Add write node
    graph = add_task(graph, "write:report", :write, %{prompt: "Generate final report"})
    graph = add_dependency(graph, "review:verify", "write:report")

    graph
  end
end
