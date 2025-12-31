![Nous AI](images/header.jpeg)

# Nous AI

> *"Nous (νοῦς) — the ancient Greek concept of mind, reason, and intellect; the faculty of understanding that grasps truth directly."*

AI agent framework for Elixir with multi-provider LLM support.

[![Elixir](https://img.shields.io/badge/elixir-~%3E%201.15-purple.svg)](https://elixir-lang.org)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/nyo16/nous/blob/master/LICENSE)
[![Status](https://img.shields.io/badge/status-working%20mvp-brightgreen.svg)](#features)

Nous AI is an AI agent framework for Elixir with support for any OpenAI-compatible API. Features include tool calling, multi-provider support, local LLM execution, and built-in utilities for dates, strings, web search, and task tracking.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:nous, "~> 0.8.0"}
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
agent = Nous.new("lmstudio:qwen/qwen3-30b",
  instructions: "Be helpful and concise"
)

# Run it
{:ok, result} = Nous.run(agent, "What is 2+2?")

IO.puts(result.output) # "4"
IO.puts("Tokens: #{result.usage.total_tokens}")
```

## Supported Providers

| Provider | Model String | Streaming |
|----------|-------------|-----------|
| LM Studio | `lmstudio:qwen/qwen3-30b` | ✅ Tested |
| OpenAI | `openai:gpt-4` | ✅ Tested |
| Anthropic | `anthropic:claude-sonnet-4-5-20250929` | ✅ Tested |
| Google Gemini | `gemini:gemini-2.0-flash-exp` | ✅ Tested |
| Mistral AI | `mistral:ministral-3-14b-instruct-2512` | ✅ Tested |
| Groq | `groq:llama-3.1-70b-versatile` | ✅ Supported |
| Ollama | `ollama:llama2` | ✅ Supported |
| vLLM | `vllm:model` + `:base_url` | ✅ Tested |
| SGLang | `sglang:model` + `:base_url` | ✅ Supported |
| OpenRouter | `openrouter:anthropic/claude-3.5-sonnet` | ✅ Supported |
| Together AI | `together:meta-llama/Llama-3-70b-chat-hf` | ✅ Supported |
| Custom | `custom:model` + `:base_url` | ✅ Supported |

All providers use pure Elixir HTTP clients (Req + Finch) with no external LLM library dependencies.

**Local (Zero Cost):** LM Studio, Ollama, vLLM, SGLang
**Cloud:** OpenAI, Anthropic, Mistral AI, Groq, OpenRouter, Together AI

```elixir
# Switch providers with one line change
agent = Nous.new("lmstudio:qwen/qwen3-30b")  # Local
agent = Nous.new("openai:gpt-4")             # Cloud
agent = Nous.new("anthropic:claude-sonnet-4-5-20250929")  # Claude
agent = Nous.new("mistral:ministral-3-14b-instruct-2512")  # Mistral
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
agent = Nous.ReActAgent.new("lmstudio:qwen/qwen3-30b",
  tools: [&search/2, &calculate/2]
)

{:ok, result} = Nous.ReActAgent.run(agent,
  "Who is the oldest F1 driver and when did they win their first championship?"
)
```

See [examples/react_agent_enhanced_demo.exs](examples/react_agent_enhanced_demo.exs) or [by_feature/patterns/](examples/by_feature/README.md#-patterns-agent-reasoning--architecture)

### Standard Agent (Flexible & Simple)

Use for simple Q&A, single-step tasks, or custom workflows where you control behavior.

```elixir
agent = Nous.new("openai:gpt-4",
  tools: [&calculate/2]
)
{:ok, result} = Nous.run(agent, "Calculate 15 * 23")
```

## Built-in Tools

### DateTime Tools
Date/time operations with timezone support, date arithmetic, and formatting.

```elixir
alias Nous.Tools.DateTimeTools
tools: [&DateTimeTools.current_date/2, &DateTimeTools.date_difference/2, &DateTimeTools.add_days/2]
```

See [examples/datetime_tools_demo.exs](examples/datetime_tools_demo.exs) or [by_feature/tools/](examples/by_feature/README.md#-tools-function-calling--actions)

### String Tools
Text manipulation: uppercase, replace, split, palindrome detection, number extraction.

```elixir
alias Nous.Tools.StringTools
tools: [&StringTools.to_uppercase/2, &StringTools.replace_text/2, &StringTools.extract_numbers/2]
```

See [examples/string_tools_demo.exs](examples/string_tools_demo.exs) or [by_feature/tools/](examples/by_feature/README.md#-tools-function-calling--actions)

### Todo Tools
Automatic task breakdown and progress tracking for multi-step workflows.

```elixir
alias Nous.Tools.TodoTools
agent = Nous.new("lmstudio:qwen/qwen3-30b",
  enable_todos: true,
  tools: [&TodoTools.add_todo/2, &TodoTools.complete_todo/2]
)
```

See [examples/todo_tools_demo.exs](examples/todo_tools_demo.exs) or [by_feature/tools/](examples/by_feature/README.md#-tools-function-calling--actions)

### Brave Search (Web Search)
Search the web for current information. Requires `BRAVE_API_KEY` ([get free key](https://brave.com/search/api/)).

```elixir
alias Nous.Tools.BraveSearch
tools: [&BraveSearch.web_search/2, &BraveSearch.news_search/2]
```

See [examples/brave_search_demo.exs](examples/brave_search_demo.exs) or [by_feature/tools/](examples/by_feature/README.md#-tools-function-calling--actions)

## Features

### Tool Calling

Define Elixir functions as tools. AI calls them automatically when needed.

```elixir
def search_database(_ctx, %{"query" => q}), do: DB.search(q)

agent = Nous.new("openai:gpt-4",
  tools: [&search_database/2]
)
```

### Tools with Context

Pass dependencies (user, database, API keys) via context:

```elixir
def get_balance(ctx, _args), do: DB.get_balance(ctx.deps.database, ctx.deps.user.id)

{:ok, result} = Nous.run(agent, "What's my balance?",
  deps: %{user: %{id: 123}, database: MyApp.DB}
)
```

See [examples/tools_with_context.exs](examples/tools_with_context.exs) or [custom_tools_guide.exs](examples/custom_tools_guide.exs)

### Conversations

```elixir
{:ok, r1} = Nous.run(agent, "Tell me a joke")
{:ok, r2} = Nous.run(agent, "Explain it", message_history: r1.new_messages)
```

### Context Continuation

Continue from previous runs with full context preservation:

```elixir
{:ok, result1} = Nous.run(agent, "Search for Elixir tutorials")
# result1.context contains full execution state

{:ok, result2} = Nous.run(agent, "Tell me more about the first one",
  context: result1.context
)
```

### Flexible Input

Pass messages directly instead of a string prompt:

```elixir
alias Nous.Message

{:ok, result} = Nous.run(agent,
  messages: [
    Message.system("You are a helpful assistant who speaks like a pirate"),
    Message.user("What's the weather like?")
  ]
)
```

### Callbacks

Monitor agent execution with callbacks or process messages:

```elixir
# Map-based callbacks
{:ok, result} = Nous.run(agent, "Hello",
  callbacks: %{
    on_llm_new_delta: fn _event, delta -> IO.write(delta) end,
    on_tool_call: fn _event, call -> IO.puts("Calling #{call.name}") end,
    on_agent_complete: fn _event, result -> IO.puts("Done!") end
  }
)

# Process messages (for LiveView)
{:ok, result} = Nous.run(agent, "Hello", notify_pid: self())
# Receives: {:agent_delta, text}, {:tool_call, call}, {:agent_complete, result}
```

### Module-Based Tools

Define tools as modules for better testability:

```elixir
defmodule MyApp.Tools.Search do
  @behaviour Nous.Tool.Behaviour

  @impl true
  def metadata do
    %{
      name: "search",
      description: "Search the web",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query"}
        },
        "required" => ["query"]
      }
    }
  end

  @impl true
  def execute(ctx, %{"query" => query}) do
    # Inject http_client via ctx.deps for testing
    http = ctx.deps[:http_client] || MyApp.HTTP
    {:ok, http.search(query)}
  end
end

# Use with agent
agent = Nous.new("openai:gpt-4",
  tools: [Nous.Tool.from_module(MyApp.Tools.Search)]
)
```

### Tool Testing Helpers

```elixir
alias Nous.Tool.Testing

# Mock tools
mock = Testing.mock_tool("search", %{results: ["a", "b"]})

# Spy tools (record calls)
{spy, calls} = Testing.spy_tool("search", result: %{found: true})
# ... use spy in agent ...
recorded = Testing.get_calls(calls)

# Test contexts
ctx = Testing.test_context(%{database: mock_db, api_key: "test"})
```

### Prompt Templates

Build prompts with EEx variable substitution:

```elixir
alias Nous.PromptTemplate

# Create templates
template = PromptTemplate.from_template(
  "You are a <%= @role %> assistant that speaks <%= @language %>.",
  role: :system
)

# Format with variables
message = PromptTemplate.to_message(template, %{role: "helpful", language: "Spanish"})

# Build message lists
messages = PromptTemplate.to_messages([
  PromptTemplate.system("You are <%= @persona %>"),
  PromptTemplate.user("Tell me about <%= @topic %>")
], %{persona: "a historian", topic: "ancient Rome"})

# Use with agent
{:ok, result} = Nous.run(agent, messages: messages)
```

### Streaming

```elixir
{:ok, stream} = Nous.run_stream(agent, "Write a poem")
stream |> Stream.each(fn {:text_delta, t} -> IO.write(t) end) |> Stream.run()
```

#### Stream Events

| Event | Description |
|-------|-------------|
| `{:text_delta, text}` | Incremental text content |
| `{:thinking_delta, text}` | Reasoning/thinking content (vLLM, DeepSeek, SGLang) |
| `{:tool_call_delta, calls}` | Tool call information |
| `{:finish, reason}` | Stream completion |

#### Thinking/Reasoning Streams

For models with reasoning capabilities (DeepSeek-R1, QwQ, etc.):

```elixir
stream |> Stream.each(fn
  {:thinking_delta, t} -> IO.write("[thinking] #{t}")
  {:text_delta, t} -> IO.write(t)
  _ -> :ok
end) |> Stream.run()
```

### Anthropic Extended Features

```elixir
# 1M token context window
agent = Nous.new("anthropic:claude-sonnet-4-5-20250929",
  model_settings: %{enable_long_context: true}
)

# Extended thinking mode
agent = Nous.new("anthropic:claude-sonnet-4-5-20250929",
  model_settings: %{thinking: %{type: "enabled", budget_tokens: 5000}}
)
```

### LiveView Integration

**Option 1: Streaming with spawn_link**

```elixir
# Spawn linked streaming process from LiveView
spawn_link(fn ->
  agent = Nous.new("anthropic:claude-sonnet-4-5-20250929")

  {:ok, stream} = Nous.run_stream(agent, message)

  stream
  |> Stream.each(fn
    {:text_delta, text} -> send(parent, {:stream_chunk, text})
    {:finish, result} -> send(parent, {:stream_complete, result})
    _ -> :ok
  end)
  |> Stream.run()
end)
```

**Option 2: AgentServer with PubSub**

For stateful conversations with automatic event broadcasting:

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    # Start agent linked to this LiveView
    {:ok, agent_pid} = Nous.AgentServer.start_link(
      session_id: socket.assigns.session_id,
      agent_config: %{
        model: "lmstudio:qwen/qwen3-30b",
        instructions: "You are a helpful assistant",
        tools: []
      }
    )

    # Subscribe to responses
    Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:#{socket.assigns.session_id}")

    {:ok, assign(socket, agent_pid: agent_pid, messages: [])}
  end

  def handle_event("send_message", %{"message" => msg}, socket) do
    Nous.AgentServer.send_message(socket.assigns.agent_pid, msg)
    {:noreply, socket}
  end

  # Receive streaming deltas
  def handle_info({:agent_delta, text}, socket) do
    {:noreply, update(socket, :current_response, &(&1 <> text))}
  end

  # Receive complete response
  def handle_info({:agent_complete, result}, socket) do
    messages = socket.assigns.messages ++ [%{role: :assistant, content: result.output}]
    {:noreply, assign(socket, messages: messages, current_response: "")}
  end

  # Handle tool calls
  def handle_info({:tool_call, call}, socket) do
    # Show tool call in UI
    {:noreply, socket}
  end
end
```

See [liveview_streaming_example.ex](examples/liveview_streaming_example.ex) for real-time streaming or [LiveView Integration Guide](docs/guides/liveview-integration.md) for patterns

## Logging & Telemetry

Configure log level in `config/config.exs`:
```elixir
config :logger, level: :info  # or :debug, :warning, :error
```

Attach telemetry handlers:
```elixir
Nous.Telemetry.attach_default_handler()
```

**Events:**
- Agent: `[:nous, :agent, :run, :start/stop/exception]`, `[:nous, :agent, :iteration, :start/stop]`
- Provider: `[:nous, :provider, :request, :start/stop/exception]`, `[:nous, :provider, :stream, :start/connected/chunk/exception]`
- Tool: `[:nous, :tool, :execute, :start/stop/exception]`, `[:nous, :tool, :timeout]`
- Context: `[:nous, :context, :update]`
- Callback: `[:nous, :callback, :execute]`

## Examples

**🚀 [Get Started in 5 Minutes](docs/getting-started.md)** - Quick setup guide with local or cloud options.

**📚 [Full Examples Collection](examples/README.md)** - Comprehensive learning path from beginner to production.

### Learning Path Overview

**🟢 Beginner** (5-15 minutes each)
- [basic_hello_world.exs](examples/basic_hello_world.exs) - 30-second minimal example
- [test_lm_studio.exs](examples/test_lm_studio.exs) - Local LM Studio setup
- [tools_simple.exs](examples/tools_simple.exs) - Basic tool calling
- [calculator_demo.exs](examples/calculator_demo.exs) - Multi-tool chaining

**🟡 Intermediate** (15-45 minutes each)
- [streaming_example.exs](examples/streaming_example.exs) - Real-time responses
- [conversation_history_example.exs](examples/conversation_history_example.exs) - Multi-turn chat
- [error_handling_example.exs](examples/error_handling_example.exs) - Graceful failure handling
- [cost_tracking_example.exs](examples/cost_tracking_example.exs) - Monitor token usage

**🔴 Advanced** (45+ minutes each)
- [Trading Desk](examples/trading_desk/README.md) - Production multi-agent system
- [Council](examples/council/README.md) - Multi-LLM deliberation
- [Coderex](examples/coderex/README.md) - AI code editor with SEARCH/REPLACE

**Browse by:**
- [Skill Level](examples/by_level/README.md) - Beginner → Intermediate → Advanced
- [Provider](examples/by_provider/README.md) - Anthropic, OpenAI, Local, etc.
- [Feature](examples/by_feature/README.md) - Tools, Streaming, Patterns, etc.

**Quick Templates:**
- [templates/](examples/templates/README.md) - Copy-paste starter files

## Architecture

```
User Code
    ↓
Nous.Agent (config + behaviour_module)
    ↓
Nous.AgentRunner (execution loop)
    ↓
├─→ Nous.Agent.Context (unified state)
│   ├─ messages, tool_calls, deps
│   ├─ usage, needs_response
│   └─ callbacks, notify_pid
│
├─→ Nous.Agent.Behaviour (extensible)
│   ├─ Nous.Agents.BasicAgent (default)
│   └─ Nous.Agents.ReActAgent (planning)
│
├─→ Nous.Agent.Callbacks (event system)
│   ├─ Map-based callbacks
│   └─ Process messages (LiveView)
│
├─→ Nous.ModelDispatcher (routes to provider)
│       ↓
│   Nous.Provider (behaviour)
│       ↓
│   ┌───────────────────────────────────────────────┐
│   │ Providers.OpenAI    Providers.Anthropic       │
│   │ Providers.Gemini    Providers.Mistral         │
│   │ Providers.LMStudio  Providers.VLLM            │
│   │ Providers.SGLang    Providers.OpenAICompatible│
│   └───────────────────────────────────────────────┘
│       ↓
│   Nous.Providers.HTTP (Req + Finch)
│       ↓
│   StreamNormalizer (behaviour)
│       ↓
│   Normalized stream events
│
├─→ ToolExecutor (run functions with timeout)
│   ├─ Tool.Behaviour (module-based tools)
│   ├─ Tool.ContextUpdate (structured updates)
│   └─ Tool.Validator (argument validation)
│
├─→ Messages (format conversion)
├─→ Usage (track tokens)
└─→ PromptTemplate (EEx templates)
```

### Stream Normalizer

Nous uses an extensible behaviour pattern for normalizing streaming responses from different providers:

```elixir
# Default normalizer handles most OpenAI-compatible providers
Nous.StreamNormalizer.OpenAI

# Mistral has its own normalizer
Nous.StreamNormalizer.Mistral
```

#### Custom Normalizer

For providers with unique formats, implement the `Nous.StreamNormalizer` behaviour:

```elixir
defmodule MyApp.CustomNormalizer do
  @behaviour Nous.StreamNormalizer

  @impl true
  def normalize_chunk(chunk) do
    # Transform provider-specific format to stream events
    [{:text_delta, chunk["custom_field"]}]
  end

  @impl true
  def complete_response?(chunk), do: false

  @impl true
  def convert_complete_response(_chunk), do: []
end

# Use it with your model
agent = Nous.new("openai_compatible:custom-model",
  base_url: "http://custom-server/v1",
  stream_normalizer: MyApp.CustomNormalizer
)
```

## Stats

- **Lines:** ~10,000 | **Modules:** 41 | **Tests:** 219 passing | **Providers:** 12

## Contributing

Contributions welcome! Areas for improvement:
- More comprehensive tests
- Structured output validation (Ecto integration)
- Performance benchmarks
- More examples

## License

Apache 2.0 License - see [LICENSE](https://github.com/nyo16/nous/blob/master/LICENSE)

## Credits

- Inspired by [Pydantic AI](https://ai.pydantic.dev/)
- HTTP client [Req](https://github.com/wojtekmach/req)
- Connection pooling [Finch](https://github.com/sneako/finch)
- Validation with [Ecto](https://github.com/elixir-ecto/ecto)
