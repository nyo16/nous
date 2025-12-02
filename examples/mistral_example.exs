#!/usr/bin/env elixir

# Yggdrasil AI - Mistral Example
# Test the new Mistral API provider implementation

# ============================================================================
# Step 1: Create a Mistral AI agent
# ============================================================================

IO.puts("🤖 Creating Mistral AI agent...")

agent = Yggdrasil.new("mistral:ministral-3-14b-instruct-2512",
  instructions: "You are a helpful assistant powered by Mistral AI"
)

# ============================================================================
# Step 2: Test basic request
# ============================================================================

IO.puts("💬 Testing basic request: 'Hello! Tell me about Mistral AI.'")
IO.puts("⏳ Thinking...")

{:ok, result} = Yggdrasil.run(agent, "Hello! Tell me about Mistral AI in 2-3 sentences.")

IO.puts("✅ AI Response:")
IO.puts(result.output)
IO.puts("📊 Used #{result.usage.total_tokens} tokens (#{result.usage.input_tokens} in, #{result.usage.output_tokens} out)")

# ============================================================================
# Step 3: Test streaming
# ============================================================================

IO.puts("")
IO.puts("🌊 Testing streaming response...")
IO.puts("💬 Asking: 'Count from 1 to 10 with explanations'")
IO.write("🤖 Response: ")

{:ok, stream} = Yggdrasil.run_stream(agent, "Count from 1 to 5, explaining why each number is interesting.")

stream
|> Stream.each(fn
  {:text_delta, text} -> IO.write(text)
  {:finish, reason} -> IO.puts("\n✅ Finished: #{reason}")
  {:tool_call_delta, _} -> IO.write("[tool call]")
  {:unknown, _} -> IO.write(".")
end)
|> Stream.run()

# ============================================================================
# Step 4: Test with custom settings
# ============================================================================

IO.puts("")
IO.puts("⚙️  Testing with custom settings (temperature: 0.1 for more focused responses)...")

focused_agent = Yggdrasil.new("mistral:ministral-3-14b-instruct-2512",
  instructions: "You are a precise, factual assistant",
  default_settings: %{
    temperature: 0.1,
    max_tokens: 100
  }
)

{:ok, result2} = Yggdrasil.run(focused_agent, "What is 2+2? Be precise.")

IO.puts("💬 Question: 'What is 2+2? Be precise.'")
IO.puts("✅ Response: #{result2.output}")
IO.puts("📊 Used #{result2.usage.total_tokens} tokens")

# ============================================================================
# Success!
# ============================================================================

IO.puts("")
IO.puts("🎉 Success! Mistral API provider is working correctly!")
IO.puts("")
IO.puts("✨ Features tested:")
IO.puts("  ✓ Basic requests")
IO.puts("  ✓ Streaming responses")
IO.puts("  ✓ Custom model settings")
IO.puts("  ✓ Token counting")
IO.puts("  ✓ Usage tracking")

# ============================================================================
# Notes about Mistral
# ============================================================================

IO.puts("")
IO.puts("🧠 About Mistral AI:")
IO.puts("  • Mistral models are known for their efficiency and multilingual capabilities")
IO.puts("  • This implementation uses the native Mistral API with Req HTTP client")
IO.puts("  • Supports all standard OpenAI-compatible features plus Mistral-specific ones")
IO.puts("")
IO.puts("🔧 Configuration:")
IO.puts("  • Set API key: export MISTRAL_API_KEY=\"your-key-here\"")
IO.puts("  • Available models: ministral-3-14b-instruct-2512, mistral-large-latest, mistral-small-latest, etc.")
IO.puts("  • Supports reasoning_mode, prediction_mode settings")

IO.puts("")
IO.puts("🚀 Next steps:")
IO.puts("  • Try different Mistral models")
IO.puts("  • Experiment with reasoning_mode: true for complex tasks")
IO.puts("  • Use with tools: mix run examples/tools_simple.exs")