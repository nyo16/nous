defmodule TradingDesk.Router do
  @moduledoc """
  Routes user queries to appropriate specialist agents.

  Uses simple keyword matching initially.
  Can be upgraded to embeddings-based routing in the future.
  """

  alias TradingDesk.AgentSpecs

  @doc """
  Analyze a query and determine which agents should handle it.

  Returns a list of agent IDs that should process the query.
  """
  def route_query(query) do
    query_lower = String.downcase(query)

    agents = []

    # Get all agent specs with their keywords
    specs = [
      {AgentSpecs.market_analyst(), ["price", "chart", "trend", "technical", "indicator", "sentiment", "volume", "moving average"]},
      {AgentSpecs.risk_manager(), ["risk", "stop loss", "take profit", "exposure", "var", "position size", "risk management"]},
      {AgentSpecs.trading_executor(), ["buy", "sell", "execute", "order", "balance", "position", "portfolio", "account"]},
      {AgentSpecs.research_analyst(), ["company", "earnings", "fundamental", "news", "research", "valuation", "financial"]}
    ]

    # Score each agent based on keyword matches
    scores =
      Enum.map(specs, fn {spec, keywords} ->
        score = count_keyword_matches(query_lower, keywords)
        {spec.id, spec.name, score}
      end)

    # Select agents with score > 0, or default to market analyst
    selected =
      scores
      |> Enum.filter(fn {_id, _name, score} -> score > 0 end)
      |> Enum.sort_by(fn {_id, _name, score} -> score end, :desc)
      |> Enum.map(fn {id, name, score} -> {id, name, score} end)

    case selected do
      [] ->
        # No matches, default to market analyst
        [{:market_analyst, "Market Analyst", 0}]

      agents ->
        # Return top agents (max 3)
        Enum.take(agents, 3)
    end
  end

  @doc """
  Explain why agents were selected.
  """
  def explain_routing(query) do
    routed_agents = route_query(query)

    explanation =
      routed_agents
      |> Enum.map(fn {id, name, score} ->
        "#{name} (relevance: #{score})"
      end)
      |> Enum.join(", ")

    "Routing to: #{explanation}"
  end

  # Private functions

  defp count_keyword_matches(query, keywords) do
    Enum.count(keywords, fn keyword ->
      String.contains?(query, keyword)
    end)
  end

  @doc """
  Future: Embeddings-based routing.

  This is a placeholder for future semantic routing using embeddings.
  """
  def route_query_with_embeddings(query) do
    # TODO: Future implementation
    # 1. Get query embedding: embedding = Embeddings.get(query)
    # 2. Compare with agent description embeddings
    # 3. Use cosine similarity
    # 4. Return top N agents
    #
    # For now, fallback to keyword matching
    route_query(query)
  end
end
