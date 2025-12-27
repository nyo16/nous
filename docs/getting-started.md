# Getting Started with Nous AI

Complete setup guide for the Nous AI framework.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:nous, "~> 0.7.0"}
  ]
end
```

Then run:
```bash
mix deps.get
```

## Quick Setup

### Option 1: Local AI (Free)
Perfect for development and testing.

1. **Download LM Studio** from [lmstudio.ai](https://lmstudio.ai/)
2. **Download a model** (recommended: qwen/qwen3-30b-a3b-2507)
3. **Start server** in LM Studio (runs on http://localhost:1234)
4. **Test it works**:
   ```bash
   mix run -e "
   agent = Nous.new(\"lmstudio:qwen/qwen3-30b\")
   {:ok, result} = Nous.run(agent, \"Hello!\")
   IO.puts(result.output)
   "
   ```

### Option 2: Cloud AI
Perfect for production and advanced models.

**Anthropic (Recommended):**
```bash
export ANTHROPIC_API_KEY="sk-ant-your-key"
```

**OpenAI:**
```bash
export OPENAI_API_KEY="sk-your-key"
```

**Test cloud setup:**
```bash
mix run -e "
agent = Nous.new(\"anthropic:claude-3-5-sonnet\")
{:ok, result} = Nous.run(agent, \"Hello!\")
IO.puts(result.output)
"
```

## Basic Usage

### Simple Chat Agent
```elixir
# Create an agent
agent = Nous.new("anthropic:claude-3-5-sonnet",
  instructions: "You are a helpful assistant"
)

# Ask questions
{:ok, result} = Nous.run(agent, "What is Elixir?")
IO.puts(result.output)

# Check usage
IO.puts("Tokens used: #{result.usage.total_tokens}")
```

### Agent with Tools
```elixir
defmodule MyTools do
  @doc "Get the current weather for a location"
  def get_weather(_ctx, %{"location" => location}) do
    "The weather in #{location} is sunny and 72°F"
  end
end

agent = Nous.new("anthropic:claude-3-5-sonnet",
  instructions: "Use the get_weather tool when asked about weather",
  tools: [&MyTools.get_weather/2]
)

{:ok, result} = Nous.run(agent, "What's the weather in Paris?")
IO.puts(result.output)  # AI automatically calls the weather tool
```

### Streaming Responses
```elixir
agent = Nous.new("anthropic:claude-3-5-sonnet")

Nous.run_stream(agent, "Tell me a story")
|> Enum.each(fn
  {:text_delta, text} -> IO.write(text)  # Print as it arrives
  {:finish, result} -> IO.puts("\n✅ Complete")
end)
```

## Next Steps

### Immediate Next Steps (15 minutes)
1. **Try examples** → [quickstart examples](../examples/quickstart/README.md)
2. **Follow tutorials** → [structured learning](../examples/tutorials/README.md)
3. **Browse by feature** → [reference guides](../examples/reference/README.md)

### Learning Path
- **Beginner** (15 min) → [01-basics](../examples/tutorials/01-basics/README.md)
- **Intermediate** (1 hour) → [02-patterns](../examples/tutorials/02-patterns/README.md)
- **Advanced** (deep dive) → [03-production](../examples/tutorials/03-production/README.md)
- **Complete projects** → [04-projects](../examples/tutorials/04-projects/README.md)

### Production Setup
- **[Best Practices Guide](guides/best_practices.md)** - Production deployment
- **[Tool Development Guide](guides/tool_development.md)** - Custom tools
- **[Troubleshooting Guide](guides/troubleshooting.md)** - Common issues

## Provider Configuration

### All Supported Providers
```elixir
# Local (Free)
agent = Nous.new("lmstudio:qwen/qwen3-30b")
agent = Nous.new("ollama:llama3")

# Cloud
agent = Nous.new("anthropic:claude-3-5-sonnet")
agent = Nous.new("openai:gpt-4o")
agent = Nous.new("gemini:gemini-1.5-pro")
agent = Nous.new("mistral:mistral-large-latest")
agent = Nous.new("groq:llama-3.1-70b-versatile")
```

### Model Settings
```elixir
agent = Nous.new("anthropic:claude-3-5-sonnet",
  model_settings: %{
    temperature: 0.7,      # Creativity (0.0 - 1.0)
    max_tokens: 2000,      # Response length
    top_p: 0.9            # Nucleus sampling
  }
)
```

## Architecture Overview

### Core Concepts
- **Agent**: Stateless configuration object (model + instructions + tools)
- **Tools**: Elixir functions the AI can call
- **Messages**: Structured conversation history
- **Streaming**: Real-time response generation

### Key Features
- **Multi-provider**: Works with 10+ AI providers
- **Tool calling**: AI can execute Elixir functions
- **Streaming**: Real-time response generation
- **Type safety**: Comprehensive type specifications
- **Production ready**: GenServer, LiveView, distributed systems

## Common Patterns

### Error Handling
```elixir
case Nous.run(agent, prompt) do
  {:ok, result} ->
    IO.puts("Success: #{result.output}")
  {:error, reason} ->
    IO.puts("Error: #{reason}")
end
```

### Conversation State
```elixir
defmodule ChatBot do
  use GenServer

  def start_link(model) do
    GenServer.start_link(__MODULE__, model)
  end

  def ask(pid, question) do
    GenServer.call(pid, {:ask, question})
  end

  def init(model) do
    agent = Nous.new(model)
    {:ok, %{agent: agent, messages: []}}
  end

  def handle_call({:ask, question}, _from, state) do
    # Add question to conversation history
    messages = state.messages ++ [%{role: "user", content: question}]

    # Get response from agent
    {:ok, result} = Nous.run(state.agent, messages)

    # Update conversation history
    new_messages = messages ++ [%{role: "assistant", content: result.output}]

    {:reply, result.output, %{state | messages: new_messages}}
  end
end
```

## Troubleshooting

### Connection Issues
- **"Connection refused"**: LM Studio not running or wrong port
- **"401 Unauthorized"**: Check API key is set correctly
- **"Model not found"**: Verify model name spelling

### Performance
- **Slow responses**: Try smaller models or local inference
- **High costs**: Use local models for development
- **Rate limits**: Implement exponential backoff

### Debug Mode
```elixir
# Enable debug logging
require Logger
Logger.configure(level: :debug)

# See all agent iterations and tool calls
{:ok, result} = Nous.run(agent, prompt)
```

For more help, see the **[Troubleshooting Guide](guides/troubleshooting.md)**.

---

## What's Next?

- **Hands-on learning** → [Examples](../examples/README.md)
- **Specific features** → [Reference guides](../examples/reference/README.md)
- **Production deployment** → [Best practices](guides/best_practices.md)
- **Custom tools** → [Tool development](guides/tool_development.md)