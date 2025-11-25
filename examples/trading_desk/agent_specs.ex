defmodule TradingDesk.AgentSpecs do
  @moduledoc """
  Specifications for all trading desk agents.
  """

  alias TradingDesk.Tools.{Market, Risk, Trading, Research}

  def all_agents do
    [
      market_analyst(),
      risk_manager(),
      trading_executor(),
      research_analyst()
    ]
  end

  def market_analyst do
    %{
      id: :market_analyst,
      name: "Market Analyst",
      description: """
      Analyzes market data, price trends, technical indicators, chart patterns,
      volume analysis, and market sentiment. Expert in technical analysis and
      real-time market conditions.
      """,
      model: "anthropic:claude-sonnet-4-5-20250929",
      instructions: """
      You are an expert market analyst specializing in technical analysis.
      Use the provided tools to analyze market data, price trends, and technical indicators.
      Provide clear, data-driven insights with specific numbers and recommendations.
      Focus on short to medium-term trading opportunities.
      """,
      tools: [
        &Market.get_market_data/2,
        &Market.get_price_history/2,
        &Market.get_technical_indicators/2,
        &Market.get_market_sentiment/2
      ]
    }
  end

  def risk_manager do
    %{
      id: :risk_manager,
      name: "Risk Manager",
      description: """
      Evaluates trading risk, calculates position sizing, sets stop losses,
      assesses portfolio exposure, calculates Value at Risk (VaR), validates
      trade compliance, and ensures risk management rules are followed.
      """,
      model: "anthropic:claude-sonnet-4-5-20250929",
      instructions: """
      You are a risk management specialist focused on protecting capital.
      Use the tools to calculate position sizes, assess risk levels, and validate trades.
      Always prioritize capital preservation and proper risk-reward ratios.
      Provide specific stop loss and take profit levels.
      Flag any trades that violate risk management rules.
      """,
      tools: [
        &Risk.calculate_position_size/2,
        &Risk.calculate_var/2,
        &Risk.check_exposure/2,
        &Risk.validate_trade/2,
        &Risk.calculate_stop_take/2
      ]
    }
  end

  def trading_executor do
    %{
      id: :trading_executor,
      name: "Trading Executor",
      description: """
      Executes trades, manages orders, checks account balance, monitors open
      positions, places buy/sell orders, and cancels pending orders. Handles
      order execution and portfolio management.
      """,
      model: "lmstudio:qwen/qwen3-30b-a3b-2507",  # Fast model for execution
      instructions: """
      You are a trading execution specialist.
      Use the tools to check account status, view positions, and execute trades.
      Always confirm order details before execution.
      Report the current account status and position information clearly.
      Be precise with numbers and order details.
      """,
      tools: [
        &Trading.get_account_balance/2,
        &Trading.get_open_positions/2,
        &Trading.place_order/2,
        &Trading.get_pending_orders/2,
        &Trading.cancel_order/2
      ]
    }
  end

  def research_analyst do
    %{
      id: :research_analyst,
      name: "Research Analyst",
      description: """
      Researches companies, analyzes fundamentals, evaluates earnings reports,
      reads news, assesses long-term value, reviews financial statements, and
      provides fundamental analysis for investment decisions.
      """,
      model: "anthropic:claude-sonnet-4-5-20250929",
      instructions: """
      You are a fundamental research analyst focused on long-term value.
      Use the tools to research company fundamentals, earnings, and news.
      Provide thorough analysis of business quality, financial health, and valuation.
      Consider both quantitative metrics and qualitative factors.
      Think long-term and focus on sustainable competitive advantages.
      """,
      tools: [
        &Research.get_company_info/2,
        &Research.get_news/2,
        &Research.get_earnings/2,
        &Research.search_research/2
      ]
    }
  end

  @doc "Get agent spec by ID"
  def get_spec(agent_id) do
    Enum.find(all_agents(), &(&1.id == agent_id))
  end
end
