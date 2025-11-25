# Yggdrasil AI - Simplified Design with OpenAI-Compatible Servers

## Overview

This document outlines a simplified architecture for Yggdrasil AI that focuses exclusively on OpenAI-compatible API servers. Instead of implementing multiple model providers from scratch, we'll use the `openai_ex` library and create an abstraction layer that works with any OpenAI-compatible endpoint.

## Why OpenAI-Compatible Only?

### Benefits

1. **Single API Standard**: OpenAI's API has become the de facto standard
2. **Wide Compatibility**: Most providers offer OpenAI-compatible endpoints:
   - OpenAI (GPT-4, GPT-3.5)
   - Anthropic (via compatibility layer)
   - Google (via compatibility layer)
   - Groq (native OpenAI compatibility)
   - Ollama (local models)
   - OpenRouter (unified gateway)
   - Together AI
   - Anyscale
   - And many more...
3. **Simplified Maintenance**: One implementation to maintain
4. **Leverage Existing Library**: Use battle-tested `openai_ex` library
5. **Future-Proof**: New providers increasingly offer OpenAI compatibility

### Trade-offs

- May not support provider-specific features (e.g., Anthropic's thinking mode)
- Relies on providers maintaining compatibility
- Some advanced features require provider-specific handling

## Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────┐
│                    Application Layer                     │
│  (User Code: Define Agents, Tools, Dependencies)        │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼─────────────────────────────┐
│                    Agent Layer                         │
│  • Agent Definition (Yggdrasil.Agent)                  │
│  • Tool Registration                                   │
│  • Output Validation                                   │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼─────────────────────────────┐
│                  Execution Layer                       │
│  • AgentRunner (GenServer)                             │
│  • Message Loop                                        │
│  • Tool Execution                                      │
│  • Streaming Coordination                              │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼─────────────────────────────┐
│              Model Abstraction Layer                   │
│  • Yggdrasil.Model (Behaviour)                         │
│  • OpenAICompatible (Implementation)                   │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼─────────────────────────────┐
│                   OpenAI.Ex Library                    │
│  • HTTP Client                                         │
│  • Chat Completions                                    │
│  • Streaming                                           │
│  • Error Handling                                      │
└─────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────▼─────────────────────────────┐
│              OpenAI-Compatible Servers                 │
│  • OpenAI                                              │
│  • Groq                                                │
│  • Ollama                                              │
│  • OpenRouter                                          │
│  • Together AI                                         │
│  • Local models                                        │
└─────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Model Configuration

```elixir
# Support various configuration formats
defmodule Yggdrasil.Model do
  @type t :: %__MODULE__{
    # Provider identifier
    provider: :openai | :groq | :ollama | :openrouter | :custom,
    # Model name
    model: String.t(),
    # API base URL (for custom/local endpoints)
    base_url: String.t() | nil,
    # API key
    api_key: String.t() | nil,
    # Default settings
    default_settings: map()
  }

  defstruct [
    :provider,
    :model,
    :base_url,
    :api_key,
    default_settings: %{}
  ]
end
```

### 2. Model Parser

```elixir
# Parse model strings into configurations
defmodule Yggdrasil.ModelParser do
  @doc """
  Parse model string into configuration.

  ## Examples

      # OpenAI
      parse("openai:gpt-4")
      # => %Model{provider: :openai, model: "gpt-4", base_url: nil}

      # Groq
      parse("groq:llama-3.1-70b-versatile")
      # => %Model{provider: :groq, model: "llama-3.1-70b-versatile",
      #           base_url: "https://api.groq.com/openai/v1"}

      # Ollama (local)
      parse("ollama:llama2")
      # => %Model{provider: :ollama, model: "llama2",
      #           base_url: "http://localhost:11434/v1"}

      # Custom endpoint
      parse("custom:my-model", base_url: "https://my-server.com/v1")
      # => %Model{provider: :custom, model: "my-model",
      #           base_url: "https://my-server.com/v1"}

  """
  def parse(model_string, opts \\ [])
end
```

### 3. OpenAI-Compatible Model Implementation

```elixir
defmodule Yggdrasil.Models.OpenAICompatible do
  @moduledoc """
  OpenAI-compatible model implementation using openai_ex library.

  This implementation works with any server that implements the OpenAI API:
  - OpenAI (https://api.openai.com/v1)
  - Groq (https://api.groq.com/openai/v1)
  - Ollama (http://localhost:11434/v1)
  - OpenRouter (https://openrouter.ai/api/v1)
  - Together AI (https://api.together.xyz/v1)
  - And more...
  """

  @behaviour Yggdrasil.Models.Behaviour

  alias Yggdrasil.{Model, Messages, Usage, Types}
  alias OpenAI.Client
  alias OpenAI.Chat

  @impl true
  def request(model, messages, settings) do
    # Configure client for this provider
    client = build_client(model)

    # Convert messages to OpenAI format
    openai_messages = convert_messages(messages)

    # Build request parameters
    params = build_params(model, openai_messages, settings)

    # Make request using openai_ex
    case Chat.Completions.create(client, params) do
      {:ok, response} ->
        {:ok, parse_response(response, model)}

      {:error, error} ->
        {:error, format_error(error)}
    end
  end

  @impl true
  def request_stream(model, messages, settings) do
    client = build_client(model)
    openai_messages = convert_messages(messages)
    params = build_params(model, openai_messages, Map.put(settings, :stream, true))

    case Chat.Completions.create(client, params) do
      {:ok, stream} ->
        {:ok, Stream.map(stream, &parse_stream_event/1)}

      {:error, error} ->
        {:error, format_error(error)}
    end
  end

  @impl true
  def count_tokens(messages) do
    # Rough estimation: ~4 chars per token
    messages
    |> Enum.map(&estimate_message_tokens/1)
    |> Enum.sum()
  end

  # Private functions

  defp build_client(%Model{} = model) do
    config = %{
      api_key: model.api_key || get_api_key(model.provider),
      base_url: model.base_url || get_base_url(model.provider),
      organization: nil
    }

    OpenAI.Client.new(config)
  end

  defp get_api_key(:openai), do: Application.get_env(:yggdrasil, :openai_api_key)
  defp get_api_key(:groq), do: Application.get_env(:yggdrasil, :groq_api_key)
  defp get_api_key(:openrouter), do: Application.get_env(:yggdrasil, :openrouter_api_key)
  defp get_api_key(:ollama), do: nil  # Ollama doesn't require API key
  defp get_api_key(_), do: nil

  defp get_base_url(:openai), do: "https://api.openai.com/v1"
  defp get_base_url(:groq), do: "https://api.groq.com/openai/v1"
  defp get_base_url(:ollama), do: "http://localhost:11434/v1"
  defp get_base_url(:openrouter), do: "https://openrouter.ai/api/v1"
  defp get_base_url(:together), do: "https://api.together.xyz/v1"
  defp get_base_url(_), do: nil

  defp build_params(model, messages, settings) do
    base_params = %{
      model: model.model,
      messages: messages
    }

    # Merge with settings
    settings = Map.merge(model.default_settings, settings)

    # Add optional parameters
    base_params
    |> maybe_add(:temperature, settings[:temperature])
    |> maybe_add(:max_tokens, settings[:max_tokens])
    |> maybe_add(:top_p, settings[:top_p])
    |> maybe_add(:frequency_penalty, settings[:frequency_penalty])
    |> maybe_add(:presence_penalty, settings[:presence_penalty])
    |> maybe_add(:stop, settings[:stop_sequences])
    |> maybe_add(:stream, settings[:stream])
    |> maybe_add(:tools, settings[:tools])
    |> maybe_add(:tool_choice, settings[:tool_choice])
  end

  defp maybe_add(params, _key, nil), do: params
  defp maybe_add(params, key, value), do: Map.put(params, key, value)

  defp convert_messages(messages) do
    Enum.map(messages, &convert_message/1)
  end

  defp convert_message({:system_prompt, text}) do
    %{role: "system", content: text}
  end

  defp convert_message({:user_prompt, text}) when is_binary(text) do
    %{role: "user", content: text}
  end

  defp convert_message({:user_prompt, content}) when is_list(content) do
    %{role: "user", content: convert_content(content)}
  end

  defp convert_message({:tool_return, %{call_id: id, result: result}}) do
    %{
      role: "tool",
      tool_call_id: id,
      content: Jason.encode!(result)
    }
  end

  defp convert_message(%{parts: parts}) do
    # This is a previous response, reconstruct it
    text = Messages.extract_text(parts)
    tool_calls = Messages.extract_tool_calls(parts)

    msg = %{role: "assistant", content: text || ""}

    if not Enum.empty?(tool_calls) do
      Map.put(msg, :tool_calls, Enum.map(tool_calls, &format_tool_call/1))
    else
      msg
    end
  end

  defp convert_content(content) do
    Enum.map(content, fn
      {:text, text} -> %{type: "text", text: text}
      {:image_url, url} -> %{type: "image_url", image_url: %{url: url}}
      text when is_binary(text) -> %{type: "text", text: text}
    end)
  end

  defp format_tool_call(%{id: id, name: name, arguments: args}) do
    %{
      id: id,
      type: "function",
      function: %{
        name: name,
        arguments: Jason.encode!(args)
      }
    }
  end

  defp parse_response(response, model) do
    choice = List.first(response.choices)
    message = choice.message

    parts = []

    # Add text content
    parts = if message.content && message.content != "" do
      [{:text, message.content} | parts]
    else
      parts
    end

    # Add tool calls
    parts = if message.tool_calls do
      tool_parts = Enum.map(message.tool_calls, &parse_tool_call/1)
      tool_parts ++ parts
    else
      parts
    end

    # Build usage
    usage = %Usage{
      requests: 1,
      input_tokens: response.usage.prompt_tokens,
      output_tokens: response.usage.completion_tokens,
      total_tokens: response.usage.total_tokens
    }

    %{
      parts: Enum.reverse(parts),
      usage: usage,
      model_name: response.model,
      timestamp: DateTime.utc_now()
    }
  end

  defp parse_tool_call(tool_call) do
    {:tool_call, %{
      id: tool_call.id,
      name: tool_call.function.name,
      arguments: Jason.decode!(tool_call.function.arguments)
    }}
  end

  defp parse_stream_event(chunk) do
    # Parse streaming chunk from openai_ex
    # Convert to our event format
    delta = List.first(chunk.choices).delta

    cond do
      delta.content ->
        {:text_delta, delta.content}

      delta.tool_calls ->
        # Handle tool call delta
        {:tool_call_delta, delta.tool_calls}

      true ->
        {:other, chunk}
    end
  end

  defp format_error(error) do
    # Convert openai_ex errors to our format
    error
  end

  defp estimate_message_tokens(message) do
    # Simple estimation
    message
    |> inspect()
    |> String.length()
    |> div(4)
  end
end
```

## Configuration Examples

### Config File

```elixir
# config/config.exs
import Config

config :yggdrasil,
  # API Keys for various providers
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  groq_api_key: System.get_env("GROQ_API_KEY"),
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),

  # Default model
  default_model: "openai:gpt-4",

  # Timeouts
  request_timeout: 60_000,

  # Telemetry
  enable_telemetry: true
```

### Runtime Configuration

```elixir
# Use OpenAI
agent = Agent.new("openai:gpt-4")

# Use Groq (fast inference)
agent = Agent.new("groq:llama-3.1-70b-versatile")

# Use Ollama (local)
agent = Agent.new("ollama:llama2")

# Use OpenRouter (access many models)
agent = Agent.new("openrouter:anthropic/claude-3.5-sonnet")

# Use custom endpoint
agent = Agent.new("custom:my-model",
  base_url: "https://my-server.com/v1",
  api_key: "my-key"
)

# Override base URL for specific provider
agent = Agent.new("ollama:llama2",
  base_url: "http://192.168.1.100:11434/v1"
)
```

## Provider Support Matrix

| Provider | Model String Format | Base URL | API Key Required |
|----------|-------------------|----------|------------------|
| OpenAI | `openai:gpt-4` | `https://api.openai.com/v1` | Yes |
| Groq | `groq:llama-3.1-70b-versatile` | `https://api.groq.com/openai/v1` | Yes |
| Ollama | `ollama:llama2` | `http://localhost:11434/v1` | No |
| LM Studio | `lmstudio:qwen/qwen3-30b-a3b-2507` | `http://localhost:1234/v1` | No |
| OpenRouter | `openrouter:anthropic/claude-3.5-sonnet` | `https://openrouter.ai/api/v1` | Yes |
| Together AI | `together:meta-llama/Llama-3-70b-chat-hf` | `https://api.together.xyz/v1` | Yes |
| Anyscale | `anyscale:meta-llama/Llama-2-70b-chat-hf` | `https://api.endpoints.anyscale.com/v1` | Yes |
| Custom | `custom:model-name` | User-provided | Optional |

## Usage Examples

### Basic Usage with Different Providers

```elixir
# OpenAI GPT-4
agent = Agent.new("openai:gpt-4",
  instructions: "Be helpful and concise"
)

{:ok, result} = Agent.run(agent, "What is 2+2?")

# Groq (fast inference)
fast_agent = Agent.new("groq:llama-3.1-8b-instant",
  instructions: "Be helpful and concise"
)

{:ok, result} = Agent.run(fast_agent, "Quick math: 2+2?")

# Ollama (local, free)
local_agent = Agent.new("ollama:llama2",
  instructions: "Be helpful and concise"
)

{:ok, result} = Agent.run(local_agent, "What is 2+2?")

# LM Studio (local, any model)
lm_agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "Always answer in rhymes",
  model_settings: %{temperature: 0.7, max_tokens: -1}
)

{:ok, result} = Agent.run(lm_agent, "What day is it today?")

# OpenRouter (access to many models)
router_agent = Agent.new("openrouter:anthropic/claude-3.5-sonnet",
  instructions: "Be helpful and concise"
)

{:ok, result} = Agent.run(router_agent, "What is 2+2?")
```

### Tools Work with Any Provider

```elixir
defmodule MyTools do
  def search_web(_ctx, query) do
    # Search implementation
    "Results for: #{query}"
  end
end

# Same agent definition works with any provider
agent = Agent.new("groq:llama-3.1-70b-versatile",
  instructions: "Help users find information",
  tools: [&MyTools.search_web/2]
)

{:ok, result} = Agent.run(agent, "Search for Elixir tutorials")
```

### Multi-Provider Architecture

```elixir
defmodule MyApp.Agents do
  @doc "Fast agent for simple queries"
  def fast do
    Agent.new("groq:llama-3.1-8b-instant",
      instructions: "Be quick and concise"
    )
  end

  @doc "Smart agent for complex reasoning"
  def smart do
    Agent.new("openai:gpt-4",
      instructions: "Think deeply and provide detailed answers"
    )
  end

  @doc "Local agent for privacy-sensitive tasks"
  def private do
    Agent.new("ollama:llama2",
      instructions: "Be helpful"
    )
  end

  @doc "Route query to appropriate agent"
  def route(query) do
    cond do
      simple_query?(query) -> fast()
      needs_reasoning?(query) -> smart()
      contains_pii?(query) -> private()
      true -> fast()
    end
  end
end
```

## Dependency Update

### mix.exs

```elixir
defp deps do
  [
    # OpenAI client library
    {:openai_ex, github: "cyberchitta/openai_ex"},

    # JSON
    {:jason, "~> 1.4"},

    # Validation
    {:ecto, "~> 3.11"},

    # Telemetry
    {:telemetry, "~> 1.2"},

    # Dev/Test
    {:ex_doc, "~> 0.31", only: :dev, runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:mox, "~> 1.1", only: :test}
  ]
end
```

## Testing with Mock Models

```elixir
defmodule Yggdrasil.Testing.MockModel do
  @moduledoc """
  Mock model for testing without API calls.
  """

  @behaviour Yggdrasil.Models.Behaviour

  def request(_model, _messages, settings) do
    # Return predefined response from settings
    response = %{
      parts: [{:text, settings[:mock_response] || "Mock response"}],
      usage: %Yggdrasil.Usage{
        requests: 1,
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 15
      },
      model_name: "mock-model",
      timestamp: DateTime.utc_now()
    }

    {:ok, response}
  end

  def request_stream(_model, _messages, settings) do
    text = settings[:mock_response] || "Mock response"
    chunks = String.split(text, " ")

    stream =
      Stream.concat(
        Stream.map(chunks, fn chunk -> {:text_delta, chunk <> " "} end),
        [{:complete, %{output: text}}]
      )

    {:ok, stream}
  end

  def count_tokens(_messages), do: 10
end

# Usage in tests
test "agent runs successfully" do
  agent = Agent.new("mock:test",
    model_implementation: Yggdrasil.Testing.MockModel,
    model_settings: %{mock_response: "Test response"}
  )

  {:ok, result} = Agent.run(agent, "Test prompt")
  assert result.output == "Test response"
end
```

## Advantages of This Approach

### 1. Simplicity
- Single implementation to maintain
- Leverage battle-tested `openai_ex` library
- No need to learn multiple provider APIs

### 2. Flexibility
- Easy to switch between providers
- Support for local models (Ollama)
- Custom endpoints for proprietary models

### 3. Cost Optimization
```elixir
# Use cheap/fast model for simple tasks
router = Agent.new("groq:llama-3.1-8b-instant")

# Use expensive/smart model for complex tasks
analyzer = Agent.new("openai:gpt-4")

# Use free local model for development
dev = Agent.new("ollama:llama2")
```

### 4. Privacy Options
```elixir
# Keep sensitive data on-premises
local_agent = Agent.new("ollama:llama2")
{:ok, result} = Agent.run(local_agent,
  "Analyze this confidential document: #{private_data}"
)
```

### 5. Vendor Independence
```elixir
# Easy to migrate between providers
# Just change the model string!

# Before: Using OpenAI
agent = Agent.new("openai:gpt-4")

# After: Using Groq (same code!)
agent = Agent.new("groq:llama-3.1-70b-versatile")
```

## Model Behaviour Definition

```elixir
defmodule Yggdrasil.Models.Behaviour do
  @moduledoc """
  Behaviour for model implementations.

  While we primarily support OpenAI-compatible APIs via openai_ex,
  this behaviour allows for custom implementations if needed.
  """

  alias Yggdrasil.{Model, Types}

  @doc """
  Make a request to the model.

  ## Parameters
  - model: Model configuration
  - messages: List of message tuples
  - settings: Request settings (temperature, max_tokens, etc.)

  ## Returns
  - `{:ok, response}` with parts, usage, model_name, timestamp
  - `{:error, reason}` on failure
  """
  @callback request(Model.t(), [Types.message()], map()) ::
              {:ok, Types.model_response()} | {:error, term()}

  @doc """
  Make a streaming request to the model.

  ## Returns
  - `{:ok, stream}` where stream yields events
  - `{:error, reason}` on failure
  """
  @callback request_stream(Model.t(), [Types.message()], map()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Count tokens in messages (can be an estimate).
  """
  @callback count_tokens([Types.message()]) :: integer()

  @optional_callbacks count_tokens: 1
end
```

## Updated Agent Module

```elixir
defmodule Yggdrasil.Agent do
  # ... (most code same as before)

  @doc """
  Create a new agent.

  ## Model Formats

  - `"openai:gpt-4"` - OpenAI GPT-4
  - `"openai:gpt-3.5-turbo"` - OpenAI GPT-3.5
  - `"groq:llama-3.1-70b-versatile"` - Groq with Llama
  - `"ollama:llama2"` - Local Ollama
  - `"openrouter:anthropic/claude-3.5-sonnet"` - OpenRouter
  - `"custom:my-model"` - Custom endpoint (requires base_url)

  ## Options

  - `:base_url` - Override base URL for custom endpoints
  - `:api_key` - Override API key
  - `:model_implementation` - Custom model implementation module
  - `:output_type` - Expected output type
  - `:instructions` - Agent instructions
  - `:tools` - Available tools
  - `:model_settings` - Default model settings

  ## Examples

      # OpenAI
      agent = Agent.new("openai:gpt-4")

      # Groq (fast)
      agent = Agent.new("groq:llama-3.1-8b-instant")

      # Local Ollama
      agent = Agent.new("ollama:llama2")

      # Custom endpoint
      agent = Agent.new("custom:my-model",
        base_url: "https://my-api.com/v1",
        api_key: "my-key"
      )
  """
  @spec new(String.t(), keyword()) :: t()
  def new(model_string, opts \\ []) do
    # Parse model string into Model struct
    model = Yggdrasil.ModelParser.parse(model_string, opts)

    # Get or default to OpenAI-compatible implementation
    implementation = Keyword.get(
      opts,
      :model_implementation,
      Yggdrasil.Models.OpenAICompatible
    )

    %__MODULE__{
      model: model,
      model_implementation: implementation,
      output_type: Keyword.get(opts, :output_type, :string),
      instructions: Keyword.get(opts, :instructions),
      system_prompt: Keyword.get(opts, :system_prompt),
      deps_type: Keyword.get(opts, :deps_type),
      name: Keyword.get(opts, :name, generate_name()),
      model_settings: Keyword.get(opts, :model_settings, %{}),
      retries: Keyword.get(opts, :retries, 1),
      tools: parse_tools(Keyword.get(opts, :tools, [])),
      end_strategy: Keyword.get(opts, :end_strategy, :early)
    }
  end
end
```

## Summary

This simplified design:

1. ✅ **Uses `openai_ex`** - Leverages existing, tested library
2. ✅ **Single implementation** - One model adapter for all providers
3. ✅ **OpenAI-compatible** - Works with any OpenAI API-compatible server
4. ✅ **Still extensible** - Behaviour allows custom implementations
5. ✅ **Provider flexibility** - Easy switching between OpenAI, Groq, Ollama, etc.
6. ✅ **Cost optimization** - Use cheaper models for simple tasks
7. ✅ **Privacy options** - Support for local models
8. ✅ **Simpler maintenance** - Less code to maintain
9. ✅ **Future-proof** - OpenAI API is becoming the standard

The abstraction layer remains, but we only implement it once using `openai_ex`, making the codebase simpler while maintaining flexibility.
