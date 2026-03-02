defmodule Nous.Decisions.ContextBuilder do
  @moduledoc """
  Builds a text summary of the decision graph for system prompt injection.

  Queries the decision store for active goals and recent decisions, then
  formats them into a human-readable string suitable for inclusion in an
  agent's system prompt.

  ## Architecture

  The context builder is a pure function module -- it reads from the store
  but does not modify it. It is called by `Nous.Plugins.Decisions` during
  the `system_prompt/2` and `before_request/3` callbacks.

  ## Quick Start

      {:ok, state} = Nous.Decisions.Store.ETS.init([])
      # ... add nodes and edges ...
      text = Nous.Decisions.ContextBuilder.build(Nous.Decisions.Store.ETS, state)

  """

  alias Nous.Decisions.Node

  @doc """
  Build a context string from active goals and recent decisions.

  ## Options

    * `:decision_limit` - max recent decisions to include (default: 5)

  ## Examples

      text = ContextBuilder.build(Store.ETS, state)
      # "## Active Goals\\n- [abc123] Implement auth (confidence: 0.8, status: active)\\n..."

  Returns `nil` if there are no goals or decisions to display.
  """
  @spec build(module(), term(), keyword()) :: String.t() | nil
  def build(store_mod, state, opts \\ []) do
    decision_limit = Keyword.get(opts, :decision_limit, 5)

    {:ok, goals} = store_mod.query(state, :active_goals, [])
    {:ok, decisions} = store_mod.query(state, :recent_decisions, limit: decision_limit)

    parts = []

    parts =
      if goals != [] do
        goal_lines =
          Enum.map(goals, fn goal ->
            children = format_children(store_mod, state, goal.id)
            confidence = if goal.confidence, do: ", confidence: #{goal.confidence}", else: ""
            line = "- [#{short_id(goal.id)}] #{goal.label} (status: #{goal.status}#{confidence})"

            if children != "" do
              line <> "\n" <> children
            else
              line
            end
          end)

        parts ++ ["## Active Goals\n" <> Enum.join(goal_lines, "\n")]
      else
        parts
      end

    parts =
      if decisions != [] do
        decision_lines =
          Enum.map(decisions, fn decision ->
            rationale = if decision.rationale, do: " -- #{decision.rationale}", else: ""
            "- [#{short_id(decision.id)}] #{decision.label}#{rationale}"
          end)

        parts ++ ["## Recent Decisions\n" <> Enum.join(decision_lines, "\n")]
      else
        parts
      end

    case parts do
      [] -> nil
      _ -> Enum.join(parts, "\n\n")
    end
  end

  defp format_children(store_mod, state, node_id) do
    {:ok, edges} = store_mod.get_edges(state, node_id, :outgoing)

    edges
    |> Enum.flat_map(fn edge ->
      case store_mod.get_node(state, edge.to_id) do
        {:ok, %Node{} = child} ->
          status_str =
            case edge.edge_type do
              :chosen -> "chosen"
              :rejected -> "rejected"
              _ -> to_string(child.status)
            end

          ["  #{tree_char()} [#{short_id(child.id)}] #{child.label} (#{status_str})"]

        _ ->
          []
      end
    end)
    |> Enum.join("\n")
  end

  defp tree_char, do: "└─"

  defp short_id(id) when byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_id(id), do: id
end
