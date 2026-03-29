defmodule Nous.Workflow.Mermaid do
  @moduledoc """
  Generate Mermaid flowchart diagrams from workflow graphs.

  ## Example

      graph = Nous.Workflow.new("pipeline")
        |> Nous.Workflow.add_node(:a, :agent_step, %{agent: nil}, label: "Plan")
        |> Nous.Workflow.add_node(:b, :parallel, %{branches: [:c, :d]}, label: "Search")
        |> Nous.Workflow.add_node(:c, :transform, %{transform_fn: &Function.identity/1}, label: "Web")
        |> Nous.Workflow.add_node(:d, :transform, %{transform_fn: &Function.identity/1}, label: "Papers")
        |> Nous.Workflow.add_node(:e, :agent_step, %{agent: nil}, label: "Report")
        |> Nous.Workflow.connect(:a, :b)
        |> Nous.Workflow.connect(:b, :e)

      IO.puts Nous.Workflow.Mermaid.to_mermaid(graph)

  Output:

      ```mermaid
      flowchart TD
          a["Plan"]
          b{{"Search"}}
          c["Web"]
          d["Papers"]
          e["Report"]
          a --> b
          b --> e
          b -.-> c
          b -.-> d
      ```
  """

  alias Nous.Workflow.Graph

  @node_shapes %{
    agent_step: {~S'["', ~S'"]'},
    tool_step: {~S'[/"', ~S'"/]'},
    branch: {~S'{"', ~S'"}'},
    parallel: {~S'{{"', ~S'"}}'},
    parallel_map: {~S'{{"', ~S'"}}'},
    transform: {~S'["', ~S'"]'},
    human_checkpoint: {~S'(["', ~S'"])'},
    subworkflow: {~S'[["', ~S'"]]'}
  }

  @doc """
  Generate a Mermaid flowchart string from a workflow graph.

  ## Options

  - `:direction` — flowchart direction, one of `"TD"`, `"LR"` (default: `"TD"`)
  """
  @spec to_mermaid(Graph.t(), keyword()) :: String.t()
  def to_mermaid(%Graph{} = graph, opts \\ []) do
    direction = Keyword.get(opts, :direction, "TD")

    nodes_section =
      graph.nodes
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, node} -> render_node(id, node) end)
      |> Enum.join("\n")

    edges_section =
      graph.out_edges
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.flat_map(fn {_from_id, edges} -> edges end)
      |> Enum.map(&render_edge(&1, graph))
      |> Enum.join("\n")

    # Parallel branch references (dashed lines)
    parallel_section =
      graph.nodes
      |> Enum.filter(fn {_id, node} -> node.type == :parallel end)
      |> Enum.flat_map(fn {id, node} ->
        (node.config[:branches] || [])
        |> Enum.map(fn branch_id ->
          "    #{id} -.-> #{to_string(branch_id)}"
        end)
      end)
      |> Enum.join("\n")

    sections =
      [nodes_section, edges_section, parallel_section]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    "flowchart #{direction}\n#{sections}"
  end

  defp render_node(id, node) do
    {open, close} = Map.get(@node_shapes, node.type, {~S'["', ~S'"]'})
    label = node.label || id
    type_suffix = if node.type in [:agent_step, :transform], do: "", else: " (#{node.type})"
    "    #{id}#{open}#{label}#{type_suffix}#{close}"
  end

  defp render_edge(edge, _graph) do
    arrow =
      case edge.type do
        :sequential -> " --> "
        :conditional -> " -->|#{edge.label || "condition"}| "
        :default -> " -->|default| "
      end

    "    #{edge.from_id}#{arrow}#{edge.to_id}"
  end
end
