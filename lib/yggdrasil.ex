defmodule Yggdrasil do
  @moduledoc """
  Type-safe AI agent framework for Elixir with OpenAI-compatible models.

  Yggdrasil brings the power of AI agents to Elixir with:
  - Model-agnostic API (OpenAI, Groq, Ollama, LM Studio, etc.)
  - Type-safe tool definitions
  - Structured outputs with Ecto validation
  - Streaming support
  - Built-in observability

  ## Quick Start

      # Create an agent
      agent = Yggdrasil.new("openai:gpt-4",
        instructions: "Be helpful and concise"
      )

      # Run it
      {:ok, result} = Yggdrasil.run(agent, "What is 2+2?")
      IO.puts(result.output) # "4"

  ## With Tools

      defmodule MyTools do
        @doc "Calculate mathematical expressions"
        def calculate(_ctx, expression) do
          # Your calculation logic
          "Result: \#{expression}"
        end
      end

      agent = Yggdrasil.new("groq:llama-3.1-70b-versatile",
        instructions: "Help with calculations",
        tools: [&MyTools.calculate/2]
      )

      {:ok, result} = Yggdrasil.run(agent, "What is 25 * 4?")

  ## Local Models

      # Use LM Studio (free, local, private)
      agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b")
      {:ok, result} = Yggdrasil.run(agent, "Hello!")

      # Use Ollama
      agent = Yggdrasil.new("ollama:llama2")
      {:ok, result} = Yggdrasil.run(agent, "Hello!")

  """

  alias Yggdrasil.Agent

  @doc """
  Create a new agent (shorthand for Agent.new/2).

  ## Examples

      # OpenAI
      agent = Yggdrasil.new("openai:gpt-4")

      # Groq (fast inference)
      agent = Yggdrasil.new("groq:llama-3.1-8b-instant")

      # Local LM Studio
      agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b")

      # With options
      agent = Yggdrasil.new("openai:gpt-4",
        instructions: "Be helpful",
        tools: [&MyTools.search/2],
        model_settings: %{temperature: 0.7}
      )

  """
  @spec new(String.t(), keyword()) :: Agent.t()
  defdelegate new(model_string, opts \\ []), to: Agent

  @doc """
  Run an agent with a prompt (shorthand for Agent.run/3).

  ## Examples

      {:ok, result} = Yggdrasil.run(agent, "What is the capital of France?")
      IO.puts(result.output)

      # With dependencies
      {:ok, result} = Yggdrasil.run(agent, "Search for users",
        deps: %{database: MyApp.DB}
      )

  """
  @spec run(Agent.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run(agent, prompt, opts \\ []), to: Agent

  @doc """
  Run an agent with streaming (shorthand for Agent.run_stream/3).

  ## Example

      {:ok, stream} = Yggdrasil.run_stream(agent, "Tell me a story")

      stream
      |> Stream.each(fn
        {:text_delta, text} -> IO.write(text)
        {:complete, _} -> IO.puts("\\nDone!")
      end)
      |> Stream.run()

  """
  @spec run_stream(Agent.t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  defdelegate run_stream(agent, prompt, opts \\ []), to: Agent
end
