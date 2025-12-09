defmodule TradingDesk do
  @moduledoc """
  Multi-agent trading desk system.

  A sophisticated example demonstrating:
  - Multiple specialized AI agents working together
  - Agent orchestration and coordination
  - Tool calling across different domains
  - Message routing and aggregation

  ## Architecture

  The trading desk consists of:
  - **Coordinator**: Routes queries and synthesizes responses
  - **Market Analyst**: Technical analysis and market data
  - **Risk Manager**: Risk assessment and position sizing
  - **Trading Executor**: Order execution and portfolio management
  - **Research Analyst**: Fundamental analysis and company research

  ## Usage

      # Start the trading desk
      {:ok, _pid} = TradingDesk.start()

      # Ask a question - automatically routed to appropriate agents
      {:ok, response} = TradingDesk.query("Should I buy AAPL?")
      IO.puts(response.synthesized_response)

      # Direct agent access
      {:ok, response} = TradingDesk.ask_agent(:market_analyst, "Analyze TSLA")

      # Get trading desk status
      status = TradingDesk.status()

  """

  alias TradingDesk.{Supervisor, Coordinator, AgentServer}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the trading desk supervisor.

  This starts all agents and makes them ready to receive queries.
  """
  def start(opts \\ []) do
    Supervisor.start_link(opts)
  end

  @doc """
  Stop the trading desk.
  """
  def stop do
    Supervisor.stop(TradingDesk.Supervisor)
  end

  @doc """
  Process a query through the trading desk.

  The coordinator will automatically route to appropriate specialists
  and synthesize their responses.

  ## Examples

      {:ok, result} = TradingDesk.query("Should I buy AAPL?")
      IO.puts(result.synthesized_response)

      {:ok, result} = TradingDesk.query("What's the risk of buying 100 shares of TSLA?")

  """
  def query(user_query, opts \\ []) do
    Coordinator.process_query(user_query, opts)
  end

  @doc """
  Ask a specific agent directly (bypass coordinator).

  ## Examples

      {:ok, result} = TradingDesk.ask_agent(:market_analyst, "Analyze AAPL trend")
      {:ok, result} = TradingDesk.ask_agent(:risk_manager, "Calculate position size for TSLA")

  """
  def ask_agent(agent_id, query, opts \\ []) do
    AgentServer.query(agent_id, query, opts)
  end

  @doc """
  Get information about an agent.

  ## Examples

      info = TradingDesk.agent_info(:market_analyst)
      IO.inspect(info)

  """
  def agent_info(agent_id) do
    AgentServer.info(agent_id)
  end

  @doc """
  Get status of the entire trading desk.

  Returns information about all agents and their current state.
  """
  def status do
    agents = [:market_analyst, :risk_manager, :trading_executor, :research_analyst]

    agent_statuses =
      Enum.map(agents, fn id ->
        case AgentServer.info(id) do
          info when is_map(info) -> {id, info}
          _ -> {id, %{status: :error}}
        end
      end)
      |> Map.new()

    %{
      status: :running,
      agents: agent_statuses,
      total_agents: length(agents),
      started_at: get_supervisor_start_time()
    }
  end

  @doc """
  Multi-agent workflow: Analyze a potential trade.

  This is a structured workflow that queries specific agents in order.

  ## Examples

      {:ok, analysis} = TradingDesk.analyze_trade(
        symbol: "AAPL",
        quantity: 100,
        entry_price: 178.50
      )

  """
  def analyze_trade(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    quantity = Keyword.get(opts, :quantity, 100)
    entry_price = Keyword.get(opts, :entry_price)

    query = "Analyze #{symbol}: Should I buy #{quantity} shares" <>
            if(entry_price, do: " at $#{entry_price}?", else: "?")

    # Route to market analyst, risk manager, and research analyst
    tasks = [
      Task.async(fn ->
        {:ok, result} = AgentServer.query(:market_analyst,
          "Analyze #{symbol} current price, trend, and technical indicators"
        )
        {:market_analysis, result.output, result.usage}
      end),
      Task.async(fn ->
        {:ok, result} = AgentServer.query(:risk_manager,
          "Assess risk for buying #{quantity} shares of #{symbol}. Calculate position size and stop loss."
        )
        {:risk_analysis, result.output, result.usage}
      end),
      Task.async(fn ->
        {:ok, result} = AgentServer.query(:research_analyst,
          "Research #{symbol} fundamentals, recent news, and long-term outlook"
        )
        {:research_analysis, result.output, result.usage}
      end)
    ]

    results = Task.await_many(tasks, 90_000)

    # Aggregate results
    %{
      symbol: symbol,
      quantity: quantity,
      entry_price: entry_price,
      analyses: Enum.into(results, %{}),
      timestamp: DateTime.utc_now()
    }
  end

  # Private helpers

  defp get_supervisor_start_time do
    # This is a simplification - in production you'd track this properly
    DateTime.utc_now()
  end
end
