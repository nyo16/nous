# Nous Examples

Learn Nous through practical examples, from basic usage to advanced patterns.

## Quick Start

```bash
# Run any example
mix run examples/01_hello_world.exs

# Requires LM Studio running locally (default)
# Or set API keys for cloud providers:
export ANTHROPIC_API_KEY="sk-..."
export OPENAI_API_KEY="sk-..."
```

## Core Examples (01-10)

Progressive learning path from basics to advanced features:

| File | Description |
|------|-------------|
| [01_hello_world.exs](https://github.com/nyo16/nous/blob/master/examples/01_hello_world.exs) | Minimal example - create agent, run, get output |
| [02_with_tools.exs](https://github.com/nyo16/nous/blob/master/examples/02_with_tools.exs) | Function-based tools and context access |
| [03_streaming.exs](https://github.com/nyo16/nous/blob/master/examples/03_streaming.exs) | Real-time streaming responses |
| [04_conversation.exs](https://github.com/nyo16/nous/blob/master/examples/04_conversation.exs) | Multi-turn conversations with context continuation |
| [05_callbacks.exs](https://github.com/nyo16/nous/blob/master/examples/05_callbacks.exs) | Map callbacks and process messages (LiveView) |
| [06_prompt_templates.exs](https://github.com/nyo16/nous/blob/master/examples/06_prompt_templates.exs) | EEx templates with variable substitution |
| [07_module_tools.exs](https://github.com/nyo16/nous/blob/master/examples/07_module_tools.exs) | Tool.Behaviour pattern for module-based tools |
| [08_tool_testing.exs](https://github.com/nyo16/nous/blob/master/examples/08_tool_testing.exs) | Mock tools, spy tools, and test helpers |
| [09_agent_server.exs](https://github.com/nyo16/nous/blob/master/examples/09_agent_server.exs) | GenServer-based agent with PubSub |
| [10_react_agent.exs](https://github.com/nyo16/nous/blob/master/examples/10_react_agent.exs) | ReAct pattern for complex reasoning |

## Provider Examples

Provider-specific configuration and features:

| File | Description |
|------|-------------|
| [providers/anthropic.exs](https://github.com/nyo16/nous/blob/master/examples/providers/anthropic.exs) | Claude models, extended thinking, tools |
| [providers/openai.exs](https://github.com/nyo16/nous/blob/master/examples/providers/openai.exs) | GPT models, function calling, settings |
| [providers/lmstudio.exs](https://github.com/nyo16/nous/blob/master/examples/providers/lmstudio.exs) | Local AI with LM Studio |
| [providers/switching_providers.exs](https://github.com/nyo16/nous/blob/master/examples/providers/switching_providers.exs) | Provider comparison and selection |

## Advanced Examples

Production patterns and advanced features:

| File | Description |
|------|-------------|
| [advanced/context_updates.exs](https://github.com/nyo16/nous/blob/master/examples/advanced/context_updates.exs) | Tool context updates and state management |
| [advanced/error_handling.exs](https://github.com/nyo16/nous/blob/master/examples/advanced/error_handling.exs) | Retries, fallbacks, circuit breakers |
| [advanced/telemetry.exs](https://github.com/nyo16/nous/blob/master/examples/advanced/telemetry.exs) | Custom metrics and cost tracking |
| [advanced/cancellation.exs](https://github.com/nyo16/nous/blob/master/examples/advanced/cancellation.exs) | Task and streaming cancellation |
| [advanced/liveview_integration.exs](https://github.com/nyo16/nous/blob/master/examples/advanced/liveview_integration.exs) | Phoenix LiveView integration patterns |

## v0.8.0 Features

These examples showcase new v0.8.0 features:

### Context Continuation
```elixir
# Pass context between runs for multi-turn conversations
{:ok, result1} = Nous.run(agent, "My name is Alice")
{:ok, result2} = Nous.run(agent, "What's my name?", context: result1.context)
```

### Callbacks
```elixir
# Map-based callbacks
Nous.run(agent, "Hello", callbacks: %{
  on_llm_new_delta: fn _event, delta -> IO.write(delta) end
})

# Process messages (for LiveView)
Nous.run(agent, "Hello", notify_pid: self())
```

### Module-Based Tools
```elixir
defmodule MyTool do
  @behaviour Nous.Tool.Behaviour

  @impl true
  def metadata, do: %{name: "my_tool", description: "..."}

  @impl true
  def execute(ctx, args), do: {:ok, result}
end

tool = Nous.Tool.from_module(MyTool)
```

### Prompt Templates
```elixir
template = Nous.PromptTemplate.from_template(
  "You are a <%= @role %> assistant",
  role: :system
)
message = Nous.PromptTemplate.to_message(template, %{role: "helpful"})
```

## Running Examples

Most examples use LM Studio by default (free, local):

1. Download [LM Studio](https://lmstudio.ai/)
2. Load a model (e.g., Qwen)
3. Start the local server
4. Run: `mix run examples/01_hello_world.exs`

For cloud providers, set the appropriate API key:
```bash
ANTHROPIC_API_KEY="..." mix run examples/providers/anthropic.exs
OPENAI_API_KEY="..." mix run examples/providers/openai.exs
```

## Project Examples

For larger project examples (multi-agent systems, trading bots, etc.), see:
- [projects/README.md](projects/README.md)
