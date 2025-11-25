defmodule Yggdrasil.Tools.BraveSearch do
  @moduledoc """
  Built-in tool for web search using Brave Search API.

  Brave Search provides high-quality web search results with privacy focus.

  ## Setup

  You need a Brave Search API key to use this tool:

  1. Get your API key from https://brave.com/search/api/
  2. Set the environment variable:

      export BRAVE_API_KEY="your-api-key-here"

  Or configure in your application:

      config :yggdrasil,
        brave_api_key: System.get_env("BRAVE_API_KEY")

  ## Rate Limits

  - Free Plan: 1 query/second, up to 2,000 queries/month
  - Base AI Plan: Up to 20 queries/second, 20M queries/month
  - Pro AI Plan: Up to 50 queries/second, unlimited monthly queries

  ## Usage

      agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
        tools: [&BraveSearch.web_search/2]
      )

      {:ok, result} = Yggdrasil.run(agent, "What's the latest news about AI?")

  The AI will automatically search the web when it needs current information.
  """

  require Logger

  @doc """
  Search the web using Brave Search API.

  ## Arguments

  - query: The search query (required)
  - count: Number of results to return (default: 5, max: 20)
  - country: Country code for localized results (e.g., "US", "GB", "DE")
  - search_lang: Language of search (e.g., "en", "es", "fr")
  - safesearch: "off", "moderate", or "strict" (default: "moderate")

  ## Returns

  A map containing:
  - query: The search query used
  - results: List of search results with title, url, description
  - result_count: Number of results returned
  - success: Whether the search succeeded
  """
  def web_search(ctx, args) do
    # Support both "query" and "q" parameter names
    query = Map.get(args, "query") || Map.get(args, "q") || ""
    count = Map.get(args, "count", 5) |> min(20)  # Max 20 results
    country = Map.get(args, "country")
    search_lang = Map.get(args, "search_lang")
    safesearch = Map.get(args, "safesearch", "moderate")

    # Get API key from context or environment
    api_key = get_api_key(ctx)

    if api_key && api_key != "" do
      case perform_search(query, api_key, count, country, search_lang, safesearch) do
        {:ok, results} ->
          %{
            query: query,
            results: results,
            result_count: length(results),
            success: true
          }

        {:error, reason} ->
          Logger.error("Brave search failed: #{inspect(reason)}")
          %{
            query: query,
            error: "Search failed: #{inspect(reason)}",
            success: false
          }
      end
    else
      %{
        query: query,
        error: "BRAVE_API_KEY not configured. Get your key from https://brave.com/search/api/",
        success: false
      }
    end
  end

  @doc """
  Search for news using Brave Search API.

  ## Arguments

  - query: The search query (required)
  - count: Number of results to return (default: 5, max: 20)
  - country: Country code for localized results
  - search_lang: Language of search
  """
  def news_search(ctx, args) do
    # Support both "query" and "q" parameter names
    query = Map.get(args, "query") || Map.get(args, "q") || ""
    count = Map.get(args, "count", 5) |> min(20)
    country = Map.get(args, "country")
    search_lang = Map.get(args, "search_lang")

    api_key = get_api_key(ctx)

    if api_key && api_key != "" do
      case perform_news_search(query, api_key, count, country, search_lang) do
        {:ok, results} ->
          %{
            query: query,
            results: results,
            result_count: length(results),
            success: true
          }

        {:error, reason} ->
          Logger.error("Brave news search failed: #{inspect(reason)}")
          %{
            query: query,
            error: "News search failed: #{inspect(reason)}",
            success: false
          }
      end
    else
      %{
        query: query,
        error: "BRAVE_API_KEY not configured",
        success: false
      }
    end
  end

  # Private functions

  defp get_api_key(ctx) do
    # Try context first, then config, then environment
    (ctx.deps[:brave_api_key] ||
     Application.get_env(:yggdrasil, :brave_api_key) ||
     System.get_env("BRAVE_API_KEY"))
  end

  defp perform_search(query, api_key, count, country, search_lang, safesearch) do
    url = "https://api.search.brave.com/res/v1/web/search"

    params = build_search_params(query, count, country, search_lang, safesearch)

    headers = [
      {~c"X-Subscription-Token", String.to_charlist(api_key)},
      {~c"Accept", ~c"application/json"}
    ]

    Logger.debug("Brave search: #{query} (#{count} results)")

    full_url = url <> "?" <> URI.encode_query(params)

    case :httpc.request(:get, {String.to_charlist(full_url), headers}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        response = Jason.decode!(to_string(body))
        results = parse_web_results(response)
        {:ok, results}

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, "HTTP #{status}: #{to_string(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_news_search(query, api_key, count, country, search_lang) do
    url = "https://api.search.brave.com/res/v1/news/search"

    params = %{
      "q" => query,
      "count" => count
    }
    |> maybe_add_param("country", country)
    |> maybe_add_param("search_lang", search_lang)

    headers = [
      {~c"X-Subscription-Token", String.to_charlist(api_key)},
      {~c"Accept", ~c"application/json"}
    ]

    Logger.debug("Brave news search: #{query} (#{count} results)")

    full_url = url <> "?" <> URI.encode_query(params)

    case :httpc.request(:get, {String.to_charlist(full_url), headers}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        response = Jason.decode!(to_string(body))
        results = parse_news_results(response)
        {:ok, results}

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, "HTTP #{status}: #{to_string(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_search_params(query, count, country, search_lang, safesearch) do
    %{
      "q" => query,
      "count" => count,
      "safesearch" => safesearch
    }
    |> maybe_add_param("country", country)
    |> maybe_add_param("search_lang", search_lang)
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Map.put(params, key, value)

  defp parse_web_results(%{"web" => %{"results" => results}}) when is_list(results) do
    Enum.map(results, fn result ->
      %{
        title: Map.get(result, "title", ""),
        url: Map.get(result, "url", ""),
        description: Map.get(result, "description", ""),
        age: Map.get(result, "age"),
        page_age: Map.get(result, "page_age")
      }
    end)
  end

  defp parse_web_results(_response), do: []

  defp parse_news_results(%{"results" => results}) when is_list(results) do
    Enum.map(results, fn result ->
      %{
        title: Map.get(result, "title", ""),
        url: Map.get(result, "url", ""),
        description: Map.get(result, "description", ""),
        age: Map.get(result, "age"),
        source: Map.get(result, "source")
      }
    end)
  end

  defp parse_news_results(_response), do: []
end
