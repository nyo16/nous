# Custom Providers Guide

This guide covers using the `custom:` provider prefix to connect to any OpenAI-compatible API endpoint.

## Overview

The `custom:` provider is the recommended way to connect to LLM services that implement the OpenAI Chat Completions API. It works with:

- Cloud providers: Groq, Together AI, OpenRouter, Anyscale, Fireworks, etc.
- Local servers: LM Studio, Ollama, vLLM, SGLang, TGI, etc.
- Self-hosted endpoints: Your own OpenAI-compatible API

> **Note**: The legacy `openai_compatible:` prefix still works for backward compatibility, but `custom:` is the recommended approach.

## Quick Start

```elixir
# Basic usage with explicit options
agent = Nous.new("custom:llama-3.1-70b",
  base_url: "https://api.groq.com/openai/v1",
  api_key: System.get_env("GROQ_API_KEY")
)

{:ok, result} = Nous.run(agent, "What is Elixir?")
```

## Configuration Methods

Configuration is loaded in precedence order (higher overrides lower):

### 1. Direct Options (Per-Request)

Pass options directly to `Nous.new/2`:

```elixir
agent = Nous.new("custom:my-model",
  base_url: "https://api.example.com/v1",
  api_key: "sk-...",
  receive_timeout: 120_000
)
```

### 2. Environment Variables

Set environment variables for global defaults:

```bash
export CUSTOM_BASE_URL="https://api.example.com/v1"
export CUSTOM_API_KEY="sk-..."
```

Then use without options:

```elixir
agent = Nous.new("custom:my-model")
```

### 3. Application Config

Configure in `config/config.exs` or environment-specific config:

```elixir
config :nous, :custom,
  base_url: "https://api.example.com/v1",
  api_key: "sk-..."
```

## Examples by Service

### Groq

Fast inference with various open models:

```elixir
# Via explicit options
agent = Nous.new("custom:llama-3.1-70b-versatile",
  base_url: "https://api.groq.com/openai/v1",
  api_key: System.get_env("GROQ_API_KEY")
)

# Or if using the built-in groq provider
agent = Nous.new("groq:llama-3.1-70b-versatile")
```

### Together AI

Wide model selection including Qwen, Llama, and more:

```elixir
agent = Nous.new("custom:meta-llama/Llama-3-70b-chat-hf",
  base_url: "https://api.together.xyz/v1",
  api_key: System.get_env("TOGETHER_API_KEY")
)

# Or use the built-in together provider
agent = Nous.new("together:meta-llama/Llama-3-70b-chat-hf")
```

### OpenRouter

Unified API for many providers:

```elixir
agent = Nous.new("custom:anthropic/claude-3.5-sonnet",
  base_url: "https://openrouter.ai/api/v1",
  api_key: System.get_env("OPENROUTER_API_KEY")
)

# Or use the built-in openrouter provider
agent = Nous.new("openrouter:anthropic/claude-3.5-sonnet")
```

### LM Studio

Local models with GUI (no API key needed):

```elixir
agent = Nous.new("custom:qwen3",
  base_url: "http://localhost:1234/v1"
)

# Or use the built-in lmstudio provider (same default URL)
agent = Nous.new("lmstudio:qwen3")
```

### Ollama

Local CLI-based models (no API key needed):

```elixir
# Using custom with explicit base_url
agent = Nous.new("custom:llama2",
  base_url: "http://localhost:11434/v1"
)

# Or use the built-in ollama provider
agent = Nous.new("ollama:llama2")
```

### vLLM

High-performance local inference:

```elixir
# Using custom with explicit base_url
agent = Nous.new("custom:meta-llama/Llama-3-8B-Instruct",
  base_url: "http://localhost:8000/v1"
)

# Or use the built-in vllm provider
agent = Nous.new("vllm:meta-llama/Llama-3-8B-Instruct",
  base_url: "http://localhost:8000/v1"
)
```

### SGLang

Structured generation with RadixAttention:

```elixir
# Using custom with explicit base_url
agent = Nous.new("custom:meta-llama/Llama-3-8B-Instruct",
  base_url: "http://localhost:30000/v1"
)

# Or use the built-in sglang provider
agent = Nous.new("sglang:meta-llama/Llama-3-8B-Instruct")
```

### Custom Self-Hosted Endpoints

Point to your own OpenAI-compatible server:

```elixir
agent = Nous.new("custom:my-custom-model",
  base_url: "https://llm.internal.company.com/v1",
  api_key: System.get_env("INTERNAL_API_KEY")
)
```

## Advanced Options

### Custom Timeouts

Slow local models may need longer timeouts:

```elixir
agent = Nous.new("custom:large-model",
  base_url: "http://localhost:8000/v1",
  receive_timeout: 300_000  # 5 minutes
)
```

### Organization Headers

Some providers support organization IDs:

```elixir
agent = Nous.new("custom:model",
  base_url: "https://api.openai.com/v1",
  api_key: System.get_env("OPENAI_API_KEY"),
  organization: "org-..."
)
```

### Using with Tools

The custom provider supports function calling if the underlying model supports it:

```elixir
get_weather = fn _ctx, %{"city" => city} ->
  %{temperature: 72, condition: "sunny"}
end

agent = Nous.new("custom:meta-llama/Llama-3-70b",
  base_url: "https://api.together.xyz/v1",
  api_key: System.get_env("TOGETHER_API_KEY"),
  instructions: "You can check the weather.",
  tools: [get_weather]
)

{:ok, result} = Nous.run(agent, "What's the weather in San Francisco?")
```

### Streaming

Streaming works the same as any other provider:

```elixir
{:ok, stream} = Nous.run_stream(agent, "Write a haiku about Elixir")

stream
|> Enum.each(fn
  {:text_delta, text} -> IO.write(text)
  {:finish, _} -> IO.puts("")
  _ -> :ok
end)
```

## Troubleshooting

### Connection Refused

Ensure the server is running and accessible:

```bash
# LM Studio - check server is enabled in settings
# vLLM
vllm serve meta-llama/Llama-3.1-8B-Instruct

# SGLang
python -m sglang.launch_server --model meta-llama/Llama-3.1-8B-Instruct

# Ollama
ollama run llama2
ollama serve
```

### Authentication Errors

Check your API key:

```elixir
# With explicit key
agent = Nous.new("custom:model",
  base_url: "...",
  api_key: System.get_env("CORRECT_API_KEY")
)

# Or set env var
System.put_env("CUSTOM_API_KEY", "your-key")
```

### Base URL Format

Most servers expect the base URL to include `/v1`:

```elixir
# Correct
base_url: "http://localhost:1234/v1"
base_url: "https://api.groq.com/openai/v1"

# Might not work
base_url: "http://localhost:1234"           # missing /v1
base_url: "http://localhost:1234/v1/chat"   # too specific
```

## Backward Compatibility

The `openai_compatible:` prefix still works and is equivalent to `custom:`:

```elixir
# Legacy (still works)
agent = Nous.new("openai_compatible:my-model", base_url: "...")

# Recommended
agent = Nous.new("custom:my-model", base_url: "...")
```

## See Also

- `Nous.Providers.Custom` - The custom provider module
- `Nous.Providers.OpenAICompatible` - Underlying implementation
- [vLLM & SGLang examples](../../examples/providers/vllm_sglang.exs) - High-performance local inference
