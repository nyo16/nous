# 🔧 Examples by Feature

Find examples showcasing specific Yggdrasil capabilities. Jump directly to the features you need.

## 🛠️ [Tools](tools/) - Function Calling & Actions

**AI agents that can DO things** - call functions, access APIs, perform actions

### Getting Started with Tools
- **[tools_simple.exs](tools/tools_simple.exs)** - Single tool (weather) ✅ *Verified*
- **[calculator_demo.exs](tools/calculator_demo.exs)** - Multi-tool chaining ✅ *Verified*
- **[with_tools_working.exs](tools/with_tools_working.exs)** - Multiple tools demo

### Built-in Tool Suites
- **[datetime_tools_demo.exs](tools/datetime_tools_demo.exs)** - Date/time operations
- **[string_tools_demo.exs](tools/string_tools_demo.exs)** - Text manipulation
- **[todo_tools_demo.exs](tools/todo_tools_demo.exs)** - Task tracking
- **[brave_search_demo.exs](tools/brave_search_demo.exs)** - Web search integration

### Advanced Tool Patterns
- **[complete_tool_example.exs](tools/complete_tool_example.exs)** - Realistic personal assistant
- **[tools_with_context.exs](tools/tools_with_context.exs)** - Context management
- **[anthropic_with_tools.exs](tools/anthropic_with_tools.exs)** - Claude with tools

**Learn:** Function calling, tool definition, context passing, API integration

---

## 🌊 [Streaming](streaming/) - Real-time Responses

**Stream responses as they're generated** for better user experience

### Coming Soon!
- **streaming_example.exs** *(planned)* - Basic streaming responses
- **streaming_with_tools.exs** *(planned)* - Streaming + function calling
- **streaming_conversation.exs** *(planned)* - Multi-turn streaming chat

**Current Examples:**
- Check [../templates/streaming_agent.exs](../templates/streaming_agent.exs) for streaming patterns

**Learn:** Real-time responses, UI integration, stream handling

---

## 🧠 [Patterns](patterns/) - Agent Reasoning & Architecture

**Advanced agent patterns** for complex problem-solving and system design

### Reasoning Patterns
- **[react_agent_demo.exs](patterns/react_agent_demo.exs)** - ReAct (Reasoning + Acting)
- **[react_agent_enhanced_demo.exs](patterns/react_agent_enhanced_demo.exs)** - ReAct with todos
- **[cancellation_demo.exs](patterns/cancellation_demo.exs)** - Agent cancellation

### Process Architecture
- **[genserver_agent_example.ex](patterns/genserver_agent_example.ex)** - GenServer wrappers
- **[distributed_agent_example.ex](patterns/distributed_agent_example.ex)** - Registry-based distribution

**Learn:** ReAct patterns, process supervision, state management, cancellation

---

## 🌐 [Providers](providers/) - Multi-Provider Support

**Work with different AI providers** and handle provider-specific features

### Provider Comparison
- **[comparing_providers.exs](providers/comparing_providers.exs)** - Compare multiple providers
- **[local_vs_cloud.exs](providers/local_vs_cloud.exs)** - Local vs cloud routing

### Provider-Specific
- **[anthropic_example.exs](providers/anthropic_example.exs)** - Claude integration
- **[gemini_example.exs](providers/gemini_example.exs)** - Google Gemini integration

**Learn:** Provider switching, fallback strategies, provider-specific features

---

## 🎯 Feature Selection Guide

| I need... | Go to... | Time |
|-----------|----------|------|
| **AI to call functions** | [Tools](tools/) | 10 min |
| **Real-time responses** | [Streaming](streaming/) | 5 min |
| **Complex reasoning** | [Patterns](patterns/) | 20 min |
| **Multiple AI providers** | [Providers](providers/) | 10 min |
| **Web integration** | [../liveview_agent_example.ex](../liveview_agent_example.ex) | 30 min |
| **Multi-agent systems** | [../specialized/](../specialized/) | 1+ hour |

---

## 🔀 Feature Combinations

Many real applications combine multiple features:

### Tools + Streaming
```elixir
# Stream responses while calling tools
{:ok, stream} = Yggdrasil.run_stream(agent, "Search for weather in Paris",
  tools: [&WeatherTools.get_weather/2])
```

### Tools + Providers
```elixir
# Fallback between providers with tools
agent = Yggdrasil.new("anthropic:claude-sonnet-4-5-20250929",
  tools: tools,
  fallback_model: "openai:gpt-4"
)
```

### Patterns + Tools
```elixir
# ReAct agent with custom tools
react_agent = Yggdrasil.ReActAgent.new("lmstudio:qwen/qwen3-30b",
  tools: [&search/2, &calculate/2, &take_notes/2]
)
```

---

## 🚀 Advanced Feature Examples

Ready for production patterns?

### Multi-Agent Coordination
- **[../trading_desk/](../trading_desk/)** - 4 specialized agents working together
- **[../council/](../council/)** - Multi-LLM deliberation system

### Complete Applications
- **[../coderex/](../coderex/)** - Full AI code editor
- **[../liveview_chat_example.ex](../liveview_chat_example.ex)** - Web chat application

### Enterprise Patterns
- **[../distributed_agent_example.ex](../distributed_agent_example.ex)** - Distributed agent management
- **[../genserver_agent_example.ex](../genserver_agent_example.ex)** - Production process architecture

---

## 💡 Feature Development Tips

### Building Custom Tools
1. Start with [templates/tool_agent.exs](../templates/tool_agent.exs)
2. See [guides/tool_development.md](../guides/tool_development.md) for advanced patterns
3. Test tools independently before adding to agents

### Streaming Integration
1. Use [templates/streaming_agent.exs](../templates/streaming_agent.exs) as base
2. Handle {:text_delta, text} events for UI updates
3. Buffer chunks for smooth user experience

### Provider Strategy
1. Start with local for development ([by_provider/local/](../by_provider/local/))
2. Add cloud providers for production ([by_provider/](../by_provider/))
3. Implement fallback strategies for reliability

### Performance Optimization
1. Monitor with [telemetry_demo.exs](../telemetry_demo.exs)
2. Use [cancellation_demo.exs](patterns/cancellation_demo.exs) for long operations
3. Consider distributed patterns for scale

---

**Features are the building blocks** - combine them to create powerful AI applications! 🔧