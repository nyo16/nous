#!/usr/bin/env elixir

# Nous AI - Hello World (30 seconds)
# The absolute minimal example to get you started

# ============================================================================
# Step 1: Create an AI agent
# ============================================================================

agent = Nous.new("lmstudio:qwen/qwen3-30b",
  instructions: "You are a friendly assistant"
)

# ============================================================================
# Step 2: Ask it something
# ============================================================================

IO.puts("🤖 Creating AI agent...")
IO.puts("💬 Asking: 'Hello! What can you do?'")
IO.puts("⏳ Thinking...")

{:ok, result} = Nous.run(agent, "Hello! What can you do?")

# ============================================================================
# Step 3: See the response
# ============================================================================

IO.puts("✅ AI Response:")
IO.puts(result.output)

# ============================================================================
# That's it! You just ran your first AI agent!
# ============================================================================

IO.puts("")
IO.puts("🎉 Success! You just ran your first Nous AI agent!")
IO.puts("📊 Used #{result.usage.total_tokens} tokens in this conversation")

# ============================================================================
# What just happened?
# ============================================================================

# 1. Created an AI agent with basic instructions
# 2. Asked it a question
# 3. Got an intelligent response
#
# The agent automatically:
# - Connected to your AI provider (LM Studio/OpenAI/Claude)
# - Processed your question with its instructions
# - Generated a helpful response
# - Tracked token usage

# ============================================================================
# Next steps (choose one):
# ============================================================================

IO.puts("")
IO.puts("🚀 What's next?")
IO.puts("1. Try changing the question above")
IO.puts("2. Change the instructions to make it respond differently")
IO.puts("3. Try: mix run examples/tools_simple.exs (add function calling)")
IO.puts("4. Try: mix run examples/calculator_demo.exs (multi-tool chaining)")
IO.puts("5. See: examples/GETTING_STARTED.md (5-minute tutorial)")

# ============================================================================
# Troubleshooting
# ============================================================================

# If this didn't work:
#
# 🔧 For local AI (LM Studio):
# 1. Make sure LM Studio is running
# 2. Check a model is loaded
# 3. Server should be on http://localhost:1234
#
# 🔧 For cloud AI:
# 1. Set your API key: export ANTHROPIC_API_KEY="sk-ant-..."
# 2. Change model above to: "anthropic:claude-sonnet-4-5-20250929"
# 3. Or use: "openai:gpt-4" with OPENAI_API_KEY
#
# 🔧 Still stuck?
# - Check examples/GETTING_STARTED.md
# - See examples/guides/troubleshooting.md

# ============================================================================
# Experiment!
# ============================================================================

# Try changing these values and running again:
#
# Different models:
# agent = Nous.new("anthropic:claude-sonnet-4-5-20250929")
# agent = Nous.new("openai:gpt-4")
#
# Different instructions:
# instructions: "You are a pirate who speaks in pirate language"
# instructions: "You are a helpful teacher who explains things simply"
# instructions: "You are a poet who always responds in rhymes"
#
# Different questions:
# "Tell me a joke"
# "What's 2+2?"
# "Explain quantum physics in simple terms"