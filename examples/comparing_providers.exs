#!/usr/bin/env elixir

# Example: Comparing different providers with the same prompt
#
# This demonstrates how easy it is to switch between:
# - Cloud providers (OpenAI, Groq)
# - Local servers (LM Studio, Ollama)

Mix.install([
  {:yggdrasil, path: ".."}
])

alias Yggdrasil.Agent

defmodule ProviderComparison do
  def compare(prompt) do
    providers = [
      # Cloud providers
      {"OpenAI GPT-4", "openai:gpt-4"},
      {"Groq Llama 3.1", "groq:llama-3.1-70b-versatile"},

      # Local providers
      {"LM Studio (local)", "custom:qwen/qwen3-30b-a3b-2507",
       [base_url: "http://localhost:1234/v1", api_key: "not-needed"]},
      {"Ollama (local)", "ollama:llama2"}
    ]

    IO.puts("Comparing providers with prompt: #{prompt}\n")
    IO.puts(String.duplicate("=", 70))

    for provider <- providers do
      case provider do
        {name, model_string} ->
          run_comparison(name, model_string, [], prompt)

        {name, model_string, opts} ->
          run_comparison(name, model_string, opts, prompt)
      end
    end
  end

  defp run_comparison(name, model_string, opts, prompt) do
    IO.puts("\n#{name}")
    IO.puts(String.duplicate("-", 70))

    agent = Agent.new(model_string, opts)
    start_time = System.monotonic_time(:millisecond)

    case Agent.run(agent, prompt) do
      {:ok, result} ->
        duration = System.monotonic_time(:millisecond) - start_time

        IO.puts("Response: #{String.slice(result.output, 0..200)}...")
        IO.puts("\nStats:")
        IO.puts("  Tokens: #{result.usage.total_tokens}")
        IO.puts("  Duration: #{duration}ms")
        IO.puts("  Speed: #{Float.round(result.usage.total_tokens / (duration / 1000), 2)} tokens/sec")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
        IO.puts("(Provider may not be available)")
    end

    IO.puts("")
  end
end

# Run comparison
ProviderComparison.compare("Explain quantum computing in simple terms")
