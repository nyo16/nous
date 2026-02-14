defmodule Nous.Tools.SearchScrape do
  @moduledoc """
  Tool that fetches and summarizes content from multiple URLs in parallel.

  Combines WebFetch + Summarize into a single tool call, reducing
  round-trips in the agent loop. Uses Task.Supervisor for parallel fetching.

  ## Usage

      agent = Agent.new("openai:gpt-4",
        tools: [&SearchScrape.scrape_results/2],
        deps: %{summary_model: "openai:gpt-4o-mini"}
      )
  """

  alias Nous.Tools.{WebFetch, Summarize}

  require Logger

  @default_concurrency 5
  @default_timeout 10_000

  @doc """
  Fetch and summarize content from multiple URLs in parallel.

  ## Arguments

  - urls: List of URLs to fetch (required)
  - query: Research query to focus summaries on (required)
  - concurrency: Max parallel requests (default: 5)
  - timeout: Per-page timeout in ms (default: 10000)

  ## Returns

  A list of results with url, title, summary, key_facts, and relevance.
  """
  def scrape_results(ctx, args) do
    urls = Map.get(args, "urls", [])
    query = Map.get(args, "query", "")
    concurrency = Map.get(args, "concurrency", @default_concurrency)
    timeout = Map.get(args, "timeout", @default_timeout)

    if Enum.empty?(urls) do
      %{results: [], error: "No URLs provided"}
    else
      results =
        urls
        |> Enum.take(concurrency)
        |> Task.async_stream(
          fn url -> fetch_and_summarize(ctx, url, query) end,
          max_concurrency: concurrency,
          timeout: timeout,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, _reason} -> nil
        end)
        |> Enum.reject(&is_nil/1)

      %{
        results: results,
        total_fetched: length(results),
        total_requested: length(urls)
      }
    end
  end

  defp fetch_and_summarize(ctx, url, query) do
    case WebFetch.do_fetch(url) do
      {:ok, page} ->
        # Summarize the content focused on the research query
        summary_result =
          Summarize.summarize(ctx, %{
            "text" => page.content,
            "focus" => query,
            "max_points" => 5
          })

        %{
          url: url,
          title: page.title,
          summary: summary_result.summary,
          key_facts: summary_result.key_points,
          relevance: summary_result.relevance_score,
          word_count: page.word_count
        }

      {:error, reason} ->
        Logger.debug("Failed to fetch #{url}: #{inspect(reason)}")

        %{
          url: url,
          title: nil,
          summary: nil,
          key_facts: [],
          relevance: 0.0,
          error: inspect(reason)
        }
    end
  end
end
