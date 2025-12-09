# 📋 Nous Agent Templates

Copy-paste starter templates for common Nous patterns. These templates are designed to be customized for your specific use cases.

## 🚀 Quick Start

1. **Copy a template** to your project
2. **Edit the configuration section** (model, instructions, etc.)
3. **Customize for your needs** (add tools, change prompts, etc.)
4. **Run it!**

```bash
# Copy and customize
cp templates/basic_agent.exs my_agent.exs
chmod +x my_agent.exs
./my_agent.exs
```

## 📁 Available Templates

### [basic_agent.exs](basic_agent.exs) - Simplest Possible Agent
**Use for:** Basic Q&A, getting started, simple tasks
```bash
mix run templates/basic_agent.exs
```
**Contains:**
- Basic agent creation
- Model selection (local/cloud)
- Simple question answering
- Error handling
- Usage statistics

**Customize:** Change the model, instructions, and prompt

---

### [tool_agent.exs](tool_agent.exs) - Agent with Function Calling
**Use for:** Agents that need to perform actions, call APIs, access data
```bash
mix run templates/tool_agent.exs
```
**Contains:**
- Multiple example tools (weather, calculator, search, time)
- Tool definition patterns
- Function calling setup
- Tool usage monitoring

**Customize:** Replace example tools with your own functions

**Example tools included:**
- `get_weather/2` - Weather information
- `calculate/2` - Basic math operations
- `get_time/2` - Current timestamp
- `search/2` - Search functionality (mock)

---

### [streaming_agent.exs](streaming_agent.exs) - Real-time Responses
**Use for:** Chat interfaces, long responses, real-time feedback
```bash
mix run templates/streaming_agent.exs
```
**Contains:**
- Simple streaming (just print text)
- Advanced streaming with event handling
- Stream statistics and monitoring
- Buffered streaming for UIs
- Error handling for streams

**Customize:** Change the stream event handlers for your UI

---

### [conversation_agent.exs](conversation_agent.exs) - Multi-turn Chat
**Use for:** Chatbots, conversational agents, stateful interactions
```bash
mix run templates/conversation_agent.exs
```
**Contains:**
- Conversation state management
- Message history tracking
- Interactive chat loop
- Conversation statistics
- Both interactive and scripted modes

**Customize:** Add persistence, change conversation flow

## 🎯 Template Selection Guide

| Need | Template | Time to Customize |
|------|----------|-------------------|
| Simple Q&A | [basic_agent.exs](basic_agent.exs) | 2 minutes |
| Call functions/APIs | [tool_agent.exs](tool_agent.exs) | 10 minutes |
| Real-time responses | [streaming_agent.exs](streaming_agent.exs) | 5 minutes |
| Multi-turn chat | [conversation_agent.exs](conversation_agent.exs) | 15 minutes |

## 🔧 Customization Guide

### 1. Change the Model
```elixir
# Local models (free)
model = "lmstudio:qwen/qwen3-30b"
model = "ollama:llama2"

# Cloud models (paid)
model = "anthropic:claude-sonnet-4-5-20250929"
model = "openai:gpt-4"
model = "gemini:gemini-2.0-flash-exp"
```

### 2. Customize Instructions
```elixir
instructions = """
You are a [ROLE] that [PURPOSE].
[SPECIFIC BEHAVIOR GUIDELINES]
[CONSTRAINTS OR LIMITATIONS]
"""
```

### 3. Add Your Tools
```elixir
defmodule MyCustomTools do
  def my_tool(_ctx, args) do
    # Your custom logic here
    # Return simple data types (string, number, map, list)
  end
end

# Add to agent
tools = [&MyCustomTools.my_tool/2]
```

### 4. Configure Model Settings
```elixir
model_settings = %{
  temperature: 0.7,     # 0.0 = deterministic, 1.0 = creative
  max_tokens: 1000,     # -1 = unlimited
  top_p: 0.9           # Nucleus sampling
}
```

## 💡 Common Patterns

### API Integration Tool
```elixir
def call_api(_ctx, %{"endpoint" => endpoint, "params" => params}) do
  HTTPoison.get!("https://api.example.com/#{endpoint}", [], params: params)
  |> Map.get(:body)
  |> Jason.decode!()
end
```

### Database Query Tool
```elixir
def get_data(_ctx, %{"id" => id}) do
  MyApp.Repo.get(MyModel, id)
  |> Map.take([:field1, :field2])
end
```

### File Operations Tool
```elixir
def save_file(_ctx, %{"filename" => name, "content" => content}) do
  case File.write(name, content) do
    :ok -> "File saved successfully"
    {:error, reason} -> "Error: #{reason}"
  end
end
```

### Environment Context
```elixir
# Pass context to tools
{:ok, result} = Nous.run(agent, prompt,
  deps: %{
    database: MyApp.Repo,
    user_id: 123,
    api_key: System.get_env("API_KEY")
  }
)
```

## 🔍 Debugging Templates

### Enable Debug Logging
Add to any template:
```elixir
require Logger
Logger.configure(level: :debug)
```

### Inspect Results
```elixir
{:ok, result} = Nous.run(agent, prompt)
IO.inspect(result, label: "Full Result", limit: :infinity)
```

### Test Tools Individually
```elixir
# Test your tools directly
MyTools.my_tool(%{}, %{"param" => "value"})
```

## 📚 Next Steps

### From Templates to Examples
Once you've customized a template, explore related examples:

- **From basic_agent.exs** → [examples/by_level/beginner/](../by_level/beginner/)
- **From tool_agent.exs** → [examples/by_feature/tools/](../by_feature/tools/)
- **From streaming_agent.exs** → [examples/by_feature/streaming/](../by_feature/streaming/)
- **From conversation_agent.exs** → [examples/liveview_agent_example.ex](../liveview_agent_example.ex)

### Production Patterns
Ready for production? See:
- [examples/genserver_agent_example.ex](../genserver_agent_example.ex) - Stateful agent processes
- [examples/distributed_agent_example.ex](../distributed_agent_example.ex) - Multi-user agents
- [examples/specialized/trading_desk/](../specialized/trading_desk/) - Enterprise architecture

### Advanced Features
Explore advanced capabilities:
- [guides/tool_development.md](../guides/tool_development.md) - Advanced tool patterns
- [guides/best_practices.md](../guides/best_practices.md) - Production recommendations
- [examples/specialized/council/](../specialized/council/) - Multi-agent collaboration

## 🆘 Need Help?

- **Quick questions**: Check [examples/GETTING_STARTED.md](../GETTING_STARTED.md)
- **Tool issues**: See [guides/tool_development.md](../guides/tool_development.md)
- **General problems**: Check [guides/troubleshooting.md](../guides/troubleshooting.md)

---

**Templates are your starting point - customize them for your specific needs!** 🚀