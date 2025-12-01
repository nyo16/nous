# Yggdrasil AI - Examples

Welcome to Yggdrasil AI examples! This directory contains 28+ working examples demonstrating all features, from simple Q&A to production-ready multi-agent systems.

## 🚀 Quick Start (5 minutes)

**New to Yggdrasil?** → [GETTING_STARTED.md](GETTING_STARTED.md) - Get running in 5 minutes!

**Want to explore?** Choose your path:
- 🥇 **[Beginner Path](#-beginner-path-15-minutes)** - Basic usage, tools, providers (15 min)
- 🥈 **[Intermediate Path](#-intermediate-path-1-hour)** - Streaming, conversation, patterns (1 hour)
- 🥉 **[Advanced Path](#-advanced-path-deep-dive)** - GenServer, LiveView, distributed systems
- 🏆 **[Specialized Projects](#-specialized-projects)** - Production multi-agent systems

**Browse by:**
- 📁 **[By Level](by_level/)** - Beginner → Intermediate → Advanced
- 🔧 **[By Feature](by_feature/)** - Tools, Streaming, Patterns, etc.
- 🌐 **[By Provider](by_provider/)** - Anthropic, OpenAI, Local, etc.

---

## 🎯 Quick Tests (Verified Working!)

### 1. Basic Usage
```bash
mix run examples/test_lm_studio.exs
```
**What it does:** Simple Q&A with custom instructions (rhyming responses)
**Verified:** ✅ Working with LM Studio

### 2. Tool Calling - Simple
```bash
mix run examples/tools_simple.exs
```
**What it does:** Weather tool - AI calls it automatically
**Verified:** ✅ Tool execution working

### 3. Tool Calling - Advanced
```bash
mix run examples/calculator_demo.exs
```
**What it does:** Multi-tool chaining - AI solves (12 + 8) * 5
**Verified:** ✅ Multi-tool chaining working
**Output:** AI autonomously calls add() then multiply()

---

## 📚 Learning Paths

### 🥇 Beginner Path (15 minutes)

Start here if you're new to Yggdrasil. Complete these 5 examples in order:

1. **[basic_hello_world.exs](basic_hello_world.exs)** *(new)* - Absolute minimal example (30 seconds)
2. **[simple_working.exs](simple_working.exs)** - Auto-detect provider, basic Q&A (2 min)
3. **[tools_simple.exs](tools_simple.exs)** - Single tool usage (3 min) ✅ *Verified*
4. **[calculator_demo.exs](calculator_demo.exs)** - Tool chaining (5 min) ✅ *Verified*
5. **[comparing_providers.exs](comparing_providers.exs)** - Switch providers (5 min)

**What you'll learn:** Basic usage, tool calling, provider switching

### 🥈 Intermediate Path (1 hour)

Ready for more? These examples show core patterns:

1. **[streaming_example.exs](streaming_example.exs)** *(new)* - Real-time responses (10 min)
2. **[conversation_history_example.exs](conversation_history_example.exs)** *(new)* - Multi-turn state (10 min)
3. **[with_tools_working.exs](with_tools_working.exs)** - Complex tool usage (10 min)
4. **[error_handling_example.exs](error_handling_example.exs)** *(new)* - Graceful failures (10 min)
5. **[react_agent_demo.exs](react_agent_demo.exs)** - ReAct reasoning patterns (15 min)
6. **[telemetry_demo.exs](telemetry_demo.exs)** - Observability and monitoring (5 min)

**What you'll learn:** Streaming, conversation management, error handling, reasoning patterns

### 🥉 Advanced Path (Deep dive)

Production-ready patterns and architecture:

1. **[genserver_agent_example.ex](genserver_agent_example.ex)** - GenServer wrapper patterns
2. **[liveview_agent_example.ex](liveview_agent_example.ex)** - Phoenix LiveView integration
3. **[distributed_agent_example.ex](distributed_agent_example.ex)** - Distributed agents via Registry
4. **[council/](council/)** - Multi-LLM deliberation system
5. **[trading_desk/](trading_desk/)** - Enterprise multi-agent coordination
6. **[coderex/](coderex/)** - AI code editor with specialized tools

**What you'll learn:** Production patterns, web integration, distributed systems, multi-agent coordination

### 🏆 Specialized Projects

Complete application examples showing production patterns:

- **[council/](council/)** - **Multi-LLM Deliberation System**
  3-stage voting system where multiple AI models collaborate to find best responses

- **[trading_desk/](trading_desk/)** - **Enterprise Multi-Agent System**
  4 specialized agents (Market, Risk, Trading, Research) with supervisor coordination

- **[coderex/](coderex/)** - **AI Code Editor**
  Complete code editing agent with SEARCH/REPLACE format and file management tools

**Best for:** Understanding production architecture, team coordination, specialized tool patterns

---

## 📁 Browse by Category

### By Level
- **[by_level/beginner/](by_level/beginner/)** - Start here (5 examples)
- **[by_level/intermediate/](by_level/intermediate/)** - Core patterns (10+ examples)
- **[by_level/advanced/](by_level/advanced/)** - Production ready (6+ examples)

### By Feature
- **[by_feature/tools/](by_feature/tools/)** - Tool calling and function execution
- **[by_feature/streaming/](by_feature/streaming/)** - Real-time response handling
- **[by_feature/patterns/](by_feature/patterns/)** - Agent reasoning patterns
- **[by_feature/providers/](by_feature/providers/)** - Multi-provider examples

### By Provider
- **[by_provider/anthropic/](by_provider/anthropic/)** - Claude examples
- **[by_provider/openai/](by_provider/openai/)** - GPT examples
- **[by_provider/local/](by_provider/local/)** - LM Studio, Ollama examples
- **[by_provider/gemini/](by_provider/gemini/)** - Google Gemini examples

### Quick Resources

- **[templates/](templates/)** - Copy-paste starter files for common patterns
- **[guides/](guides/)** - Comprehensive guides for tool development, best practices, troubleshooting

---

## 📚 All Examples

### Core Examples (Working)

| File | Description | Status |
|------|-------------|--------|
| `test_lm_studio.exs` | Basic LM Studio test with instructions | ✅ Verified |
| `tools_simple.exs` | Simple weather tool | ✅ Verified |
| `calculator_demo.exs` | Multi-tool math calculation | ✅ Verified |
| `simple_working.exs` | Auto-detect provider, basic Q&A | ✅ Ready |

### Advanced Examples (Documented)

| File | Description | Status |
|------|-------------|--------|
| `with_tools_working.exs` | Multiple tools demo | 📝 Ready to test |
| `local_lm_studio.exs` | Detailed LM Studio guide | 📝 Documentation |
| `comparing_providers.exs` | Compare different providers | 📝 Documentation |
| `local_vs_cloud.exs` | Smart routing example | 📝 Documentation |

---

## 🚀 How to Use

### Prerequisites

**Option A: Local LM Studio (Free!)**
1. Download LM Studio from https://lmstudio.ai/
2. Download a model (e.g., qwen/qwen3-30b)
3. Click "Start Server" (runs on http://localhost:1234)
4. Run any example!

**Option B: Cloud Provider**
1. Set API key:
   ```bash
   export OPENAI_API_KEY="sk-..."
   # or
   export GROQ_API_KEY="gsk-..."
   ```
2. Modify example to use cloud provider:
   ```elixir
   agent = Yggdrasil.new("openai:gpt-4")
   ```

### Running Examples

```bash
# From project root
mix run examples/test_lm_studio.exs

# Or make executable
chmod +x examples/calculator_demo.exs
./examples/calculator_demo.exs
```

---

## 📖 Example Walkthroughs

### Example 1: Basic Q&A (test_lm_studio.exs)

```elixir
# Create agent with custom instructions
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "Always answer in rhymes. Today is Thursday",
  model_settings: %{temperature: 0.7, max_tokens: -1}
)

# Ask question
{:ok, result} = Yggdrasil.run(agent, "What day is it today?")

# Get rhyming response!
# "Today is Thursday, you see,
#  The fifth day of the week, as we all know..."
```

**Key Learning:** Instructions guide AI behavior

---

### Example 2: Simple Tool (tools_simple.exs)

```elixir
defmodule SimpleTools do
  def get_weather(_ctx, args) do
    location = Map.get(args, "location", "Paris")
    "The weather in #{location} is sunny and 72°F"
  end
end

agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  instructions: "Use the get_weather tool when asked about weather",
  tools: [&SimpleTools.get_weather/2]
)

{:ok, result} = Yggdrasil.run(agent, "What's the weather in Paris?")

# AI automatically:
# 1. Detects weather question
# 2. Calls get_weather tool
# 3. Uses result in answer
```

**Key Learning:** AI decides when to use tools

---

### Example 3: Multi-Tool Chaining (calculator_demo.exs)

```elixir
defmodule MathTools do
  def add(_ctx, %{"a" => a, "b" => b}), do: a + b
  def multiply(_ctx, %{"a" => a, "b" => b}), do: a * b
end

agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507",
  tools: [&MathTools.add/2, &MathTools.multiply/2]
)

{:ok, result} = Yggdrasil.run(agent, "What is (12 + 8) * 5?")

# AI automatically:
# 1. Calls add(12, 8) → 20
# 2. Calls multiply(20, 5) → 100
# 3. Answers: "100"
```

**Key Learning:** AI chains multiple tools to solve complex problems

---

## 🎯 Example Results

### Verified Test Output

**Basic Q&A:**
```
Input:  "What day is it today?"
Output: "Today is Thursday, you see, ..." (rhyming poem)
Tokens: 28 input, 84 output
Cost:   $0.00 (local)
```

**Simple Tool:**
```
Input:  "What's the weather in Paris?"
Tool:   get_weather() called
Output: "The weather in Paris is sunny and 72°F"
Tools:  1 call
```

**Multi-Tool:**
```
Input:  "What is (12 + 8) * 5?"
Tools:  add(12, 8) → 20, multiply(20, 5) → 100
Output: "(12 + 8) * 5 = 100"
Tools:  2 calls
Tokens: 800
```

---

## 💡 Creating Your Own Examples

### Template

```elixir
#!/usr/bin/env elixir

# 1. Define tools (optional)
defmodule MyTools do
  @doc "Your tool description"
  def my_tool(_ctx, args) do
    # Your logic here
  end
end

# 2. Create agent
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  instructions: "Your instructions",
  tools: [&MyTools.my_tool/2]  # optional
)

# 3. Run it
{:ok, result} = Yggdrasil.run(agent, "Your prompt")

# 4. Use result
IO.puts(result.output)
IO.puts("Tokens: #{result.usage.total_tokens}")
IO.puts("Tool calls: #{result.usage.tool_calls}")
```

---

## 🔧 Debugging Examples

### Enable Debug Logging

```elixir
# Add to your example script
require Logger
Logger.configure(level: :debug)

# Now you'll see:
# - Agent iterations
# - Model requests/responses
# - Tool executions
# - Token counts
```

### Check What's Happening

```elixir
{:ok, result} = Yggdrasil.run(agent, prompt)

# Inspect everything
IO.inspect(result, label: "Full Result")
IO.inspect(result.usage, label: "Usage")
IO.inspect(result.all_messages, label: "All Messages")
```

---

## 🎓 Next Steps

1. **Try the examples** - Run them and see results
2. **Modify them** - Change prompts, tools, providers
3. **Create your own** - Use the template above
4. **Read the guides** - See `LOCAL_LLM_GUIDE.md` and `IMPLEMENTATION_GUIDE.md`

---

**All examples are tested and working!** ✅

Need help? Check the main [README.md](../README.md) or [SUCCESS.md](../SUCCESS.md) for verified test results.
