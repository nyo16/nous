#!/usr/bin/env elixir

# Nous AI - Web & Search Tools
#
# Demonstrates the built-in web/search tools:
#
#   - Nous.Tools.WebFetch.fetch_page/2    -> fetch + extract readable page content
#   - Nous.Tools.SearchScrape.scrape_results/2 -> fetch + summarize many URLs in parallel
#   - Nous.Tools.TavilySearch.search/2    -> AI-optimized search (needs TAVILY_API_KEY)
#   - Nous.Tools.BraveSearch.web_search/2 -> web search (needs BRAVE_API_KEY)
#   - Nous.Tools.BraveSearch.news_search/2 -> news search (needs BRAVE_API_KEY)
#
# Run with:  mix run examples/advanced/web_tools.exs
#
# Notes:
#   * WebFetch/SearchScrape need NETWORK access but NO API key. WebFetch also
#     requires the optional Floki dependency ({:floki, "~> 0.36"} in mix.exs).
#   * Tavily/Brave need API keys. Keys are resolved (in order) from:
#       ctx.deps[:tavily_api_key] / [:brave_api_key]
#       Application config (:nous, :tavily_api_key / :brave_api_key)
#       env vars TAVILY_API_KEY / BRAVE_API_KEY
#     Below we pass them through an agent's `deps:`.

alias Nous.Tools.{WebFetch, SearchScrape, TavilySearch, BraveSearch}
alias Nous.RunContext

IO.puts("=== Nous AI - Web & Search Tools ===\n")

# ============================================================================
# Part 1: Call a tool function directly (no LLM, no API key)
# ============================================================================
#
# Tools are plain `fun(ctx, args)` functions. We can call them directly.
# `ctx` is a Nous.RunContext; `args` is a string-keyed map (as the LLM sends).

IO.puts("--- Part 1: WebFetch.fetch_page/2 (direct call, needs network) ---")

ctx = RunContext.new(%{})

case WebFetch.fetch_page(ctx, %{"url" => "https://example.com"}) do
  %{success: true} = page ->
    IO.puts("Title:      #{page.title}")
    IO.puts("Words:      #{page.word_count}")
    IO.puts("Fetched at: #{page.fetched_at}")
    IO.puts("Preview:    #{String.slice(page.content, 0, 120)}...")

  %{success: false, error: error} ->
    IO.puts("Fetch unavailable (network/Floki?): #{error}")
end

IO.puts("")

# ============================================================================
# Part 2: SearchScrape.scrape_results/2 (parallel fetch + summarize)
# ============================================================================
#
# SearchScrape fetches each URL then summarizes it. Summarization uses an LLM,
# so we supply a summary model via deps. It needs network + a reachable model.

IO.puts("--- Part 2: SearchScrape.scrape_results/2 (parallel, needs network + model) ---")

scrape_ctx = RunContext.new(%{summary_model: "lmstudio:qwen3"})

scrape_args = %{
  "urls" => ["https://example.com", "https://example.org"],
  "query" => "What are these pages about?",
  "concurrency" => 2
}

case SearchScrape.scrape_results(scrape_ctx, scrape_args) do
  %{results: results, total_fetched: fetched, total_requested: requested} ->
    IO.puts("Fetched #{fetched}/#{requested} pages")

    for r <- results do
      IO.puts("  - #{r.url} (relevance: #{r.relevance})")
    end

  other ->
    IO.inspect(other, label: "SearchScrape result")
end

IO.puts("")

# ============================================================================
# Part 3: Tavily search (key-gated) - direct call
# ============================================================================

IO.puts("--- Part 3: TavilySearch.search/2 (needs TAVILY_API_KEY) ---")

tavily_key = System.get_env("TAVILY_API_KEY")

if is_nil(tavily_key) or tavily_key == "" do
  IO.puts("Skipped. Set TAVILY_API_KEY to run this part (https://tavily.com).")
else
  # Key supplied via deps so the tool resolves it from ctx.deps[:tavily_api_key].
  tavily_ctx = RunContext.new(%{tavily_api_key: tavily_key})

  case TavilySearch.search(tavily_ctx, %{"query" => "latest Elixir release", "max_results" => 3}) do
    %{success: true} = res ->
      if res.answer, do: IO.puts("Answer: #{res.answer}")
      IO.puts("Got #{res.result_count} results:")
      for r <- res.results, do: IO.puts("  - #{r.title} (#{r.url})")

    %{success: false, error: error} ->
      IO.puts("Tavily error: #{error}")
  end
end

IO.puts("")

# ============================================================================
# Part 4: Brave search (key-gated) - direct call
# ============================================================================

IO.puts("--- Part 4: BraveSearch.web_search/2 (needs BRAVE_API_KEY) ---")

brave_key = System.get_env("BRAVE_API_KEY")

if is_nil(brave_key) or brave_key == "" do
  IO.puts("Skipped. Set BRAVE_API_KEY to run this part (https://brave.com/search/api/).")
else
  brave_ctx = RunContext.new(%{brave_api_key: brave_key})

  case BraveSearch.web_search(brave_ctx, %{"query" => "Elixir programming language", "count" => 3}) do
    %{success: true} = res ->
      IO.puts("Got #{res.result_count} web results:")
      for r <- res.results, do: IO.puts("  - #{r.title} (#{r.url})")

    %{success: false, error: error} ->
      IO.puts("Brave error: #{error}")
  end
end

IO.puts("")

# ============================================================================
# Part 5: Register the tools on an agent and let the LLM decide
# ============================================================================
#
# Pass tools as a list of captured functions; pass any API keys through `deps`
# so the tools can read them from ctx. The agent calls a tool only when needed.

IO.puts("--- Part 5: Agent with web tools (needs a reachable model) ---")

research_agent =
  Nous.new("lmstudio:qwen3",
    instructions: "You research topics using the web tools available to you.",
    tools: [
      &WebFetch.fetch_page/2,
      &SearchScrape.scrape_results/2,
      &TavilySearch.search/2,
      &BraveSearch.web_search/2,
      &BraveSearch.news_search/2
    ]
  )

# deps flow into ctx.deps for every tool call during the run.
deps = %{
  summary_model: "lmstudio:qwen3",
  tavily_api_key: tavily_key,
  brave_api_key: brave_key
}

case Nous.run(research_agent, "Fetch https://example.com and tell me what it's for.", deps: deps) do
  {:ok, result} ->
    IO.puts("Response: #{result.output}")
    IO.puts("Tool calls: #{result.usage.tool_calls}")

  {:error, reason} ->
    IO.puts("Agent run failed (model unreachable?): #{inspect(reason)}")
end

IO.puts("\nDone.")
