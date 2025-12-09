#!/usr/bin/env elixir

# Example: Smart routing between local and cloud models
#
# Strategy:
# - Use local LM Studio for development/testing (free, fast, private)
# - Use cloud providers for production (better quality, always available)

Mix.install([
  {:nous, path: ".."}
])

alias Nous.Agent

defmodule SmartRouter do
  @doc """
  Route to appropriate provider based on environment and requirements.
  """
  def create_agent(env \\ Mix.env()) do
    case env do
      :dev ->
        # Use local LM Studio in development
        IO.puts("📍 Using local LM Studio (free, private)")

        Agent.new("custom:qwen/qwen3-30b-a3b-2507",
          base_url: "http://localhost:1234/v1",
          api_key: "not-needed",
          model_settings: %{temperature: 0.7}
        )

      :test ->
        # Use fast Groq for tests
        IO.puts("📍 Using Groq (fast, cheap)")

        Agent.new("groq:llama-3.1-8b-instant",
          model_settings: %{temperature: 0.5}
        )

      :prod ->
        # Use OpenAI for production
        IO.puts("📍 Using OpenAI GPT-4 (best quality)")

        Agent.new("openai:gpt-4",
          model_settings: %{temperature: 0.7}
        )
    end
  end

  @doc """
  Route based on data sensitivity.
  """
  def create_agent_for_data(sensitive: true) do
    IO.puts("🔒 Using local model for sensitive data")

    Agent.new("custom:qwen/qwen3-30b-a3b-2507",
      base_url: "http://localhost:1234/v1",
      api_key: "not-needed",
      instructions: "Handle data confidentially"
    )
  end

  def create_agent_for_data(sensitive: false) do
    IO.puts("☁️  Using cloud model for non-sensitive data")

    Agent.new("groq:llama-3.1-70b-versatile",
      model_settings: %{temperature: 0.7}
    )
  end
end

# Example 1: Environment-based routing
IO.puts("=== Environment-based Routing ===\n")

agent = SmartRouter.create_agent(:dev)
{:ok, result} = Agent.run(agent, "What is 2+2?")
IO.puts("Response: #{result.output}\n")

# Example 2: Sensitivity-based routing
IO.puts("\n=== Sensitivity-based Routing ===\n")

# Public data - use cloud
public_agent = SmartRouter.create_agent_for_data(sensitive: false)
{:ok, result} = Agent.run(public_agent, "What's the weather like?")
IO.puts("Response: #{result.output}\n")

# Sensitive data - use local
sensitive_agent = SmartRouter.create_agent_for_data(sensitive: true)
{:ok, result} = Agent.run(sensitive_agent, "Analyze this confidential report")
IO.puts("Response: #{result.output}\n")

IO.puts("\n💡 Tip: Local models keep your data private and cost $0!")
