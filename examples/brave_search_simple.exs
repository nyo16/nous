#!/usr/bin/env elixir

# Simple Brave Search Test - Just one search

IO.puts("\n🔍 Brave Search - Simple Test")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

alias Yggdrasil.Tools.BraveSearch

# Check if API key is set
api_key = System.get_env("BRAVE_API_KEY")

if !api_key || api_key == "" do
  IO.puts("❌ Error: BRAVE_API_KEY not set")
  System.halt(1)
end

# Create agent with search
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: """
  You are a helpful assistant with web search.
  When searching, use the web_search tool and cite sources.
  """,
  tools: [&BraveSearch.web_search/2]
)

{:ok, result} = Yggdrasil.run(agent, "Search for 'Elixir 1.18 release date' and tell me when it was released")

IO.puts(result.output)
IO.puts("")
