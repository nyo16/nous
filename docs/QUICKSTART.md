# Yggdrasil AI - Quick Start Guide

## 30 Second Quick Start

```bash
# 1. Start IEx
iex -S mix

# 2. Create agent (paste this)
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507")

# 3. Run it (paste this)
{:ok, r} = Yggdrasil.run(agent, "What is 2+2?")

# 4. See result
r.output
```

Done! That's it! ✅

---

## With Tools (1 Minute)

```elixir
# Define a tool
defmodule Tools do
  def get_weather(_ctx, _), do: "Sunny, 72°F"
end

# Create agent with tool
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  tools: [&Tools.get_weather/2]
)

# AI will call the tool automatically!
{:ok, r} = Yggdrasil.run(agent, "What's the weather?")
r.output
```

---

## Examples (Ready to Run)

```bash
# Basic test
mix run examples/test_lm_studio.exs

# Tool calling
mix run examples/tools_simple.exs

# Multi-tool chaining
mix run examples/calculator_demo.exs
```

---

## Different Providers

```elixir
# Local LM Studio
Yggdrasil.new("lmstudio:qwen/qwen3-30b")

# Local Ollama
Yggdrasil.new("ollama:llama2")

# Cloud OpenAI (need API key)
Yggdrasil.new("openai:gpt-4")

# Cloud Groq (need API key)
Yggdrasil.new("groq:llama-3.1-70b-versatile")
```

All use the **exact same API**! Just change the model string.

---

**That's all you need to get started!** 🚀

See [README.md](README.md) for full documentation.
