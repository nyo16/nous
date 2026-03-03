defmodule Nous.Decisions.Tools do
  @moduledoc """
  Agent tools for decision graph operations.

  Provides tools for agents to record goals, decisions, outcomes, and
  query the decision graph. Each tool receives `ctx` via `takes_ctx: true`
  and returns `{:ok, result, ContextUpdate.new()}`.

  ## Tools

  - `add_goal` -- create a goal node
  - `record_decision` -- create a decision node with edge from a parent
  - `record_outcome` -- create an outcome node with edge from a parent
  - `query_decisions` -- query the graph (active_goals, recent_decisions, path)
  """

  alias Nous.Decisions.{Node, Edge}
  alias Nous.Tool
  alias Nous.Tool.ContextUpdate

  @doc """
  Returns all decision tools as a list.
  """
  @spec all_tools() :: [Tool.t()]
  def all_tools do
    [add_goal_tool(), record_decision_tool(), record_outcome_tool(), query_decisions_tool()]
  end

  # ---------------------------------------------------------------------------
  # Tool definitions
  # ---------------------------------------------------------------------------

  defp add_goal_tool do
    %Tool{
      name: "add_goal",
      description:
        "Add a goal to the decision graph. Goals are top-level objectives that drive decisions and actions.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "label" => %{
            "type" => "string",
            "description" => "Description of the goal"
          },
          "confidence" => %{
            "type" => "number",
            "description" => "Confidence level 0.0-1.0 that this goal is achievable (optional)"
          },
          "rationale" => %{
            "type" => "string",
            "description" => "Why this goal was chosen (optional)"
          }
        },
        "required" => ["label"]
      },
      function: &__MODULE__.add_goal/2,
      takes_ctx: true
    }
  end

  defp record_decision_tool do
    %Tool{
      name: "record_decision",
      description:
        "Record a decision in the graph. Optionally link it to a parent node (e.g., a goal or another decision).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "label" => %{
            "type" => "string",
            "description" => "Description of the decision"
          },
          "parent_id" => %{
            "type" => "string",
            "description" => "ID of the parent node to link from (optional)"
          },
          "edge_type" => %{
            "type" => "string",
            "enum" => ["leads_to", "chosen", "rejected", "requires", "enables"],
            "description" => "Type of relationship to parent (default: leads_to)"
          },
          "confidence" => %{
            "type" => "number",
            "description" => "Confidence level 0.0-1.0 (optional)"
          },
          "rationale" => %{
            "type" => "string",
            "description" => "Why this decision was made (optional)"
          }
        },
        "required" => ["label"]
      },
      function: &__MODULE__.record_decision/2,
      takes_ctx: true
    }
  end

  defp record_outcome_tool do
    %Tool{
      name: "record_outcome",
      description:
        "Record an outcome of a decision or action. Links the outcome to its parent node.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "label" => %{
            "type" => "string",
            "description" => "Description of the outcome"
          },
          "parent_id" => %{
            "type" => "string",
            "description" => "ID of the parent decision or action node"
          },
          "status" => %{
            "type" => "string",
            "enum" => ["active", "completed", "rejected"],
            "description" => "Status of the outcome (default: completed)"
          },
          "rationale" => %{
            "type" => "string",
            "description" => "Notes about the outcome (optional)"
          }
        },
        "required" => ["label", "parent_id"]
      },
      function: &__MODULE__.record_outcome/2,
      takes_ctx: true
    }
  end

  defp query_decisions_tool do
    %Tool{
      name: "query_decisions",
      description:
        "Query the decision graph. Supports: active_goals, recent_decisions, descendants, ancestors, path_between.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query_type" => %{
            "type" => "string",
            "enum" => [
              "active_goals",
              "recent_decisions",
              "descendants",
              "ancestors",
              "path_between"
            ],
            "description" => "Type of query to run"
          },
          "node_id" => %{
            "type" => "string",
            "description" => "Node ID for descendants/ancestors queries"
          },
          "from_id" => %{
            "type" => "string",
            "description" => "Source node ID for path_between query"
          },
          "to_id" => %{
            "type" => "string",
            "description" => "Destination node ID for path_between query"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum results for recent_decisions (default: 5)"
          }
        },
        "required" => ["query_type"]
      },
      function: &__MODULE__.query_decisions/2,
      takes_ctx: true
    }
  end

  # ---------------------------------------------------------------------------
  # Tool implementations
  # ---------------------------------------------------------------------------

  @doc """
  Add a goal node to the decision graph.
  """
  @spec add_goal(Nous.Agent.Context.t(), map()) :: {:ok, map(), ContextUpdate.t()}
  def add_goal(ctx, args) do
    with {:ok, store_mod, state} <- get_store(ctx) do
      node =
        Node.new(%{
          type: :goal,
          label: Map.fetch!(args, "label"),
          confidence: Map.get(args, "confidence"),
          rationale: Map.get(args, "rationale")
        })

      case store_mod.add_node(state, node) do
        {:ok, new_state} ->
          {:ok, %{status: "added", id: node.id, type: "goal", label: node.label},
           config_update(ctx, new_state)}

        {:error, reason} ->
          {:ok, %{status: "error", message: "Failed to add goal: #{inspect(reason)}"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} ->
        {:ok, %{status: "error", message: "Decision system not initialized"}, ContextUpdate.new()}
    end
  end

  @doc """
  Record a decision node, optionally linking it to a parent.
  """
  @spec record_decision(Nous.Agent.Context.t(), map()) :: {:ok, map(), ContextUpdate.t()}
  def record_decision(ctx, args) do
    with {:ok, store_mod, state} <- get_store(ctx) do
      node =
        Node.new(%{
          type: :decision,
          label: Map.fetch!(args, "label"),
          confidence: Map.get(args, "confidence"),
          rationale: Map.get(args, "rationale")
        })

      case store_mod.add_node(state, node) do
        {:ok, new_state} ->
          # Optionally add edge from parent
          new_state =
            case Map.get(args, "parent_id") do
              nil ->
                new_state

              parent_id ->
                edge_type = parse_edge_type(Map.get(args, "edge_type", "leads_to"))

                edge =
                  Edge.new(%{
                    from_id: parent_id,
                    to_id: node.id,
                    edge_type: edge_type
                  })

                case store_mod.add_edge(new_state, edge) do
                  {:ok, s} -> s
                  {:error, _} -> new_state
                end
            end

          {:ok, %{status: "recorded", id: node.id, type: "decision", label: node.label},
           config_update(ctx, new_state)}

        {:error, reason} ->
          {:ok, %{status: "error", message: "Failed to record decision: #{inspect(reason)}"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} ->
        {:ok, %{status: "error", message: "Decision system not initialized"}, ContextUpdate.new()}
    end
  end

  @doc """
  Record an outcome node linked to a parent decision or action.
  """
  @spec record_outcome(Nous.Agent.Context.t(), map()) :: {:ok, map(), ContextUpdate.t()}
  def record_outcome(ctx, args) do
    with {:ok, store_mod, state} <- get_store(ctx) do
      status = parse_status(Map.get(args, "status", "completed"))

      node =
        Node.new(%{
          type: :outcome,
          label: Map.fetch!(args, "label"),
          status: status,
          rationale: Map.get(args, "rationale")
        })

      case store_mod.add_node(state, node) do
        {:ok, new_state} ->
          parent_id = Map.fetch!(args, "parent_id")

          edge =
            Edge.new(%{
              from_id: parent_id,
              to_id: node.id,
              edge_type: :leads_to
            })

          new_state =
            case store_mod.add_edge(new_state, edge) do
              {:ok, s} -> s
              {:error, _} -> new_state
            end

          {:ok, %{status: "recorded", id: node.id, type: "outcome", label: node.label},
           config_update(ctx, new_state)}

        {:error, reason} ->
          {:ok, %{status: "error", message: "Failed to record outcome: #{inspect(reason)}"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} ->
        {:ok, %{status: "error", message: "Decision system not initialized"}, ContextUpdate.new()}
    end
  end

  @doc """
  Query the decision graph.
  """
  @spec query_decisions(Nous.Agent.Context.t(), map()) :: {:ok, map(), ContextUpdate.t()}
  def query_decisions(ctx, args) do
    with {:ok, store_mod, state} <- get_store(ctx) do
      query_type = String.to_existing_atom(Map.fetch!(args, "query_type"))

      opts =
        case query_type do
          :recent_decisions ->
            [limit: Map.get(args, "limit", 5)]

          :descendants ->
            [node_id: Map.fetch!(args, "node_id")]

          :ancestors ->
            [node_id: Map.fetch!(args, "node_id")]

          :path_between ->
            [from_id: Map.fetch!(args, "from_id"), to_id: Map.fetch!(args, "to_id")]

          _ ->
            []
        end

      case store_mod.query(state, query_type, opts) do
        {:ok, nodes} ->
          formatted =
            Enum.map(nodes, fn node ->
              %{
                id: node.id,
                type: to_string(node.type),
                label: node.label,
                status: to_string(node.status),
                confidence: node.confidence
              }
            end)

          {:ok, %{status: "found", count: length(formatted), nodes: formatted},
           ContextUpdate.new()}

        {:error, reason} ->
          {:ok, %{status: "error", message: "Query failed: #{inspect(reason)}"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} ->
        {:ok, %{status: "error", message: "Decision system not initialized"}, ContextUpdate.new()}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp get_store(ctx) do
    config = ctx.deps[:decisions_config] || %{}
    store_mod = config[:store]
    store_state = config[:store_state]

    if store_mod && store_state do
      {:ok, store_mod, store_state}
    else
      {:error, :not_initialized}
    end
  end

  defp config_update(ctx, new_state) do
    config = ctx.deps[:decisions_config]
    updated_config = Map.put(config, :store_state, new_state)
    ContextUpdate.new() |> ContextUpdate.set(:decisions_config, updated_config)
  end

  defp parse_edge_type("leads_to"), do: :leads_to
  defp parse_edge_type("chosen"), do: :chosen
  defp parse_edge_type("rejected"), do: :rejected
  defp parse_edge_type("requires"), do: :requires
  defp parse_edge_type("enables"), do: :enables
  defp parse_edge_type("blocks"), do: :blocks
  defp parse_edge_type("supersedes"), do: :supersedes
  defp parse_edge_type(_), do: :leads_to

  defp parse_status("active"), do: :active
  defp parse_status("completed"), do: :completed
  defp parse_status("superseded"), do: :superseded
  defp parse_status("rejected"), do: :rejected
  defp parse_status(_), do: :completed
end
