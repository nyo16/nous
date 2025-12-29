# Providers & Models Examples

Examples for specific AI providers and model configurations.

## Learning Path
New to providers? Follow this progression:
1. **[Provider Switching](https://github.com/nyo16/nous/blob/master/examples/tutorials/01-basics/04-provider-switch.exs)** - Compare providers
2. **[Provider-specific features](https://github.com/nyo16/nous/blob/master/examples/anthropic_with_tools.exs)** - Claude tools
3. **[Local vs Cloud](https://github.com/nyo16/nous/blob/master/examples/local_vs_cloud.exs)** - Cost optimization

## Local Models (Free!)

### LM Studio
- **[02-simple-qa.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/01-basics/02-simple-qa.exs)** - Basic LM Studio usage
- **[local_lm_studio.exs](https://github.com/nyo16/nous/blob/master/examples/local_lm_studio.exs)** - Complete LM Studio guide
- **[test_lm_studio.exs](https://github.com/nyo16/nous/blob/master/examples/test_lm_studio.exs)** - Quick test script

### Setup Instructions
```bash
# 1. Download LM Studio from lmstudio.ai
# 2. Download a model (e.g., qwen3-30b)
# 3. Start server (http://localhost:1234)
# 4. Use in any example:
agent = Nous.new("lmstudio:qwen/qwen3-30b")
```

### Other Local Providers
```elixir
# Ollama
agent = Nous.new("ollama:llama3")

# vLLM
agent = Nous.new("openai:llama-3-8b",
  base_url: "http://localhost:8000")

# SGLang
agent = Nous.new("openai:qwen2-7b",
  base_url: "http://localhost:30000")
```

## Cloud Providers

### Anthropic (Claude)
- **[anthropic_example.exs](https://github.com/nyo16/nous/blob/master/examples/anthropic_example.exs)** - Basic Claude usage
- **[anthropic_with_tools.exs](https://github.com/nyo16/nous/blob/master/examples/anthropic_with_tools.exs)** - Claude tool calling
- **[anthropic_thinking_mode.exs](https://github.com/nyo16/nous/blob/master/examples/anthropic_thinking_mode.exs)** - Claude thinking
- **[anthropic_long_context.exs](https://github.com/nyo16/nous/blob/master/examples/anthropic_long_context.exs)** - 1M token context

```elixir
# Claude models
agent = Nous.new("anthropic:claude-3-5-sonnet-20241022")
agent = Nous.new("anthropic:claude-3-5-haiku-20241022")
```

### OpenAI (GPT)
- **[openai_example.exs](https://github.com/nyo16/nous/blob/master/examples/openai_example.exs)** - Basic GPT usage
- **[openai_with_vision.exs](https://github.com/nyo16/nous/blob/master/examples/openai_with_vision.exs)** - GPT-4V image analysis

```elixir
# OpenAI models
agent = Nous.new("openai:gpt-4o")
agent = Nous.new("openai:gpt-4o-mini")
agent = Nous.new("openai:o1-preview")
```

### Google Gemini
- **[gemini_example.exs](https://github.com/nyo16/nous/blob/master/examples/gemini_example.exs)** - Gemini usage
- **[gemini_with_tools.exs](https://github.com/nyo16/nous/blob/master/examples/gemini_with_tools.exs)** - Gemini function calling

```elixir
# Gemini models
agent = Nous.new("gemini:gemini-1.5-pro")
agent = Nous.new("gemini:gemini-1.5-flash")
```

### Mistral AI
- **[mistral_example.exs](https://github.com/nyo16/nous/blob/master/examples/mistral_example.exs)** - Mistral usage

```elixir
# Mistral models
agent = Nous.new("mistral:mistral-large-latest")
agent = Nous.new("mistral:pixtral-12b-2409")
```

### Other Providers
```elixir
# Groq (fast inference)
agent = Nous.new("groq:llama-3.1-70b-versatile")

# Together AI
agent = Nous.new("together:meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo")

# OpenRouter (access to many models)
agent = Nous.new("openrouter:anthropic/claude-3.5-sonnet")
```

## Provider Comparison

### Feature Matrix
| Provider | Tools | Streaming | Vision | Context | Cost |
|----------|-------|-----------|--------|---------|------|
| **Anthropic** | ✅ | ✅ | ✅ | 200K | $$$ |
| **OpenAI** | ✅ | ✅ | ✅ | 128K | $$$ |
| **Gemini** | ✅ | ✅ | ✅ | 2M | $$ |
| **Mistral** | ✅ | ✅ | ✅ | 128K | $$ |
| **Local** | ✅ | ✅ | Some | Varies | Free |

### Performance Comparison
- **[04-provider-switch.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/01-basics/04-provider-switch.exs)** - Compare same prompt
- **[comparing_providers.exs](https://github.com/nyo16/nous/blob/master/examples/comparing_providers.exs)** - Detailed comparison
- **[cost_tracking_example.exs](https://github.com/nyo16/nous/blob/master/examples/cost_tracking_example.exs)** - Track usage costs

## Cost Optimization

### Local vs Cloud Strategy
- **[local_vs_cloud.exs](https://github.com/nyo16/nous/blob/master/examples/local_vs_cloud.exs)** - Smart routing example

```elixir
# Use local for development, cloud for production
def get_agent(env) do
  case env do
    :dev -> Nous.new("lmstudio:qwen3-30b")
    :prod -> Nous.new("anthropic:claude-3-5-sonnet")
  end
end
```

### Usage Tracking
```elixir
{:ok, result} = Nous.run(agent, prompt)
IO.puts("Tokens: #{result.usage.total_tokens}")
IO.puts("Cost estimate: $#{result.usage.estimated_cost}")
```

## Provider-Specific Features

### Anthropic Claude
- **Thinking Mode**: Internal reasoning steps
- **Tool Use**: Excellent function calling
- **Long Context**: Up to 200K tokens efficiently
- **Safety**: Strong safety guidelines

### OpenAI GPT
- **Vision**: Image understanding (GPT-4V)
- **O1 Models**: Advanced reasoning
- **Function Calling**: Native tool support
- **Assistants API**: Managed conversations

### Google Gemini
- **Long Context**: Up to 2M tokens
- **Multimodal**: Text, images, video, audio
- **Free Tier**: Generous free usage
- **Fast**: Good latency for real-time apps

### Local Models
- **Zero Cost**: No per-token charges
- **Privacy**: Data stays local
- **Offline**: Works without internet
- **Customization**: Fine-tune models

## Setup & Authentication

### API Keys
```bash
# Anthropic
export ANTHROPIC_API_KEY="sk-ant-..."

# OpenAI
export OPENAI_API_KEY="sk-..."

# Gemini
export GEMINI_API_KEY="AIza..."

# Mistral
export MISTRAL_API_KEY="..."
```

### Configuration
```elixir
# Override default settings
agent = Nous.new("anthropic:claude-3-5-sonnet",
  model_settings: %{
    temperature: 0.7,
    max_tokens: 2000,
    top_p: 0.9
  }
)
```

## Troubleshooting Providers

### Common Issues
- **401 Unauthorized**: Check API key is set correctly
- **Rate limits**: Implement exponential backoff
- **Model not found**: Verify model name spelling
- **Connection errors**: Check internet/firewall

### Provider Health Check
```elixir
# Test provider connectivity
def test_provider(provider) do
  agent = Nous.new(provider)
  case Nous.run(agent, "Say 'OK' if you can hear me") do
    {:ok, _result} -> "✅ #{provider} working"
    {:error, error} -> "❌ #{provider} failed: #{error}"
  end
end
```

---

**Next Steps:**
- Start with [04-provider-switch.exs](https://github.com/nyo16/nous/blob/master/examples/tutorials/01-basics/04-provider-switch.exs)
- Set up your preferred provider with API keys
- Try [local LM Studio](https://github.com/nyo16/nous/blob/master/examples/local_lm_studio.exs) for free development
