defmodule TradingDesk.Tools.Research do
  @moduledoc """
  Mock research tools for research analyst agent.
  """

  @doc """
  Get company fundamental information.

  ## Parameters
  - symbol: Stock ticker
  """
  def get_company_info(_ctx, args) do
    symbol = Map.get(args, "symbol", "UNKNOWN")

    mock_data = %{
      "AAPL" => %{
        symbol: "AAPL",
        name: "Apple Inc.",
        sector: "Technology",
        industry: "Consumer Electronics",
        pe_ratio: 29.5,
        eps: 6.05,
        revenue: "383.9B",
        profit_margin: 25.3,
        dividend_yield: 0.52,
        beta: 1.25
      },
      "TSLA" => %{
        symbol: "TSLA",
        name: "Tesla Inc.",
        sector: "Automotive",
        industry: "Electric Vehicles",
        pe_ratio: 75.2,
        eps: 3.23,
        revenue: "96.8B",
        profit_margin: 15.5,
        dividend_yield: 0.0,
        beta: 2.01
      }
    }

    Map.get(mock_data, symbol, %{
      symbol: symbol,
      name: "#{symbol} Corporation",
      sector: "Unknown",
      pe_ratio: 20.0,
      eps: 2.50
    })
  end

  @doc """
  Get recent news for a symbol.

  ## Parameters
  - symbol: Stock ticker
  - limit: Number of news items (default: 5)
  """
  def get_news(_ctx, args) do
    symbol = Map.get(args, "symbol", "UNKNOWN")
    limit = Map.get(args, "limit", 5)

    # Mock news
    news_templates = [
      "#{symbol} announces record quarterly earnings, beats analyst expectations",
      "#{symbol} stock upgraded to 'buy' by major investment firm",
      "CEO of #{symbol} discusses future growth strategy in interview",
      "#{symbol} launches new product line, market reacts positively",
      "Analysts raise price target for #{symbol} following strong results"
    ]

    news =
      news_templates
      |> Enum.take(limit)
      |> Enum.with_index()
      |> Enum.map(fn {headline, idx} ->
        %{
          headline: headline,
          published: DateTime.add(DateTime.utc_now(), -idx * 3600, :second),
          source: Enum.random(["Bloomberg", "Reuters", "CNBC", "WSJ"]),
          sentiment: Enum.random(["positive", "neutral", "negative"])
        }
      end)

    %{
      symbol: symbol,
      count: length(news),
      news: news
    }
  end

  @doc """
  Get earnings information.

  ## Parameters
  - symbol: Stock ticker
  """
  def get_earnings(_ctx, args) do
    symbol = Map.get(args, "symbol", "UNKNOWN")

    %{
      symbol: symbol,
      last_quarter: %{
        date: "2025-07-15",
        revenue: "85.8B",
        earnings: "21.5B",
        eps: 1.52,
        beat_estimates: true,
        surprise_percent: 3.5
      },
      next_earnings_date: "2025-10-28",
      guidance: %{
        revenue_estimate: "88-92B",
        eps_estimate: 1.58,
        outlook: "positive"
      },
      analyst_consensus: %{
        rating: "buy",
        price_target: 195.00,
        upside_percent: 9.2
      }
    }
  end

  @doc """
  Search research database.

  ## Parameters
  - query: Search query
  """
  def search_research(_ctx, args) do
    query = Map.get(args, "query", "")

    # Mock research results
    results = [
      %{
        title: "Tech Sector Analysis Q4 2025",
        type: "sector_report",
        date: "2025-10-01",
        summary: "Technology sector shows continued strength with AI-driven growth..."
      },
      %{
        title: "Semiconductor Industry Outlook",
        type: "industry_report",
        date: "2025-09-15",
        summary: "Strong demand for AI chips driving semiconductor growth..."
      },
      %{
        title: "Economic Indicators Update",
        type: "macro_analysis",
        date: "2025-10-05",
        summary: "Federal Reserve maintains rates, inflation trending lower..."
      }
    ]

    %{
      query: query,
      results: results,
      count: length(results)
    }
  end
end
