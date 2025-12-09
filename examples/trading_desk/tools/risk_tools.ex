defmodule TradingDesk.Tools.Risk do
  @moduledoc """
  Mock risk management tools for risk manager agent.
  """

  @doc """
  Calculate position size based on risk parameters.

  ## Parameters
  - capital: Total trading capital
  - risk_percent: Percentage of capital to risk (e.g., 2.0 for 2%)
  - stop_loss_percent: Stop loss percentage from entry
  """
  def calculate_position_size(_ctx, args) do
    capital = Map.get(args, "capital", 100_000)
    risk_percent = Map.get(args, "risk_percent", 1.0)
    stop_loss_percent = Map.get(args, "stop_loss_percent", 5.0)

    # Calculate position size
    risk_amount = capital * (risk_percent / 100)
    position_size = risk_amount / (stop_loss_percent / 100)

    %{
      capital: capital,
      risk_percent: risk_percent,
      risk_amount: risk_amount,
      stop_loss_percent: stop_loss_percent,
      recommended_position_size: position_size,
      shares: floor(position_size / 150)  # Assuming $150/share
    }
  end

  @doc """
  Calculate Value at Risk (VaR) for a portfolio.

  ## Parameters
  - portfolio: List of positions
  - confidence: Confidence level (e.g., 95, 99)
  """
  def calculate_var(_ctx, args) do
    portfolio = Map.get(args, "portfolio", [])
    confidence = Map.get(args, "confidence", 95)

    # Mock VaR calculation
    total_value = Enum.reduce(portfolio, 0, fn pos, acc ->
      acc + Map.get(pos, "value", 10_000)
    end)

    var_percent = case confidence do
      99 -> 5.5
      95 -> 3.2
      90 -> 2.1
      _ -> 3.0
    end

    %{
      portfolio_value: total_value,
      confidence_level: confidence,
      var_amount: total_value * (var_percent / 100),
      var_percent: var_percent,
      risk_level: if(var_percent > 4, do: "high", else: "moderate")
    }
  end

  @doc """
  Check portfolio exposure to a specific symbol or sector.

  ## Parameters
  - portfolio: Current portfolio
  - symbol: Symbol to check exposure
  """
  def check_exposure(_ctx, args) do
    symbol = Map.get(args, "symbol", "AAPL")
    portfolio = Map.get(args, "portfolio", [])

    # Mock exposure calculation
    total_value = 250_000
    position_value = 45_000
    exposure_percent = (position_value / total_value) * 100

    %{
      symbol: symbol,
      position_value: position_value,
      portfolio_value: total_value,
      exposure_percent: exposure_percent,
      recommendation: if(exposure_percent > 20, do: "reduce", else: "acceptable"),
      max_recommended_percent: 15.0
    }
  end

  @doc """
  Validate if a trade meets risk management rules.

  ## Parameters
  - trade: Trade details (symbol, quantity, price, type)
  """
  def validate_trade(_ctx, args) do
    symbol = Map.get(args, "symbol", "UNKNOWN")
    quantity = Map.get(args, "quantity", 0)
    price = Map.get(args, "price", 0)
    trade_type = Map.get(args, "type", "buy")

    trade_value = quantity * price

    # Mock validation rules
    checks = %{
      position_size_ok: trade_value < 50_000,
      diversification_ok: true,
      leverage_ok: true,
      liquidity_ok: quantity < 1000,
      compliance_ok: true
    }

    all_passed = Enum.all?(checks, fn {_k, v} -> v end)

    %{
      symbol: symbol,
      trade_value: trade_value,
      type: trade_type,
      checks: checks,
      approved: all_passed,
      message: if(all_passed, do: "Trade approved", else: "Trade rejected - review required")
    }
  end

  @doc """
  Calculate stop loss and take profit levels.

  ## Parameters
  - entry_price: Entry price for position
  - risk_reward_ratio: Risk/reward ratio (e.g., 2.0 for 1:2)
  - stop_loss_percent: Stop loss percentage
  """
  def calculate_stop_take(_ctx, args) do
    entry_price = Map.get(args, "entry_price", 100.0)
    risk_reward_ratio = Map.get(args, "risk_reward_ratio", 2.0)
    stop_loss_percent = Map.get(args, "stop_loss_percent", 5.0)

    stop_loss = entry_price * (1 - stop_loss_percent / 100)
    risk_amount = entry_price - stop_loss
    take_profit = entry_price + (risk_amount * risk_reward_ratio)

    %{
      entry_price: entry_price,
      stop_loss: stop_loss,
      take_profit: take_profit,
      risk_amount: risk_amount,
      reward_amount: take_profit - entry_price,
      risk_reward_ratio: risk_reward_ratio
    }
  end
end
