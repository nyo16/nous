defmodule Nous.Tools.BraveSearch do
  @moduledoc """
  Built-in tool for web search using Brave Search API.

  Brave Search provides high-quality web search results with privacy focus.

  ## Setup

  You need a Brave Search API key to use this tool:

  1. Get your API key from https://brave.com/search/api/
  2. Set the environment variable:

      export BRAVE_API_KEY="your-api-key-here"

  Or configure in your application:

      config :nous,
        brave_api_key: System.get_env("BRAVE_API_KEY")

  ## Rate Limits

  - Free Plan: 1 query/second, up to 2,000 queries/month
  - Base AI Plan: Up to 20 queries/second, 20M queries/month
  - Pro AI Plan: Up to 50 queries/second, unlimited monthly queries

  ## Usage

      agent = Nous.new("lmstudio:qwen3-vl-4b-thinking-mlx",
        tools: [&BraveSearch.web_search/2]
      )

      {:ok, result} = Nous.run(agent, "What's the latest news about AI?")

  The AI will automatically search the web when it needs current information.
  """

  require Logger

  alias Nous.Tools.Search.Common

  @typedoc """
  One web result. Values are copied verbatim out of the Brave JSON payload —
  the keys are what this tool guarantees, not the shape of what Brave puts in
  them. `:age`/`:page_age` are absent from most payloads and come back as nil.
  """
  @type web_result :: %{
          title: term(),
          url: term(),
          description: term(),
          age: term(),
          page_age: term()
        }

  @typedoc """
  One news result. Same caveat as `t:web_result/0` about the values.
  """
  @type news_result :: %{
          title: term(),
          url: term(),
          description: term(),
          age: term(),
          source: term()
        }

  @typedoc """
  The failure envelope `Nous.Tools.Search.Common.run_search/4` returns for a
  missing API key or a failed request.
  """
  @type search_error :: %{query: String.t(), error: String.t(), success: false}

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
  @spec web_search(Nous.RunContext.t(), map()) ::
          %{
            query: String.t(),
            results: [web_result()],
            result_count: non_neg_integer(),
            success: true
          }
          | search_error()
  def web_search(ctx, args) do
    query = Common.query(args)
    # Max 20 results
    count = Map.get(args, "count", 5) |> min(20)
    country = Map.get(args, "country")
    search_lang = Map.get(args, "search_lang")
    safesearch = Map.get(args, "safesearch", "moderate")
    api_key = Common.api_key(ctx, :brave_api_key, "BRAVE_API_KEY")

    opts = [
      missing_key_error:
        "BRAVE_API_KEY not configured. Get your key from https://brave.com/search/api/",
      log_label: "Brave search",
      error_prefix: "Search failed"
    ]

    Common.run_search(query, api_key, opts, fn ->
      with {:ok, results} <-
             perform_search(query, api_key, count, country, search_lang, safesearch) do
        {:ok, %{results: results, result_count: length(results)}}
      end
    end)
  end

  @doc """
  Search for news using Brave Search API.

  ## Arguments

  - query: The search query (required)
  - count: Number of results to return (default: 5, max: 20)
  - country: Country code for localized results
  - search_lang: Language of search
  """
  @spec news_search(Nous.RunContext.t(), map()) ::
          %{
            query: String.t(),
            results: [news_result()],
            result_count: non_neg_integer(),
            success: true
          }
          | search_error()
  def news_search(ctx, args) do
    query = Common.query(args)
    count = Map.get(args, "count", 5) |> min(20)
    country = Map.get(args, "country")
    search_lang = Map.get(args, "search_lang")
    api_key = Common.api_key(ctx, :brave_api_key, "BRAVE_API_KEY")

    opts = [
      missing_key_error: "BRAVE_API_KEY not configured",
      log_label: "Brave news search",
      error_prefix: "News search failed"
    ]

    Common.run_search(query, api_key, opts, fn ->
      with {:ok, results} <- perform_news_search(query, api_key, count, country, search_lang) do
        {:ok, %{results: results, result_count: length(results)}}
      end
    end)
  end

  # Private functions

  defp perform_search(query, api_key, count, country, search_lang, safesearch) do
    url = "https://api.search.brave.com/res/v1/web/search"

    params = build_search_params(query, count, country, search_lang, safesearch)

    Logger.debug("Brave search: #{query} (#{count} results)")
    do_brave_request(url, params, api_key, &parse_web_results/1, "web")
  end

  defp perform_news_search(query, api_key, count, country, search_lang) do
    url = "https://api.search.brave.com/res/v1/news/search"

    params =
      %{
        "q" => query,
        "count" => count
      }
      |> maybe_add_param("country", country)
      |> maybe_add_param("search_lang", search_lang)

    Logger.debug("Brave news search: #{query} (#{count} results)")
    do_brave_request(url, params, api_key, &parse_news_results/1, "news")
  end

  # L-5: switched from raw :httpc (which defaults to NO TLS verification
  # and doesn't share Nous's Finch pool) to Req. The previous code path
  # accepted MITM-altered TLS connections and would silently leak the
  # Brave API key to any attacker on-path.
  #
  # retry: false — Req's default `:safe_transient` turns one agent tool call
  # into up to 4 GETs against a metered API on any 429/5xx. A 429 here means
  # the subscription quota is spent, so retrying behind the model's back only
  # burns the quota faster and stretches the tool call across the backoff.
  # Surfacing the error lets the agent decide.
  defp do_brave_request(url, params, api_key, parse_results, label) do
    case Req.get(url,
           params: params,
           headers: [
             {"x-subscription-token", api_key},
             {"accept", "application/json"}
           ],
           connect_options: [transport_opts: [verify: :verify_peer]],
           receive_timeout: 15_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, parse_results.(body)}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case JSON.decode(body) do
          {:ok, response} ->
            {:ok, parse_results.(response)}

          {:error, decode_error} ->
            Logger.error(
              "Failed to decode Brave #{label} search response: #{inspect(decode_error)}"
            )

            {:error, "Invalid JSON response from Brave API"}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

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

  defp parse_web_results(response) do
    response
    |> get_in(["web", "results"])
    |> Common.map_results(
      title: {"title", ""},
      url: {"url", ""},
      description: {"description", ""},
      age: "age",
      page_age: "page_age"
    )
  end

  defp parse_news_results(response) do
    response
    |> Map.get("results")
    |> Common.map_results(
      title: {"title", ""},
      url: {"url", ""},
      description: {"description", ""},
      age: "age",
      source: "source"
    )
  end
end
