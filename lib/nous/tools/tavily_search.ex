defmodule Nous.Tools.TavilySearch do
  @moduledoc """
  Built-in tool for search using Tavily Search API.

  Tavily is purpose-built for AI research and returns clean, pre-extracted
  content from search results (no HTML parsing needed).

  ## Setup

  Get your API key from https://tavily.com and set:

      export TAVILY_API_KEY="your-api-key"

  Or configure in your application:

      config :nous,
        tavily_api_key: System.get_env("TAVILY_API_KEY")

  ## Usage

      agent = Agent.new("openai:gpt-4",
        tools: [&TavilySearch.search/2]
      )
  """

  require Logger

  @api_url "https://api.tavily.com/search"

  @doc """
  Search using Tavily API with AI-optimized results.

  ## Arguments

  - query: The search query (required)
  - search_depth: "basic" or "advanced" (default: "basic")
  - max_results: Number of results (default: 5, max: 10)
  - include_answer: Whether to include a direct answer (default: true)

  ## Returns

  A map with results list and optional direct answer.
  """
  def search(ctx, args) do
    query = Map.get(args, "query") || Map.get(args, "q") || ""
    search_depth = Map.get(args, "search_depth", "basic")
    max_results = Map.get(args, "max_results", 5) |> min(10)
    include_answer = Map.get(args, "include_answer", true)

    api_key = get_api_key(ctx)

    if api_key && api_key != "" do
      case perform_search(query, api_key, search_depth, max_results, include_answer) do
        {:ok, results} ->
          Map.put(results, :success, true)

        {:error, reason} ->
          Logger.error("Tavily search failed: #{inspect(reason)}")
          %{query: query, error: "Search failed: #{inspect(reason)}", success: false}
      end
    else
      %{
        query: query,
        error: "TAVILY_API_KEY not configured. Get your key from https://tavily.com",
        success: false
      }
    end
  end

  defp get_api_key(ctx) do
    ctx.deps[:tavily_api_key] ||
      Application.get_env(:nous, :tavily_api_key) ||
      System.get_env("TAVILY_API_KEY")
  end

  defp perform_search(query, api_key, search_depth, max_results, include_answer) do
    body =
      Jason.encode!(%{
        api_key: api_key,
        query: query,
        search_depth: search_depth,
        max_results: max_results,
        include_answer: include_answer
      })

    Logger.debug("Tavily search: #{query} (depth: #{search_depth}, max: #{max_results})")

    try do
      case Req.post(@api_url,
             body: body,
             headers: [{"content-type", "application/json"}],
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: response}} when is_map(response) ->
          results = parse_results(response)

          {:ok,
           %{
             query: query,
             results: results,
             result_count: length(results),
             answer: Map.get(response, "answer")
           }}

        {:ok, %{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp parse_results(%{"results" => results}) when is_list(results) do
    Enum.map(results, fn result ->
      %{
        url: Map.get(result, "url", ""),
        title: Map.get(result, "title", ""),
        content: Map.get(result, "content", ""),
        score: Map.get(result, "score", 0.0),
        raw_content: Map.get(result, "raw_content")
      }
    end)
  end

  defp parse_results(_), do: []
end
