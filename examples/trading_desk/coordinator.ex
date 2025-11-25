defmodule TradingDesk.Coordinator do
  @moduledoc """
  Coordinator agent that orchestrates specialist agents.

  Responsibilities:
  - Receives user queries
  - Routes to specialist agents
  - Aggregates responses
  - Synthesizes final answer
  """

  use GenServer
  require Logger

  alias TradingDesk.{Router, AgentServer}
  alias Yggdrasil.Agent

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    name = {:via, Registry, {TradingDesk.Registry, :coordinator}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Process a user query by coordinating specialist agents"
  def process_query(query, opts \\ []) do
    via_name = {:via, Registry, {TradingDesk.Registry, :coordinator}}
    GenServer.call(via_name, {:process_query, query, opts}, 120_000)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Coordinator doesn't use Yggdrasil agent - it's pure orchestration logic
    state = %{
      query_count: 0,
      created_at: DateTime.utc_now()
    }

    Logger.info("[TradingDesk] Coordinator started")

    {:ok, state}
  end

  @impl true
  def handle_call({:process_query, query, _opts}, _from, state) do
    Logger.info("[Coordinator] Processing query: #{String.slice(query, 0..60)}...")

    # 1. Route query to appropriate agents
    routed_agents = Router.route_query(query)

    Logger.info("[Coordinator] #{Router.explain_routing(query)}")

    # 2. Query each specialist agent in parallel
    tasks =
      Enum.map(routed_agents, fn {agent_id, agent_name, _score} ->
        Task.async(fn ->
          Logger.debug("[Coordinator] Querying #{agent_name}...")

          case AgentServer.query(agent_id, query) do
            {:ok, result} ->
              Logger.debug("[Coordinator] #{agent_name} responded (#{result.usage.total_tokens} tokens)")
              {:ok, agent_id, agent_name, result.output, result.usage}

            {:error, error} ->
              Logger.error("[Coordinator] #{agent_name} failed: #{inspect(error)}")
              {:error, agent_id, agent_name, error}
          end
        end)
      end)

    # 3. Wait for all responses (with timeout)
    responses =
      tasks
      |> Task.await_many(90_000)
      |> Enum.filter(fn
        {:ok, _, _, _, _} -> true
        _ -> false
      end)

    # 4. Synthesize final response
    final_response = synthesize_responses(query, responses)

    # 5. Calculate total usage
    total_usage =
      responses
      |> Enum.reduce(%{requests: 0, tool_calls: 0, total_tokens: 0}, fn {:ok, _, _, _, usage},
                                                                          acc ->
        %{
          requests: acc.requests + usage.requests,
          tool_calls: acc.tool_calls + usage.tool_calls,
          total_tokens: acc.total_tokens + usage.total_tokens
        }
      end)

    result = %{
      query: query,
      agents_consulted: Enum.map(responses, fn {:ok, id, name, _, _} -> {id, name} end),
      individual_responses: Enum.map(responses, fn {:ok, id, name, resp, _} -> {name, resp} end),
      synthesized_response: final_response,
      usage: total_usage
    }

    {:reply, {:ok, result}, %{state | query_count: state.query_count + 1}}
  end

  # Private functions

  defp synthesize_responses(query, responses) do
    if Enum.empty?(responses) do
      "No specialist agents were able to process this query."
    else
      # Build synthesis from all responses
      parts = [
        "📊 Trading Desk Analysis",
        "",
        "Query: #{query}",
        "",
        "Specialist Insights:",
        ""
      ]

      # Add each agent's response
      specialist_parts =
        responses
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {{:ok, _id, name, response, usage}, idx} ->
          [
            "#{idx}. #{name}:",
            response,
            "(#{usage.tool_calls} tool calls, #{usage.total_tokens} tokens)",
            ""
          ]
        end)

      parts = parts ++ specialist_parts

      # Add summary
      parts =
        parts ++
          [
            "---",
            "",
            "Summary: Consulted #{length(responses)} specialist(s) for comprehensive analysis."
          ]

      Enum.join(parts, "\n")
    end
  end
end
