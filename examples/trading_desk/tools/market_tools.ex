defmodule TradingDesk.Tools.Market do
  @moduledoc """
  Mock market data tools for market analyst agent.
  """

  @doc """
  Get current market data for a symbol.

  ## Parameters
  - symbol: Stock ticker symbol (e.g., "AAPL", "TSLA")
  """
  def get_market_data(_ctx, args) do
    symbol = Map.get(args, "symbol", "UNKNOWN")

    # Mock market data
    mock_data = %{
      "AAPL" => %{symbol: "AAPL", price: 178.50, change: 2.30, change_pct: 1.31, volume: 52_400_000, market_cap: "2.8T"},
      "TSLA" => %{symbol: "TSLA", price: 242.80, change: -5.20, change_pct: -2.10, volume: 98_200_000, market_cap: "771B"},
      "GOOGL" => %{symbol: "GOOGL", price: 142.30, change: 1.80, change_pct: 1.28, volume: 28_900_000, market_cap: "1.8T"},
      "NVDA" => %{symbol: "NVDA", price: 495.20, change: 12.50, change_pct: 2.59, volume: 156_300_000, market_cap: "1.2T"},
      "MSFT" => %{symbol: "MSFT", price: 378.90, change: 3.10, change_pct: 0.82, volume: 24_100_000, market_cap: "2.8T"}
    }

    Map.get(mock_data, symbol, %{
      symbol: symbol,
      price: 100.0,
      change: 0.0,
      change_pct: 0.0,
      volume: 1_000_000,
      market_cap: "Unknown"
    })
  end

  @doc """
  Get price history for a symbol.

  ## Parameters
  - symbol: Stock ticker
  - days: Number of days (default: 30)
  """
  def get_price_history(_ctx, args) do
    symbol = Map.get(args, "symbol", "UNKNOWN")
    days = Map.get(args, "days", 30)

    # Generate mock historical data
    current_price = get_market_data(nil, %{"symbol" => symbol}).price

    history =
      for day <- days..1 do
        # Random walk from current price
        variance = :rand.uniform() * 10 - 5
        price = current_price + variance

        %{
          date: Date.add(Date.utc_today(), -day),
          open: price - 1,
          high: price + 2,
          low: price - 2,
          close: price,
          volume: :rand.uniform(100_000_000)
        }
      end

    %{
      symbol: symbol,
      period_days: days,
      data_points: length(history),
      history: Enum.take(history, 5)  # Return sample
    }
  end

  @doc """
  Get technical indicators for a symbol.

  ## Parameters
  - symbol: Stock ticker
  """
  def get_technical_indicators(_ctx, args) do
    symbol = Map.get(args, "symbol", "UNKNOWN")

    # Mock technical indicators
    %{
      symbol: symbol,
      rsi: 62.5,
      macd: %{value: 1.23, signal: 0.98, histogram: 0.25},
      moving_averages: %{
        sma_20: 175.30,
        sma_50: 172.80,
        sma_200: 168.50
      },
      bollinger_bands: %{
        upper: 182.00,
        middle: 175.30,
        lower: 168.60
      },
      trend: "bullish",
      support_levels: [170.00, 165.00],
      resistance_levels: [180.00, 185.00]
    }
  end

  @doc """
  Get market sentiment for a symbol.

  ## Parameters
  - symbol: Stock ticker
  """
  def get_market_sentiment(_ctx, args) do
    symbol = Map.get(args, "symbol", "UNKNOWN")

    sentiments = ["bullish", "bearish", "neutral"]
    sentiment = Enum.random(sentiments)

    %{
      symbol: symbol,
      sentiment: sentiment,
      score: :rand.uniform() * 2 - 1,  # -1 to 1
      analyst_ratings: %{
        buy: :rand.uniform(20),
        hold: :rand.uniform(15),
        sell: :rand.uniform(5)
      },
      social_sentiment: %{
        positive: :rand.uniform(100),
        negative: :rand.uniform(50),
        neutral: :rand.uniform(30)
      }
    }
  end
end
