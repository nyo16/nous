# Running Yggdrasil AI with Local LLMs

## Overview

Yggdrasil AI can run completely locally using OpenAI-compatible local servers. This means:
- 🆓 **Zero API costs** - No per-token charges
- 🔒 **Complete privacy** - Your data never leaves your machine
- ⚡ **Low latency** - No network round trips
- 🌐 **Work offline** - No internet required
- 🎛️ **Full control** - Choose any model, any settings

## Supported Local Servers

### 1. LM Studio (Recommended for Beginners)

**What is it?** Desktop app with a beautiful UI for running local LLMs.

**Installation:**
1. Download from https://lmstudio.ai/
2. Install the app
3. Browse and download models (e.g., Qwen 3 30B, Llama 3.1, Mistral)
4. Click "Start Server" - runs on `http://localhost:1234`

**Yggdrasil Usage:**
```elixir
# Using the shorthand
agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "Be helpful and concise"
)

# Or using custom endpoint
agent = Agent.new("custom:qwen/qwen3-30b-a3b-2507",
  base_url: "http://localhost:1234/v1",
  api_key: "not-needed"
)

{:ok, result} = Agent.run(agent, "What is the meaning of life?")
```

**Real cURL Example (from LM Studio):**
```bash
curl http://localhost:1234/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen/qwen3-30b-a3b-2507",
    "messages": [
      { "role": "system", "content": "Always answer in rhymes. Today is Thursday" },
      { "role": "user", "content": "What day is it today?" }
    ],
    "temperature": 0.7,
    "max_tokens": -1,
    "stream": false
  }'
```

**Yggdrasil Equivalent:**
```elixir
agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "Always answer in rhymes. Today is Thursday",
  model_settings: %{
    temperature: 0.7,
    max_tokens: -1  # -1 means unlimited
  }
)

{:ok, result} = Agent.run(agent, "What day is it today?")
IO.puts(result.output)
```

### 2. Ollama (CLI-Focused)

**What is it?** Command-line tool for running LLMs locally.

**Installation:**
```bash
# macOS/Linux
curl -fsSL https://ollama.ai/install.sh | sh

# Or download from https://ollama.ai/download
```

**Setup:**
```bash
# Pull a model
ollama pull llama2

# Start server (runs on http://localhost:11434)
ollama serve
```

**Yggdrasil Usage:**
```elixir
agent = Agent.new("ollama:llama2",
  instructions: "Be helpful and concise"
)

{:ok, result} = Agent.run(agent, "Explain quantum computing")
```

### 3. Text Generation Web UI (Advanced)

**What is it?** Web interface for running various LLM models with OpenAI-compatible API.

**Installation:**
```bash
git clone https://github.com/oobabooga/text-generation-webui
cd text-generation-webui
./start_linux.sh  # or start_macos.sh, start_windows.bat
```

**Enable OpenAI API:**
- In the web UI, go to "Session" tab
- Enable "openai" extension
- Server runs on `http://localhost:5000`

**Yggdrasil Usage:**
```elixir
agent = Agent.new("custom:your-model-name",
  base_url: "http://localhost:5000/v1",
  api_key: "not-needed"
)
```

### 4. llama.cpp Server

**What is it?** High-performance C++ implementation of LLama models.

**Installation:**
```bash
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp
make

# Download a model (GGUF format)
# Then run server
./server -m models/llama-2-7b.Q4_K_M.gguf --port 8080
```

**Yggdrasil Usage:**
```elixir
agent = Agent.new("custom:llama-2-7b",
  base_url: "http://localhost:8080/v1",
  api_key: "not-needed"
)
```

## Complete Example: Multi-Environment Setup

```elixir
defmodule MyApp.AgentFactory do
  @moduledoc """
  Smart agent creation based on environment and requirements.
  """

  @doc """
  Create agent based on environment.

  - Development: Use free local LM Studio
  - Testing: Use fast local Ollama
  - Production: Use cloud provider
  """
  def create(env \\ Mix.env()) do
    case env do
      :dev ->
        # LM Studio - good for development with UI
        Yggdrasil.Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
          instructions: "Be helpful and concise",
          model_settings: %{temperature: 0.7}
        )

      :test ->
        # Ollama - fast and lightweight for tests
        Yggdrasil.Agent.new("ollama:llama2",
          model_settings: %{temperature: 0.5}
        )

      :prod ->
        # Cloud provider for production reliability
        Yggdrasil.Agent.new("openai:gpt-4",
          model_settings: %{temperature: 0.7}
        )
    end
  end

  @doc """
  Create agent based on data sensitivity.
  """
  def create_for_data_sensitivity(sensitive?) do
    if sensitive? do
      # Keep sensitive data local
      Yggdrasil.Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
        instructions: "Handle all data confidentially"
      )
    else
      # Cloud is fine for public data
      Yggdrasil.Agent.new("groq:llama-3.1-70b-versatile",
        model_settings: %{temperature: 0.7}
      )
    end
  end

  @doc """
  Create agent based on performance requirements.
  """
  def create_for_performance(requirement) do
    case requirement do
      :fastest ->
        # Groq is fastest cloud option
        Yggdrasil.Agent.new("groq:llama-3.1-8b-instant")

      :balanced ->
        # Local LM Studio - no network latency
        Yggdrasil.Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507")

      :highest_quality ->
        # OpenAI GPT-4 for best results
        Yggdrasil.Agent.new("openai:gpt-4")

      :cheapest ->
        # Local Ollama - completely free
        Yggdrasil.Agent.new("ollama:llama2")
    end
  end
end
```

## Model Recommendations

### Small & Fast (< 10GB RAM)
```elixir
# 7B parameter models - fast, low memory
agent = Agent.new("lmstudio:llama-3.2-3b")
agent = Agent.new("ollama:phi3")
agent = Agent.new("ollama:gemma:7b")
```

### Medium Quality (16GB RAM)
```elixir
# 13-30B parameter models - good balance
agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507")
agent = Agent.new("ollama:llama2:13b")
agent = Agent.new("ollama:mistral")
```

### High Quality (32GB+ RAM)
```elixir
# 70B+ parameter models - best quality
agent = Agent.new("lmstudio:llama-3.1-70b")
agent = Agent.new("ollama:llama3.1:70b")
```

## Streaming with Local Models

```elixir
agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507")

{:ok, stream} = Agent.run_stream(agent, "Write a poem about Elixir")

stream
|> Stream.each(fn
  {:text_delta, text} -> IO.write(text)
  {:finish, _reason} -> IO.puts("\n[Done]")
  _ -> :ok
end)
|> Stream.run()
```

## Tools with Local Models

```elixir
defmodule LocalTools do
  @doc "Search local database"
  def search_db(_ctx, query) do
    # Your local database search
    "Results for: #{query}"
  end

  @doc "Get system info"
  def get_system_info(_ctx, _args) do
    %{
      os: :os.type(),
      memory: :erlang.memory(),
      processes: length(Process.list())
    }
  end
end

# Local agent with tools
agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "Help users with system information and data searches",
  tools: [
    &LocalTools.search_db/2,
    &LocalTools.get_system_info/2
  ]
)

{:ok, result} = Agent.run(agent, "What's the system memory usage?")
```

## Configuration for Multiple Local Servers

```elixir
# config/dev.exs
import Config

config :yggdrasil,
  # LM Studio
  lmstudio_base_url: "http://localhost:1234/v1",

  # Ollama
  ollama_base_url: "http://localhost:11434/v1",

  # Custom local server
  custom_base_url: "http://localhost:8080/v1",

  # Finch pools for local connections
  finch: Yggdrasil.Finch

config :yggdrasil, Yggdrasil.Finch,
  pools: %{
    "http://localhost:1234" => [size: 5, count: 1],
    "http://localhost:11434" => [size: 5, count: 1],
    "http://localhost:8080" => [size: 5, count: 1]
  }
```

## Performance Comparison

| Provider | Speed | Cost | Quality | Privacy |
|----------|-------|------|---------|---------|
| LM Studio (Local) | ⚡⚡⚡ | 🆓 Free | ⭐⭐⭐⭐ | 🔒 100% |
| Ollama (Local) | ⚡⚡⚡ | 🆓 Free | ⭐⭐⭐ | 🔒 100% |
| Groq (Cloud) | ⚡⚡⚡⚡ | 💰 Cheap | ⭐⭐⭐⭐ | ☁️ Cloud |
| OpenAI GPT-4 (Cloud) | ⚡⚡ | 💰💰💰 | ⭐⭐⭐⭐⭐ | ☁️ Cloud |

## Troubleshooting

### LM Studio not responding
```elixir
# Check if server is running
System.cmd("curl", ["http://localhost:1234/v1/models"])

# Make sure "Start Server" is clicked in LM Studio UI
```

### Ollama connection refused
```bash
# Start Ollama server
ollama serve

# Or check if it's running
ps aux | grep ollama
```

### Slow inference
```elixir
# Use smaller model
agent = Agent.new("ollama:phi3")  # Instead of llama3.1:70b

# Reduce max_tokens
agent = Agent.new("lmstudio:your-model",
  model_settings: %{max_tokens: 500}
)
```

### Out of memory
```bash
# Use quantized models (Q4, Q5)
# These use less RAM but maintain quality

# In LM Studio: Look for models with "Q4" or "Q5" in name
# In Ollama: Most models are already quantized
```

## Best Practices

### 1. Development Workflow
```elixir
# Use local for development
dev_agent = Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507")

# Test with same API before deploying
# Just change the model string!
prod_agent = Agent.new("openai:gpt-4")
```

### 2. Cost Optimization
```elixir
defmodule CostOptimizer do
  def run_with_budget(prompt, max_cost) do
    cond do
      max_cost == 0 ->
        # Use free local model
        agent = Agent.new("ollama:llama2")
        Agent.run(agent, prompt)

      max_cost < 0.01 ->
        # Use cheap cloud
        agent = Agent.new("groq:llama-3.1-8b-instant")
        Agent.run(agent, prompt)

      true ->
        # Use best quality
        agent = Agent.new("openai:gpt-4")
        Agent.run(agent, prompt)
    end
  end
end
```

### 3. Privacy-First
```elixir
defmodule PrivacyRouter do
  def process(data, contains_pii?) do
    agent = if contains_pii? do
      # Keep PII local
      Agent.new("lmstudio:qwen/qwen3-30b-a3b-2507")
    else
      # Cloud is fine
      Agent.new("openai:gpt-4")
    end

    Agent.run(agent, data)
  end
end
```

## Summary

Local LLMs with Yggdrasil give you:

✅ **Zero cost** - No API fees
✅ **Complete privacy** - Data stays local
✅ **Full control** - Any model, any settings
✅ **Offline capable** - No internet needed
✅ **Same API** - Easy migration to cloud when needed

Start with LM Studio for the easiest experience, then explore Ollama and other options as you grow!
