defmodule DeepResearch.Tools.SearchTools do
  @moduledoc """
  Search tools for deep research: web, news, Wikipedia, and academic sources.

  Falls back to mock data if API keys are not configured.
  """

  require Logger

  @brave_base_url "https://api.search.brave.com/res/v1"
  @wikipedia_base_url "https://en.wikipedia.org/w/api.php"

  @doc """
  Search the web for information.

  ## Parameters
  - query: Search query string (required)
  - count: Number of results (default: 10, max: 20)

  Uses BraveSearch if BRAVE_API_KEY is set, otherwise returns mock results.
  """
  def web_search(ctx, args) do
    query = Map.get(args, "query", "")
    count = Map.get(args, "count", 10) |> min(20) |> max(1)

    if query == "" do
      %{success: false, error: "query is required"}
    else
      api_key = get_brave_api_key(ctx)

      if api_key do
        perform_brave_search(query, api_key, count, "web")
      else
        Logger.debug("BRAVE_API_KEY not set, using mock web search results")
        mock_web_search(query, count)
      end
    end
  end

  @doc """
  Search news articles for recent information.

  ## Parameters
  - query: Search query string (required)
  - count: Number of results (default: 5, max: 20)
  """
  def news_search(ctx, args) do
    query = Map.get(args, "query", "")
    count = Map.get(args, "count", 5) |> min(20) |> max(1)

    if query == "" do
      %{success: false, error: "query is required"}
    else
      api_key = get_brave_api_key(ctx)

      if api_key do
        perform_brave_search(query, api_key, count, "news")
      else
        Logger.debug("BRAVE_API_KEY not set, using mock news results")
        mock_news_search(query, count)
      end
    end
  end

  @doc """
  Search Wikipedia for encyclopedic information.

  ## Parameters
  - query: Search query string (required)
  - limit: Number of results (default: 5, max: 10)

  Uses real Wikipedia API (no key required).
  """
  def wikipedia_search(_ctx, args) do
    query = Map.get(args, "query", "")
    limit = Map.get(args, "limit", 5) |> min(10) |> max(1)

    if query == "" do
      %{success: false, error: "query is required"}
    else
      perform_wikipedia_search(query, limit)
    end
  end

  @doc """
  Search academic sources (mock implementation).

  ## Parameters
  - query: Search query string (required)
  - limit: Number of results (default: 5)

  Note: In production, integrate with Semantic Scholar, arXiv, or Google Scholar APIs.
  """
  def academic_search(_ctx, args) do
    query = Map.get(args, "query", "")
    limit = Map.get(args, "limit", 5) |> min(10) |> max(1)

    if query == "" do
      %{success: false, error: "query is required"}
    else
      mock_academic_search(query, limit)
    end
  end

  # Private: Brave Search API

  defp get_brave_api_key(ctx) do
    ctx.deps[:brave_api_key] || System.get_env("BRAVE_API_KEY")
  end

  defp perform_brave_search(query, api_key, count, search_type) do
    endpoint =
      case search_type do
        "news" -> "#{@brave_base_url}/news/search"
        _ -> "#{@brave_base_url}/web/search"
      end

    params =
      URI.encode_query(%{
        "q" => query,
        "count" => count
      })

    url = "#{endpoint}?#{params}"

    headers = [
      {~c"Accept", ~c"application/json"},
      {~c"X-Subscription-Token", String.to_charlist(api_key)}
    ]

    case :httpc.request(:get, {String.to_charlist(url), headers}, [timeout: 10_000], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        parse_brave_response(to_string(body), query, search_type)

      {:ok, {{_, status, _}, _, body}} ->
        %{
          success: false,
          error: "Brave API returned #{status}",
          details: to_string(body) |> String.slice(0..200)
        }

      {:error, reason} ->
        %{success: false, error: "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp parse_brave_response(body, query, search_type) do
    case Jason.decode(body) do
      {:ok, data} ->
        results_key = if search_type == "news", do: "results", else: "web"
        raw_results = get_in(data, [results_key, "results"]) || []

        results =
          raw_results
          |> Enum.take(20)
          |> Enum.map(fn r ->
            %{
              title: r["title"] || "",
              url: r["url"] || "",
              description: r["description"] || "",
              source: search_type
            }
          end)

        %{
          success: true,
          query: query,
          source: "brave_#{search_type}",
          results: results,
          result_count: length(results)
        }

      {:error, _} ->
        %{success: false, error: "Failed to parse Brave API response"}
    end
  end

  # Private: Wikipedia API

  defp perform_wikipedia_search(query, limit) do
    params =
      URI.encode_query(%{
        "action" => "query",
        "list" => "search",
        "srsearch" => query,
        "srlimit" => limit,
        "format" => "json",
        "origin" => "*"
      })

    url = "#{@wikipedia_base_url}?#{params}"

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 10_000], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        parse_wikipedia_response(to_string(body), query)

      {:ok, {{_, status, _}, _, _}} ->
        %{success: false, error: "Wikipedia API returned #{status}"}

      {:error, reason} ->
        %{success: false, error: "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp parse_wikipedia_response(body, query) do
    case Jason.decode(body) do
      {:ok, data} ->
        raw_results = get_in(data, ["query", "search"]) || []

        results =
          Enum.map(raw_results, fn r ->
            page_id = r["pageid"]

            %{
              title: r["title"] || "",
              url: "https://en.wikipedia.org/wiki/#{URI.encode(r["title"] || "")}",
              description: strip_html(r["snippet"] || ""),
              word_count: r["wordcount"],
              page_id: page_id,
              source: "wikipedia"
            }
          end)

        %{
          success: true,
          query: query,
          source: "wikipedia",
          results: results,
          result_count: length(results)
        }

      {:error, _} ->
        %{success: false, error: "Failed to parse Wikipedia response"}
    end
  end

  defp strip_html(text) do
    text
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  # Mock implementations

  defp mock_web_search(query, count) do
    keywords = query |> String.downcase() |> String.split()
    topic = Enum.take(keywords, 3) |> Enum.join(" ")

    results =
      1..count
      |> Enum.map(fn i ->
        %{
          title: "#{String.capitalize(topic)} - Comprehensive Guide (Part #{i})",
          url: "https://example.com/#{topic |> String.replace(" ", "-")}/article-#{i}",
          description:
            "This is a mock search result about #{topic}. In production, this would contain real search results from Brave Search API.",
          source: "mock_web"
        }
      end)

    %{
      success: true,
      query: query,
      source: "mock_web",
      results: results,
      result_count: length(results),
      note: "Mock data - set BRAVE_API_KEY for real results"
    }
  end

  defp mock_news_search(query, count) do
    keywords = query |> String.downcase() |> String.split()
    topic = Enum.take(keywords, 3) |> Enum.join(" ")

    results =
      1..count
      |> Enum.map(fn i ->
        days_ago = i - 1

        %{
          title: "Breaking: New Developments in #{String.capitalize(topic)}",
          url: "https://news.example.com/#{topic |> String.replace(" ", "-")}/#{i}",
          description:
            "Recent news about #{topic}. Published #{days_ago} days ago. This is mock data.",
          published_date:
            DateTime.utc_now()
            |> DateTime.add(-days_ago * 24 * 3600, :second)
            |> DateTime.to_iso8601(),
          source: "mock_news"
        }
      end)

    %{
      success: true,
      query: query,
      source: "mock_news",
      results: results,
      result_count: length(results),
      note: "Mock data - set BRAVE_API_KEY for real results"
    }
  end

  defp mock_academic_search(query, limit) do
    keywords = query |> String.downcase() |> String.split()
    topic = Enum.take(keywords, 3) |> Enum.join(" ")

    results =
      1..limit
      |> Enum.map(fn i ->
        year = 2025 - rem(i, 5)

        %{
          title: "A Survey of #{String.capitalize(topic)}: Methods and Applications (#{year})",
          authors: ["Smith, J.", "Chen, L.", "Kumar, A."] |> Enum.take(rem(i, 3) + 1),
          year: year,
          abstract:
            "This paper presents a comprehensive survey of #{topic}. We analyze recent advances and identify key challenges...",
          url: "https://arxiv.org/abs/#{year}.#{String.pad_leading("#{i}0001", 5, "0")}",
          citations: 50 + i * 10,
          source: "mock_academic"
        }
      end)

    %{
      success: true,
      query: query,
      source: "mock_academic",
      results: results,
      result_count: length(results),
      note: "Mock data - integrate Semantic Scholar or arXiv API for real results"
    }
  end
end
