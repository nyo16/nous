#!/usr/bin/env elixir

# Simple working example of Nous AI
#
# This demonstrates the basic functionality without needing Mix.install
# Run from project root: elixir -S mix run examples/simple_working.exs

# Note: This requires OPENAI_API_KEY or another provider key to be set

IO.puts("=" |> String.duplicate(70))
IO.puts("Nous AI - Simple Example")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Check if we have API keys
has_openai = System.get_env("OPENAI_API_KEY") != nil
has_groq = System.get_env("GROQ_API_KEY") != nil

if not has_openai and not has_groq do
  IO.puts("⚠️  No API keys found!")
  IO.puts("")
  IO.puts("Please set one of:")
  IO.puts("  export OPENAI_API_KEY='sk-...'")
  IO.puts("  export GROQ_API_KEY='gsk-...'")
  IO.puts("")
  IO.puts("Or use local models:")
  IO.puts("  - LM Studio: http://lmstudio.ai")
  IO.puts("  - Ollama: http://ollama.ai")
  System.halt(1)
end

# Choose provider based on available keys
{provider, model} =
  cond do
    has_groq -> {"groq", "llama-3.1-8b-instant"}
    has_openai -> {"openai", "gpt-4"}
    true -> {"ollama", "llama2"}
  end

model_string = "#{provider}:#{model}"

IO.puts("Using: #{model_string}")
IO.puts("")

# Create agent
IO.puts("Creating agent...")

agent =
  Nous.new(model_string,
    instructions: "Be helpful and concise. Answer in one short sentence."
  )

IO.puts("Agent created: #{agent.name}")
IO.puts("")

# Example 1: Simple question
IO.puts("Example 1: Simple Question")
IO.puts("-" |> String.duplicate(40))
IO.puts("Q: What is 2+2?")

case Nous.run(agent, "What is 2+2?") do
  {:ok, result} ->
    IO.puts("A: #{result.output}")
    IO.puts("Tokens used: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")

# Example 2: Another question
IO.puts("Example 2: General Knowledge")
IO.puts("-" |> String.duplicate(40))
IO.puts("Q: What is the capital of France?")

case Nous.run(agent, "What is the capital of France?") do
  {:ok, result} ->
    IO.puts("A: #{result.output}")
    IO.puts("Tokens used: #{result.usage.total_tokens}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("✅ Example complete!")
IO.puts("")
IO.puts("Next steps:")
IO.puts("  - See examples/with_tools.exs for tool usage")
IO.puts("  - See examples/local_lm_studio.exs for local models")
IO.puts("  - Check IMPLEMENTATION_GUIDE.md for more examples")
IO.puts("=" |> String.duplicate(70))
