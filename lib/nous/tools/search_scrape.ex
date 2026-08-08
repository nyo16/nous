# Gated on Floki like WebFetch: without it, WebFetch.do_fetch/1 is a stub
# that only returns {:error, _}, and compiling this module against that stub
# emits a "the {:ok, page} clause can never match" warning in every app that
# depends on nous without floki.
if Code.ensure_loaded?(Floki) do
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

    ## Limits

    At most 50 URLs per call, and each page is subject to the same response
    ceiling as `Nous.Tools.WebFetch` — `ctx.deps[:web_fetch_max_bytes]` or
    `config :nous, web_fetch_max_bytes: bytes`, defaulting to WebFetch's own
    5_000_000.
    """

    alias Nous.Tools.{WebFetch, Summarize}

    require Logger

    @default_concurrency 5
    @default_timeout 10_000
    # Upper bound on URLs fetched per call so a model can't request unbounded work.
    @max_urls 50

    @typedoc """
    One scraped page. The second variant is what a failed fetch contributes —
    the URL still appears in the results so the model can see what was tried.
    `:url` is echoed from the model-supplied list without validation.
    """
    @type page_result ::
            %{
              url: term(),
              title: String.t() | nil,
              summary: String.t(),
              key_facts: [String.t()],
              relevance: float(),
              word_count: non_neg_integer()
            }
            | %{
                url: term(),
                title: nil,
                summary: nil,
                key_facts: [],
                relevance: float(),
                error: String.t()
              }

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
    @spec scrape_results(Nous.RunContext.t(), map()) ::
            %{results: [], error: String.t()}
            | %{
                required(:results) => [page_result()],
                required(:total_fetched) => non_neg_integer(),
                required(:total_requested) => non_neg_integer(),
                optional(:note) => String.t()
              }
    def scrape_results(ctx, args) do
      all_urls = Map.get(args, "urls", [])
      query = Map.get(args, "query", "")
      # concurrency/timeout are LLM-supplied; clamp to sane integers (a non-integer
      # would otherwise crash async_stream).
      concurrency = clamp_int(Map.get(args, "concurrency", @default_concurrency), 1, 20)
      timeout = clamp_int(Map.get(args, "timeout", @default_timeout), 1_000, 120_000)
      # Process ALL urls (capped), throttling parallelism via max_concurrency.
      # Previously Enum.take(urls, concurrency) silently fetched only the first few.
      urls = Enum.take(all_urls, @max_urls)

      if Enum.empty?(urls) do
        %{results: [], error: "No URLs provided"}
      else
        # Fan out, or fetch sequentially when the node is at its task ceiling:
        # a slower scrape beats no scrape, and refusing the batch would cost the
        # model every page. Each page stays bounded by WebFetch's own connect and
        # receive timeouts, and the whole call by ToolExecutor's per-tool budget,
        # so the dropped per-item `:timeout` is not the only thing holding this.
        results =
          Nous.Tasks.stream(
            urls,
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

        base = %{
          results: results,
          total_fetched: length(results),
          total_requested: length(urls)
        }

        if length(all_urls) > @max_urls do
          Map.put(base, :note, "Only the first #{@max_urls} URLs were fetched")
        else
          base
        end
      end
    end

    defp clamp_int(value, lo, hi) when is_integer(value), do: value |> max(lo) |> min(hi)
    defp clamp_int(_value, lo, _hi), do: lo

    defp fetch_and_summarize(ctx, url, query) do
      case WebFetch.do_fetch(url, nil, fetch_opts(ctx)) do
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

    # `WebFetch.do_fetch/3` falls back to WebFetch's own compiled-in default
    # when no `:max_bytes` is given, so calling it bare made every scrape
    # ignore the ceiling the host declared for exactly this traffic — and this
    # tool fetches up to @max_urls pages per call, so it is the larger
    # exposure of the two. Resolve the identical keys `fetch_page/2` resolves
    # (deps first, then application config) and pass the result through.
    # Nothing is forwarded when neither is set, which keeps WebFetch the one
    # place the default lives.
    defp fetch_opts(ctx) do
      ceiling =
        positive_int(ctx_deps(ctx)[:web_fetch_max_bytes]) ||
          positive_int(Application.get_env(:nous, :web_fetch_max_bytes))

      if ceiling, do: [max_bytes: ceiling], else: []
    end

    defp ctx_deps(%{deps: deps}) when is_map(deps), do: deps
    defp ctx_deps(_ctx), do: %{}

    defp positive_int(n) when is_integer(n) and n > 0, do: n

    defp positive_int(s) when is_binary(s) do
      case Integer.parse(s) do
        {n, ""} when n > 0 -> n
        _ -> nil
      end
    end

    defp positive_int(_other), do: nil
  end
else
  defmodule Nous.Tools.SearchScrape do
    @moduledoc """
    Tool that fetches and summarizes content from multiple URLs in parallel.

    Requires the `floki` package (used by `Nous.Tools.WebFetch`).
    Add `{:floki, "~> 0.36"}` to your deps.
    """

    @spec scrape_results(Nous.RunContext.t(), map()) :: %{success: false, error: String.t()}
    def scrape_results(_ctx, _args) do
      %{success: false, error: "Floki is required. Add {:floki, \"~> 0.36\"} to your deps."}
    end
  end
end
