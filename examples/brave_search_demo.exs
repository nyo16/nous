#!/usr/bin/env elixir

# Brave Search Demo - Shows web search capabilities

IO.puts("\n🔍 Yggdrasil AI - Brave Search Demo")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

alias Yggdrasil.Tools.BraveSearch

# Check if API key is set
api_key = System.get_env("BRAVE_API_KEY")

if !api_key || api_key == "" do
  IO.puts("❌ Error: BRAVE_API_KEY environment variable not set")
  IO.puts("")
  IO.puts("Please set your Brave API key:")
  IO.puts("  export BRAVE_API_KEY=\"your-api-key-here\"")
  IO.puts("")
  IO.puts("Get your API key from: https://brave.com/search/api/")
  System.halt(1)
end

IO.puts("✓ Brave API key found")
IO.puts("")

# Create agent with search capabilities
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: """
  You are a helpful AI assistant with access to web search.
  When answering questions, use the search tool to find current information.
  Always cite the sources you use (URLs).
  Be concise and accurate.
  """,
  tools: [
    &BraveSearch.web_search/2,
    &BraveSearch.news_search/2
  ]
)

IO.puts("==" |> String.duplicate(70))
IO.puts("")

# Test 1: General web search
IO.puts("Test 1: General Web Search")
IO.puts("-" |> String.duplicate(70))

IO.puts("Searching for: 'Elixir programming language latest version'")
IO.puts("(Note: Only 1 search due to rate limit)")
IO.puts("")

{:ok, result1} = Yggdrasil.run(agent, "What is the latest version of Elixir programming language? Use web search to find current info.")

IO.puts(result1.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Wait to respect rate limit (1 req/s)
IO.puts("⏱️  Waiting 2 seconds to respect rate limit (1 req/s)...")
Process.sleep(2000)

# Test 2: News search
IO.puts("Test 2: News Search")
IO.puts("-" |> String.duplicate(70))

IO.puts("Searching for: 'AI developments'")
IO.puts("")

{:ok, result2} = Yggdrasil.run(agent, "What are the latest AI developments? Search the news.")

IO.puts(result2.output)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts("✅ Demo complete!")
IO.puts("")
IO.puts("Brave Search API Features:")
IO.puts("  • web_search - Search the web for current information")
IO.puts("  • news_search - Search for latest news")
IO.puts("")
IO.puts("Parameters:")
IO.puts("  • query - Search query (required)")
IO.puts("  • count - Number of results (default: 5, max: 20)")
IO.puts("  • country - Country code (e.g., 'US', 'GB')")
IO.puts("  • search_lang - Language (e.g., 'en', 'es')")
IO.puts("  • safesearch - 'off', 'moderate', or 'strict'")
IO.puts("")
IO.puts("Rate Limits:")
IO.puts("  • Free Plan: 1 query/second, 2,000 queries/month")
IO.puts("  • Base AI: 20 queries/second, 20M queries/month")
IO.puts("  • Pro AI: 50 queries/second, unlimited")
IO.puts("")
IO.puts("Get your API key: https://brave.com/search/api/")
IO.puts("")
