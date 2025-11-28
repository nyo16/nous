# Yggdrasil AI

> Type-safe AI agent framework for Elixir with OpenAI-compatible models

[![Elixir](https://img.shields.io/badge/elixir-~%3E%201.17-purple.svg)](https://elixir-lang.org)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/nyo16/yggdrasil/blob/master/LICENSE)
[![Status](https://img.shields.io/badge/status-working%20mvp-brightgreen.svg)](SUCCESS.md)

Yggdrasil AI is a type-safe AI agent framework for Elixir with support for any OpenAI-compatible API.

## Proven Working Features

- **Basic Q&A** - Tested with LM Studio (qwen/qwen3-30b)
- **Custom Instructions** - AI follows instructions
- **Tool Calling** - AI autonomously calls Elixir functions
- **Multi-Tool Chaining** - AI chains multiple tools to solve problems
- **Usage Tracking** - Accurate token counting
- **Multi-Provider** - Same API works with OpenAI, Groq, Ollama, LM Studio
- **Local Execution** - Run locally with LM Studio or Ollama

## Quick Start

```elixir
# 1. Create an agent
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  instructions: "Be helpful and concise"
)

# 2. Run it
{:ok, result} = Yggdrasil.run(agent, "What is 2+2?")

# 3. Get result
IO.puts(result.output) # "4"
IO.puts("Tokens: #{result.usage.total_tokens}")
```

## Real Example - Tool Calling

```elixir
defmodule MathTools do
  @doc "Add two numbers"
  def add(_ctx, %{"a" => a, "b" => b}), do: a + b

  @doc "Multiply two numbers"
  def multiply(_ctx, %{"a" => a, "b" => b}), do: a * b
end

agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  instructions: "Use the math tools to calculate",
  tools: [&MathTools.add/2, &MathTools.multiply/2]
)

# AI automatically calls tools!
{:ok, result} = Yggdrasil.run(agent, "What is (12 + 8) * 5?")

# AI called: add(12, 8) → 20
# AI called: multiply(20, 5) → 100
# AI answered: "100"

IO.puts(result.output) # "(12 + 8) * 5 = 100"
IO.puts("Tool calls: #{result.usage.tool_calls}") # 2
```

The AI decides which tools to call and in what order.

## Supported Providers

| Provider | Model String | Status |
|----------|-------------|--------|
| LM Studio | `lmstudio:qwen/qwen3-30b` | Tested & Working |
| OpenAI | `openai:gpt-4` | Supported |
| Anthropic | `anthropic:claude-sonnet-4-5-20250929` | Tested & Working |
| Google Gemini | `gemini:gemini-2.0-flash-exp` | Native API |
| Groq | `groq:llama-3.1-70b-versatile` | Supported |
| Ollama | `ollama:llama2` | Supported |
| vLLM | `vllm:model` + `:base_url` | Supported |
| OpenRouter | `openrouter:anthropic/claude-3.5-sonnet` | Supported |
| Together AI | `together:meta-llama/Llama-3-70b-chat-hf` | Supported |
| Custom | `custom:model` + `:base_url` | Supported |

## Choosing Your Agent Type

### When to Use `ReActAgent` (Enhanced Planning)

Use **`Yggdrasil.ReActAgent`** for complex, multi-step problems that benefit from structured planning:

```elixir
agent = Yggdrasil.ReActAgent.new("lmstudio:qwen/qwen3-30b",
  instructions: "You are a research assistant",
  tools: [&MyTools.search/2, &MyTools.calculate/2]
)
```

**Perfect for:**
- **Research tasks** - "Find X, analyze Y, compare Z"
- **Multi-step workflows** - Tasks requiring 3+ steps
- **Complex calculations** - Math/logic problems with dependencies
- **Data analysis** - Gather → Process → Report workflows
- **Debugging** - Systematic problem investigation

**Features:**
- **Structured planning** - Agent creates a plan before acting
- **Built-in todo list** - Agent tracks its own progress
- **Note-taking** - Agent documents findings
- **Explicit completion** - Must call `final_answer` to finish
- **Loop prevention** - Avoids repeating the same actions

**Example:**
```elixir
alias Yggdrasil.ReActAgent

agent = ReActAgent.new("openai:gpt-4",
  tools: [&search/2, &calculate/2]
)

# Agent will automatically:
# 1. Create a plan
# 2. Add todos for each step
# 3. Use tools systematically
# 4. Complete todos as it progresses
# 5. Call final_answer when done
{:ok, result} = ReActAgent.run(agent,
  "Who is the oldest F1 driver and when did they win their first championship?"
)
```

**See [examples/react_agent_enhanced_demo.exs](examples/react_agent_enhanced_demo.exs) for complete example!**

---

### When to Use Standard `Agent` (Flexible & Simple)

Use **`Yggdrasil.Agent`** (or just `Yggdrasil.new/2`) for simpler tasks or custom workflows:

```elixir
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  instructions: "Be helpful",
  tools: [&MyTools.search/2]
)
```

**Perfect for:**
- **Simple Q&A** - Direct questions with simple answers
- **Single-step tasks** - One tool call, one answer
- **Custom workflows** - You control the agent's behavior via instructions
- **Quick prototyping** - Fast iteration without overhead
- **Conversational** - Back-and-forth chat interfaces

**When you want:**
- **Speed** - No planning overhead
- **Full control** - You design the workflow
- **Lightweight** - Minimal token usage
- **Custom patterns** - Implement your own agent pattern

**Example:**
```elixir
# Simple: Just answer the question
agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929")
{:ok, result} = Yggdrasil.run(agent, "What is 2+2?")

# With tools: Agent decides when to use them
agent = Yggdrasil.new("openai:gpt-4",
  tools: [&calculate/2]
)
{:ok, result} = Yggdrasil.run(agent, "Calculate 15 * 23")
```

---

### Quick Comparison

| Feature | `ReActAgent` | Standard `Agent` |
|---------|--------------|------------------|
| **Planning** | Built-in structured planning | No planning (you control flow) |
| **Todo tracking** | Automatic task breakdown | Manual (via custom tools) |
| **Completion** | Explicit `final_answer` required | Stops naturally |
| **Best for** | Complex multi-step problems | Simple tasks, custom workflows |
| **Token usage** | Higher (planning + tracking) | Lower (direct execution) |
| **Learning curve** | Easy (automatic) | Easy (manual control) |
| **Built-in tools** | 6 tools (plan, todo, note, etc.) | 0 tools (you add what you need) |
| **Use case** | Research, analysis, debugging | Q&A, simple tasks, chat |

---

### Building Custom Agent Patterns

Want to create your own agent pattern? Wrap `Agent` like we did with `ReActAgent`:

```elixir
defmodule MyApp.CustomAgent do
  alias Yggdrasil.Agent

  def new(model_string, opts \\ []) do
    # Add your custom system prompt
    custom_prompt = "You are a specialized agent that..."

    # Add your custom tools
    custom_tools = [
      &MyTools.tool1/2,
      &MyTools.tool2/2
    ]

    # Combine with user options
    Agent.new(model_string,
      instructions: custom_prompt <> Keyword.get(opts, :instructions, ""),
      tools: custom_tools ++ Keyword.get(opts, :tools, [])
    )
  end

  # Custom run logic if needed
  def run(agent, prompt, opts \\ []) do
    # Initialize custom context
    custom_deps = %{my_state: %{}}
    opts = Keyword.put(opts, :deps, custom_deps)

    Agent.run(agent, prompt, opts)
  end
end
```

**See [lib/yggdrasil/react_agent.ex](lib/yggdrasil/react_agent.ex) for a complete example!**

---

## Test It Now

### Option 1: IEx (Fastest)
```bash
iex -S mix
```
```elixir
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507")
{:ok, r} = Yggdrasil.run(agent, "Say hello!")
r.output
```

### Option 2: Run Examples
```bash
# Basic example
mix run examples/test_lm_studio.exs

# Tool calling
mix run examples/calculator_demo.exs

# Simple tool
mix run examples/tools_simple.exs
```

### Option 3: One-Liner
```bash
mix run -e 'agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507"); {:ok, r} = Yggdrasil.run(agent, "Hi!"); IO.puts(r.output)'
```

## Key Features

### Run Locally (Zero Cost)
```elixir
# LM Studio - any model, beautiful UI
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b")

# Ollama - CLI-focused, easy to use
agent = Yggdrasil.new("ollama:llama2")

# vLLM - high-performance serving
agent = Yggdrasil.new("vllm:qwen/qwen3-30b",
  base_url: "http://localhost:8000/v1"
)
```

### Switch Providers (One Line)
```elixir
# Development - use free local
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b")

# Production - use OpenAI
agent = Yggdrasil.new("openai:gpt-4")

# Production - use Anthropic Claude (native API)
agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929")

# Same code, just change the model string!
```

### Tool Calling
```elixir
# Define any Elixir function
def search_database(_ctx, %{"query" => q}), do: DB.search(q)

# Add to agent
agent = Yggdrasil.new("openai:gpt-4",
  tools: [&search_database/2]
)

# AI calls it automatically when needed!
```

### Tools with Context (User ID, Database, etc.)
```elixir
# Define tools that use context
def get_user_balance(ctx, _args) do
  user = ctx.deps.user           # Access user from context
  db = ctx.deps.database         # Access database

  DB.get_balance(db, user.id)
end

# Pass dependencies when running
deps = %{
  user: %{id: 123, name: "Alice"},
  database: MyApp.Database,
  api_key: "secret"
}

{:ok, result} = Yggdrasil.run(agent, "What's my balance?",
  deps: deps  # Tools get access via ctx.deps
)

# Perfect for:
# - Multi-tenant apps (different user per request)
# - Database injection
# - API key management
# - Per-user permissions
```

**See [examples/tools_with_context.exs](examples/tools_with_context.exs) for complete example!**

### Built-in DateTime Tools
```elixir
alias Yggdrasil.Tools.DateTimeTools

agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  tools: [
    &DateTimeTools.current_date/2,
    &DateTimeTools.current_time/2,
    &DateTimeTools.date_difference/2,
    &DateTimeTools.add_days/2,
    &DateTimeTools.is_weekend/2,
    &DateTimeTools.current_week/2,
    &DateTimeTools.current_month/2
  ]
)

# AI can now answer date/time questions!
{:ok, result} = Yggdrasil.run(agent, "What day is today?")
# => "Today is Thursday, October 9, 2025. It is not a weekend."

{:ok, result} = Yggdrasil.run(agent, "What day will it be 30 days from now?")
# => "30 days from now will be Saturday, November 8, 2025."
```

**Features:**
- Current date/time in multiple formats (ISO8601, US, EU, human-readable)
- Timezone support (America/New_York, Europe/London, etc.)
- Date arithmetic (add/subtract days)
- Date differences (days, weeks, months, years)
- Weekend detection
- Week and month information
- Date parsing in various formats

**See [examples/datetime_tools_demo.exs](examples/datetime_tools_demo.exs) for complete example!**

### Built-in String Tools
```elixir
alias Yggdrasil.Tools.StringTools

agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  tools: [
    &StringTools.string_length/2,
    &StringTools.replace_text/2,
    &StringTools.split_text/2,
    &StringTools.to_uppercase/2,
    &StringTools.capitalize_text/2,
    &StringTools.contains/2,
    &StringTools.extract_words/2,
    &StringTools.is_palindrome/2,
    &StringTools.extract_numbers/2
  ]
)

# AI can now manipulate strings!
{:ok, result} = Yggdrasil.run(agent, "Convert 'hello world' to uppercase")
# => "HELLO WORLD"

{:ok, result} = Yggdrasil.run(agent, "Is 'racecar' a palindrome?")
# => "Yes, 'racecar' is a palindrome."
```

**Features:**
- Text transformation (uppercase, lowercase, capitalize)
- String operations (replace, split, join, trim, substring)
- Pattern matching (contains, starts_with, ends_with)
- String analysis (length, count occurrences, extract words)
- Number extraction and parsing
- Palindrome detection
- Case-sensitive and case-insensitive operations

**Available tools:** `string_length`, `replace_text`, `split_text`, `join_text`, `count_occurrences`, `to_uppercase`, `to_lowercase`, `capitalize_text`, `trim_text`, `substring`, `contains`, `starts_with`, `ends_with`, `reverse_text`, `repeat_text`, `extract_words`, `pad_text`, `is_palindrome`, `extract_numbers`

**See [examples/string_tools_demo.exs](examples/string_tools_demo.exs) for complete example!**

### Built-in Web Search (Brave API)
```elixir
alias Yggdrasil.Tools.BraveSearch

# Set your API key
# export BRAVE_API_KEY="your-api-key-here"
# Get free API key from https://brave.com/search/api/

agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  tools: [
    &BraveSearch.web_search/2,
    &BraveSearch.news_search/2
  ]
)

# AI can now search the web for current information!
{:ok, result} = Yggdrasil.run(agent, "What is the latest version of Elixir?")
# => AI searches the web and gives you current information

{:ok, result} = Yggdrasil.run(agent, "What are the latest AI developments?")
# => AI searches news and summarizes recent developments
```

**Features:**
- Web search for current information
- News search for latest developments
- Automatic source citation (URLs)
- Configurable result count, country, language
- Safe search options

**Rate Limits:**
- Free Plan: 1 query/second, 2,000 queries/month
- Base AI Plan: 20 queries/second, 20M queries/month
- Pro AI Plan: 50 queries/second, unlimited

**Environment Variable:** `BRAVE_API_KEY` - Get your free API key from https://brave.com/search/api/

**See [examples/brave_search_demo.exs](examples/brave_search_demo.exs) for complete example!**

### Built-in Todo Tracking
```elixir
alias Yggdrasil.Tools.TodoTools

# Enable automatic todo tracking
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  instructions: "You are a helpful coding assistant",
  enable_todos: true,  # Enable todo tracking!
  tools: [
    &TodoTools.add_todo/2,
    &TodoTools.update_todo/2,
    &TodoTools.complete_todo/2,
    &TodoTools.list_todos/2
  ]
)

# Give AI a complex task - it breaks it down automatically
{:ok, r1} = Yggdrasil.run(agent, "Analyze codebase and create report",
  deps: %{todos: []}
)

# AI creates todos:
# 📝 Pending: Read source files, Analyze dependencies, Write report

# Continue work - AI sees previous todos
{:ok, r2} = Yggdrasil.run(agent, "Continue with next task",
  deps: %{todos: r1.deps[:todos]}  # Pass todos from previous run
)

# AI updates progress:
# ✅ Completed: Read source files
# ⏳ In Progress: Analyze dependencies
# 📝 Pending: Write report
```

**How It Works:**
1. Tools return `__update_context__` with updated todos
2. AgentRunner merges updates into state
3. Before each model request, todos injected into system prompt
4. AI sees current progress: In Progress, Pending, Completed

**Features:**
- AI automatically breaks down complex tasks
- Self-organizing - AI tracks its own progress
- Persistent across multiple runs (via deps)
- Priority levels (high, medium, low)
- Status tracking (pending, in_progress, completed)
- 20 unit tests

**Perfect For:**
- Multi-step workflows
- Long-running autonomous tasks
- Progress tracking
- Task decomposition

**See [examples/todo_tools_demo.exs](examples/todo_tools_demo.exs) for complete example!**

### Anthropic Extended Context (1M tokens)
```elixir
# Enable 1M token context window for large documents
agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929",
  model_settings: %{
    enable_long_context: true  # Enable extended context
  }
)

# Or enable per-request
{:ok, result} = Yggdrasil.run(agent, large_document,
  model_settings: %{enable_long_context: true}
)
```

### Anthropic Extended Thinking
```elixir
# Enable thinking mode for complex reasoning
agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929",
  model_settings: %{
    thinking: %{
      type: "enabled",
      budget_tokens: 5000  # Allow 5000 tokens for thinking
    }
  }
)

# Claude will "think through" problems before responding
{:ok, result} = Yggdrasil.run(agent, "Solve this complex problem...")
```

### Conversations
```elixir
{:ok, r1} = Yggdrasil.run(agent, "Tell me a joke")
{:ok, r2} = Yggdrasil.run(agent, "Explain it",
  message_history: r1.new_messages
)
```

### LiveView Integration (Named Agents)
```elixir
# Start named agent linked to LiveView
{:ok, agent_pid} = MyApp.DistributedAgent.start_agent(
  name: {:via, Registry, {MyApp.AgentRegistry, "user:#{user_id}"}},
  model: "anthropic:claude-sonnet-4-5-20250929",
  owner_pid: self()  # Links to LiveView
)

# Chat by name (works across cluster!)
{:ok, result} = MyApp.DistributedAgent.chat("user:#{user_id}", message)

# When LiveView dies → Agent dies automatically! ✨
```

**See [Distributed Agents Guide](distributed_agents.html) for complete guide.**

### Streaming
```elixir
{:ok, stream} = Yggdrasil.run_stream(agent, "Write a poem")

stream
|> Stream.each(fn
  {:text_delta, text} -> IO.write(text)
  {:finish, _} -> IO.puts("\n[Done]")
end)
|> Stream.run()
```

### Logging

Yggdrasil includes comprehensive logging at all levels:

**INFO logs** (important operations):
```
21:24:52.774 [info] Starting agent run: agent_7554 with model lmstudio:qwen/qwen3-30b-a3b-2507
21:24:53.324 [info] OpenAI-compatible request completed
  Provider: lmstudio
  Model: qwen/qwen3-30b-a3b-2507
  Duration: 546ms
  Tokens: 223 (in: 197, out: 26)
  Tool calls: 1
21:24:54.115 [info] Agent run completed: agent_7554
  Duration: 1341ms
  Iterations: 2
  Tokens: 446 (in: 394, out: 52)
  Tool calls: 2
  Requests: 2
```

**DEBUG logs** (detailed execution flow):
```
21:24:52.775 [debug] Agent has 2 tools available
21:24:52.776 [debug] Converting 2 tools for provider: lmstudio
21:24:52.776 [debug] Agent iteration 1/10: requesting model response
21:24:52.777 [debug] Routing to OpenAI-compatible adapter for provider: lmstudio
21:24:53.325 [debug] Detected 1 tool call(s): add
21:24:53.325 [debug] Executing tool 'add' (retries: 1, takes_ctx: true)
21:24:53.325 [debug] Tool 'add' executed successfully
```

**ERROR logs** (failures with context):
```
21:25:10.555 [error] Tool 'calculate' failed after all 3 attempt(s)
  Error: division by zero
  Error type: ArithmeticError
  Total duration: 42ms
```

Configure log level in your `config/config.exs`:
```elixir
config :logger, level: :info  # or :debug, :warning, :error
```

### Telemetry & Monitoring

```elixir
# Attach default telemetry handler (logs all events)
Yggdrasil.Telemetry.attach_default_handler()

# Or attach custom handler
:telemetry.attach(
  "my-handler",
  [:yggdrasil, :agent, :run, :stop],
  fn _event, measurements, metadata, _config ->
    IO.puts("Agent #{metadata.agent_name}: #{measurements.duration}ms, #{measurements.total_tokens} tokens")
    # Send to your metrics system
    MyApp.Metrics.track(metadata.tool_name, measurements.duration)
  end,
  nil
)

# Tool names, durations, tokens - all captured!
```

**Events emitted:**
- `[:yggdrasil, :agent, :run, :start|stop|exception]`
- `[:yggdrasil, :model, :request, :start|stop|exception]`
- `[:yggdrasil, :tool, :execute, :start|stop|exception]` - **includes tool_name!**

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:yggdrasil, "~> 0.1.0"},
    {:openai_ex, "~> 0.9.17"}
  ]
end
```

Then:
```bash
mix deps.get
```

## Documentation

- **[docs/SUCCESS.md](docs/SUCCESS.md)** - Verified test results
- **[docs/QUICKSTART.md](docs/QUICKSTART.md)** - 30 second start guide
- **[docs/LOCAL_LLM_GUIDE.md](docs/LOCAL_LLM_GUIDE.md)** - Local model setup
- **[docs/IMPLEMENTATION_GUIDE.md](docs/IMPLEMENTATION_GUIDE.md)** - Complete code examples
- **[docs/PROJECT_STRUCTURE.md](docs/PROJECT_STRUCTURE.md)** - Architecture details
- **[Examples Overview](examples_overview.html)** - Working code examples

## Examples Directory

See the [Examples Overview](examples_overview.html) for working scripts:

### Core Examples
- `test_lm_studio.exs` - Basic LM Studio test (VERIFIED ✅)
- `calculator_demo.exs` - Multi-tool chaining (VERIFIED ✅)
- `anthropic_with_tools.exs` - Claude tool calling (VERIFIED ✅)
- `complete_tool_example.exs` - Real-world 4-tool demo (VERIFIED ✅)

### Provider Examples
- `anthropic_example.exs` - Native Anthropic API
- `anthropic_long_context.exs` - 1M token context window
- `anthropic_thinking_mode.exs` - Extended thinking
- `vllm_example.exs` - vLLM server integration

### Integration Examples
- `liveview_agent_example.ex` - Phoenix LiveView integration
- `distributed_agent_example.ex` - Named agents with Registry
- `genserver_agent_example.ex` - GenServer wrapper

### Guides
- `README.md` - Examples overview
- `LIVEVIEW_INTEGRATION.md` - LiveView patterns
- `DISTRIBUTED_AGENTS.md` - Named agents & clustering

## Architecture

```
User Code
    ↓
Yggdrasil.Agent (config)
    ↓
Yggdrasil.AgentRunner (execution loop)
    ↓
├─→ OpenAICompatible (model adapter)
│       ↓
│   OpenaiEx (HTTP client)
│       ↓
│   LM Studio / OpenAI / Groq / etc.
│
├─→ ToolExecutor (run functions)
├─→ Messages (format conversion)
└─→ Usage (track tokens)
```

## Stats

```
Lines of Code:    ~2,100
Source Files:     16 modules
Tests:            18 passing
Providers:        7 supported
Status:           Working MVP
Verified:         Tool calling with LM Studio
```

## Learn More

### Guides
- Getting started → See this README
- Tool development → See `examples/calculator_demo.exs`
- Local LLMs → See `LOCAL_LLM_GUIDE.md`
- Architecture → See `PROJECT_STRUCTURE.md`

### Real Test Results
- Basic Q&A → Rhyming response verified
- Tool calling → Weather tool verified
- Multi-tool → Calculator chaining verified
- Token tracking → Accurate counts verified

## Contributing

Contributions welcome! This is an MVP with lots of room for improvement.

### Areas for Contribution
- [ ] More comprehensive tests
- [ ] Structured output validation (Ecto integration)
- [ ] Usage limit enforcement
- [ ] Telemetry instrumentation
- [ ] More examples
- [ ] Performance benchmarks

## License

Apache 2.0 License - see [LICENSE](https://github.com/nyo16/yggdrasil/blob/master/LICENSE) for details.

## Credits

- Inspired by [Pydantic AI](https://ai.pydantic.dev/) by the Pydantic team
- Built with [openai_ex](https://github.com/cyberchitta/openai_ex)
- Validation with [ecto](https://github.com/elixir-ecto/ecto)

---

**Quick Start:**

```bash
iex -S mix
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b-a3b-2507")
{:ok, r} = Yggdrasil.run(agent, "What is 2+2?")
IO.puts(r.output)
```
