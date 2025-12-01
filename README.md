![Yggdrasil AI](images/header.jpeg)

# Yggdrasil AI

> Type-safe AI agent framework for Elixir with OpenAI-compatible models

[![Elixir](https://img.shields.io/badge/elixir-~%3E%201.17-purple.svg)](https://elixir-lang.org)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/nyo16/yggdrasil/blob/master/LICENSE)
[![Status](https://img.shields.io/badge/status-working%20mvp-brightgreen.svg)](SUCCESS.md)

Yggdrasil AI is a type-safe AI agent framework for Elixir with support for any OpenAI-compatible API. Features include tool calling, multi-provider support, local LLM execution, and built-in utilities for dates, strings, web search, and task tracking.

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

Then run:
```bash
mix deps.get
```

## Quick Start

```elixir
# Create an agent
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  instructions: "Be helpful and concise"
)

# Run it
{:ok, result} = Yggdrasil.run(agent, "What is 2+2?")

IO.puts(result.output) # "4"
IO.puts("Tokens: #{result.usage.total_tokens}")
```

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

**Local (Zero Cost):** LM Studio, Ollama, vLLM
**Cloud:** OpenAI, Anthropic, Groq, OpenRouter, Together AI

```elixir
# Switch providers with one line change
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b")  # Local
agent = Yggdrasil.new("openai:gpt-4")             # Cloud
agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929")  # Claude
```

## Agent Types

| Feature | `ReActAgent` | Standard `Agent` |
|---------|--------------|------------------|
| **Planning** | Built-in structured planning | No planning (you control flow) |
| **Todo tracking** | Automatic task breakdown | Manual (via custom tools) |
| **Completion** | Explicit `final_answer` required | Stops naturally |
| **Best for** | Complex multi-step problems | Simple tasks, custom workflows |
| **Token usage** | Higher (planning + tracking) | Lower (direct execution) |

### ReActAgent (Enhanced Planning)

Use for complex, multi-step problems with structured planning. Agent creates plans, tracks todos, and documents findings.

```elixir
agent = Yggdrasil.ReActAgent.new("lmstudio:qwen/qwen3-30b",
  tools: [&search/2, &calculate/2]
)

{:ok, result} = Yggdrasil.ReActAgent.run(agent,
  "Who is the oldest F1 driver and when did they win their first championship?"
)
```

See [examples/react_agent_enhanced_demo.exs](examples/react_agent_enhanced_demo.exs)

### Standard Agent (Flexible & Simple)

Use for simple Q&A, single-step tasks, or custom workflows where you control behavior.

```elixir
agent = Yggdrasil.new("openai:gpt-4",
  tools: [&calculate/2]
)
{:ok, result} = Yggdrasil.run(agent, "Calculate 15 * 23")
```

## Built-in Tools

### DateTime Tools
Date/time operations with timezone support, date arithmetic, and formatting.

```elixir
alias Yggdrasil.Tools.DateTimeTools
tools: [&DateTimeTools.current_date/2, &DateTimeTools.date_difference/2, &DateTimeTools.add_days/2]
```

See [examples/datetime_tools_demo.exs](examples/datetime_tools_demo.exs)

### String Tools
Text manipulation: uppercase, replace, split, palindrome detection, number extraction.

```elixir
alias Yggdrasil.Tools.StringTools
tools: [&StringTools.to_uppercase/2, &StringTools.replace_text/2, &StringTools.extract_numbers/2]
```

See [examples/string_tools_demo.exs](examples/string_tools_demo.exs)

### Todo Tools
Automatic task breakdown and progress tracking for multi-step workflows.

```elixir
alias Yggdrasil.Tools.TodoTools
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  enable_todos: true,
  tools: [&TodoTools.add_todo/2, &TodoTools.complete_todo/2]
)
```

See [examples/todo_tools_demo.exs](examples/todo_tools_demo.exs)

### Brave Search (Web Search)
Search the web for current information. Requires `BRAVE_API_KEY` ([get free key](https://brave.com/search/api/)).

```elixir
alias Yggdrasil.Tools.BraveSearch
tools: [&BraveSearch.web_search/2, &BraveSearch.news_search/2]
```

See [examples/brave_search_demo.exs](examples/brave_search_demo.exs)

## Features

### Tool Calling

Define Elixir functions as tools. AI calls them automatically when needed.

```elixir
def search_database(_ctx, %{"query" => q}), do: DB.search(q)

agent = Yggdrasil.new("openai:gpt-4",
  tools: [&search_database/2]
)
```

### Tools with Context

Pass dependencies (user, database, API keys) via context:

```elixir
def get_balance(ctx, _args), do: DB.get_balance(ctx.deps.database, ctx.deps.user.id)

{:ok, result} = Yggdrasil.run(agent, "What's my balance?",
  deps: %{user: %{id: 123}, database: MyApp.DB}
)
```

See [examples/tools_with_context.exs](examples/tools_with_context.exs)

### Conversations

```elixir
{:ok, r1} = Yggdrasil.run(agent, "Tell me a joke")
{:ok, r2} = Yggdrasil.run(agent, "Explain it", message_history: r1.new_messages)
```

### Streaming

```elixir
{:ok, stream} = Yggdrasil.run_stream(agent, "Write a poem")
stream |> Stream.each(fn {:text_delta, t} -> IO.write(t) end) |> Stream.run()
```

### Anthropic Extended Features

```elixir
# 1M token context window
agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929",
  model_settings: %{enable_long_context: true}
)

# Extended thinking mode
agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929",
  model_settings: %{thinking: %{type: "enabled", budget_tokens: 5000}}
)
```

### LiveView Integration

```elixir
{:ok, pid} = MyApp.DistributedAgent.start_agent(
  name: {:via, Registry, {MyApp.AgentRegistry, "user:#{user_id}"}},
  model: "anthropic:claude-sonnet-4-5-20250929",
  owner_pid: self()
)
```

See [distributed_agent_example.ex](examples/distributed_agent_example.ex)

## Logging & Telemetry

Configure log level in `config/config.exs`:
```elixir
config :logger, level: :info  # or :debug, :warning, :error
```

Attach telemetry handlers:
```elixir
Yggdrasil.Telemetry.attach_default_handler()
```

Events: `[:yggdrasil, :agent, :run, :*]`, `[:yggdrasil, :model, :request, :*]`, `[:yggdrasil, :tool, :execute, :*]`

## Examples

See the examples below for all working scripts.

**Core:**
- `test_lm_studio.exs` - Basic LM Studio test
- `calculator_demo.exs` - Multi-tool chaining
- `anthropic_with_tools.exs` - Claude tool calling
- `complete_tool_example.exs` - Real-world 4-tool demo

**Providers:**
- `anthropic_example.exs` - Native Anthropic API
- `anthropic_long_context.exs` - 1M token context
- `anthropic_thinking_mode.exs` - Extended thinking
- `vllm_example.exs` - vLLM server

**Integration:**
- `liveview_agent_example.ex` - Phoenix LiveView
- `distributed_agent_example.ex` - Named agents with Registry
- `genserver_agent_example.ex` - GenServer wrapper

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

- **Lines:** ~2,100 | **Modules:** 16 | **Tests:** 18 passing | **Providers:** 7+

## Contributing

Contributions welcome! Areas for improvement:
- More comprehensive tests
- Structured output validation (Ecto integration)
- Performance benchmarks
- More examples

## License

Apache 2.0 License - see [LICENSE](https://github.com/nyo16/yggdrasil/blob/master/LICENSE)

## Credits

- Inspired by [Pydantic AI](https://ai.pydantic.dev/)
- Built with [openai_ex](https://github.com/cyberchitta/openai_ex)
- Validation with [ecto](https://github.com/elixir-ecto/ecto)
