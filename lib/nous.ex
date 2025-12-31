defmodule Nous do
  @moduledoc """
  AI agent framework for Elixir with multi-provider LLM support.

  Nous brings the power of AI agents to Elixir with:
  - Model-agnostic API (OpenAI, Groq, Ollama, LM Studio, etc.)
  - Simple tool definitions
  - Structured outputs with Ecto validation
  - Streaming support
  - Built-in observability

  ## Quick Start

      # Create an agent
      agent = Nous.new("openai:gpt-4",
        instructions: "Be helpful and concise"
      )

      # Run it
      {:ok, result} = Nous.run(agent, "What is 2+2?")
      IO.puts(result.output) # "4"

  ## With Tools

      defmodule MyTools do
        @doc "Calculate mathematical expressions"
        def calculate(_ctx, expression) do
          # Your calculation logic
          "Result: \#{expression}"
        end
      end

      agent = Nous.new("groq:llama-3.1-70b-versatile",
        instructions: "Help with calculations",
        tools: [&MyTools.calculate/2]
      )

      {:ok, result} = Nous.run(agent, "What is 25 * 4?")

  ## Local Models

      # Use LM Studio (free, local, private)
      agent = Nous.new("lmstudio:qwen/qwen3-30b")
      {:ok, result} = Nous.run(agent, "Hello!")

      # Use Ollama
      agent = Nous.new("ollama:llama2")
      {:ok, result} = Nous.run(agent, "Hello!")

  """

  alias Nous.Agent

  @doc """
  Create a new agent (shorthand for Agent.new/2).

  ## Examples

      # OpenAI
      agent = Nous.new("openai:gpt-4")

      # Groq (fast inference)
      agent = Nous.new("groq:llama-3.1-8b-instant")

      # Local LM Studio
      agent = Nous.new("lmstudio:qwen/qwen3-30b")

      # With options
      agent = Nous.new("openai:gpt-4",
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

      {:ok, result} = Nous.run(agent, "What is the capital of France?")
      IO.puts(result.output)

      # With dependencies
      {:ok, result} = Nous.run(agent, "Search for users",
        deps: %{database: MyApp.DB}
      )

  """
  @spec run(Agent.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run(agent, prompt, opts \\ []), to: Agent

  @doc """
  Run an agent with streaming (shorthand for Agent.run_stream/3).

  ## Example

      {:ok, stream} = Nous.run_stream(agent, "Tell me a story")

      stream
      |> Stream.each(fn
        {:text_delta, text} -> IO.write(text)
        {:complete, _} -> IO.puts("\\nDone!")
      end)
      |> Stream.run()

  """
  @spec run_stream(Agent.t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  defdelegate run_stream(agent, prompt, opts \\ []), to: Agent

  # Simple LLM API (without agents)

  @doc """
  Generate text from a model without creating an agent.

  This is a simpler API for text generation. Supports tools - if the model
  calls a tool, it will be executed and the conversation continues until
  the model returns a text response.

  ## Examples

      {:ok, text} = Nous.generate_text("openai:gpt-4", "What is 2+2?")

      {:ok, text} = Nous.generate_text("anthropic:claude-haiku-4-5", "Hello",
        system: "You are a pirate",
        temperature: 0.7,
        max_tokens: 500
      )

      # With tools
      weather_tool = Nous.Tool.from_function(&MyTools.get_weather/2,
        name: "get_weather",
        description: "Get weather for a city",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["location"]
        }
      )

      {:ok, text} = Nous.generate_text("openai:gpt-4", "What's the weather in Paris?",
        tools: [weather_tool]
      )

  ## Options

    * `:system` - System prompt
    * `:temperature` - Sampling temperature (0.0 to 2.0)
    * `:max_tokens` - Maximum tokens to generate
    * `:top_p` - Nucleus sampling parameter
    * `:base_url` - Override API base URL
    * `:api_key` - Override API key
    * `:tools` - List of tool functions or `Nous.Tool` structs
    * `:deps` - Dependencies to pass to tool functions

  """
  @spec generate_text(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate generate_text(model, prompt, opts \\ []), to: Nous.LLM

  @doc """
  Generate text from a model, raising on error.

  ## Example

      text = Nous.generate_text!("openai:gpt-4", "What is 2+2?")
      IO.puts(text) # "4"

  """
  @spec generate_text!(String.t(), String.t(), keyword()) :: String.t()
  defdelegate generate_text!(model, prompt, opts \\ []), to: Nous.LLM

  @doc """
  Stream text from a model.

  Returns a stream that yields text chunks as strings.

  ## Example

      {:ok, stream} = Nous.stream_text("openai:gpt-4", "Write a haiku")
      stream |> Stream.each(&IO.write/1) |> Stream.run()

  ## Options

    Same as `generate_text/3`.

  """
  @spec stream_text(String.t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  defdelegate stream_text(model, prompt, opts \\ []), to: Nous.LLM
end
