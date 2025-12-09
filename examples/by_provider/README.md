# 🌐 Examples by AI Provider

Choose examples specific to your AI provider. Each provider has unique features and capabilities.

## 🔵 [Anthropic](anthropic/) (Claude)

**Best for:** Advanced reasoning, long contexts, thinking mode, safety
**Cost:** Pay-per-use, premium pricing

### Examples:
- **[anthropic_example.exs](anthropic/anthropic_example.exs)** - Basic Claude usage via Anthropix
- **[anthropic_with_tools.exs](anthropic/anthropic_with_tools.exs)** - Claude with function calling
- **[anthropic_thinking_mode.exs](anthropic/anthropic_thinking_mode.exs)** - Extended thinking capabilities
- **[anthropic_long_context.exs](anthropic/anthropic_long_context.exs)** - 1M token context windows

**Setup:**
```bash
export ANTHROPIC_API_KEY="sk-ant-your-key"
mix run anthropic_example.exs
```

**Unique Features:** Thinking mode, 1M token contexts, strong safety guardrails

---

## 🟢 [Local](local/) (Free)

**Best for:** Development, privacy, no API costs, offline usage
**Cost:** Free (hardware requirements apply)

### Examples:
- **[test_lm_studio.exs](local/test_lm_studio.exs)** - LM Studio integration ✅ *Verified*
- **[local_lm_studio.exs](local/local_lm_studio.exs)** - Detailed setup guide
- **[local_vs_cloud.exs](local/local_vs_cloud.exs)** - Local/cloud comparison

**Setup:**
1. Download [LM Studio](https://lmstudio.ai/)
2. Download a model (e.g., qwen3-30b)
3. Start server on http://localhost:1234
4. Run examples!

**Popular Local Models:**
- **qwen3-30b** - Fast, capable, good balance
- **llama3-70b** - Powerful, requires more RAM
- **codellama** - Code-focused capabilities

---

## 🟡 [OpenAI](openai/) (GPT)

**Best for:** General purpose, widespread compatibility, established patterns
**Cost:** Pay-per-use, moderate pricing

### Examples:
- **[simple_working.exs](openai/simple_working.exs)** - Auto-detection (defaults to OpenAI)
- **[comparing_providers.exs](openai/comparing_providers.exs)** - Provider comparison

**Setup:**
```bash
export OPENAI_API_KEY="sk-your-key"
mix run simple_working.exs
```

**Popular Models:** `gpt-4`, `gpt-4-turbo`, `gpt-3.5-turbo`

---

## 🔴 [Gemini](gemini/) (Google)

**Best for:** Multimodal (text + images), Google ecosystem integration
**Cost:** Competitive pricing, generous free tier

### Examples:
- **[gemini_example.exs](gemini/gemini_example.exs)** - Google Gemini integration

**Setup:**
```bash
export GEMINI_API_KEY="your-key"
mix run gemini_example.exs
```

**Popular Models:** `gemini-2.0-flash-exp`, `gemini-pro`

---

## 🚀 Multi-Provider Examples

Examples that work across providers:

- **[../../comparing_providers.exs](../../comparing_providers.exs)** - Compare multiple providers
- **[../../local_vs_cloud.exs](../../local_vs_cloud.exs)** - Smart routing between local/cloud

---

## 🔄 Provider Switching Guide

### Change Model String
```elixir
# Local
agent = Nous.new("lmstudio:qwen/qwen3-30b")

# Cloud providers
agent = Nous.new("anthropic:claude-sonnet-4-5-20250929")
agent = Nous.new("openai:gpt-4")
agent = Nous.new("gemini:gemini-2.0-flash-exp")
```

### Provider-Specific Features
```elixir
# Anthropic thinking mode
agent = Nous.new("anthropic:claude-sonnet-4-5-20250929",
  model_settings: %{thinking: %{type: "enabled", budget_tokens: 5000}}
)

# Anthropic long context
agent = Nous.new("anthropic:claude-sonnet-4-5-20250929",
  model_settings: %{enable_long_context: true}
)
```

---

## 💰 Cost & Performance Comparison

| Provider | Cost | Speed | Context | Features |
|----------|------|-------|---------|----------|
| **Local** | Free | Fast | 4k-32k | Privacy, offline |
| **Anthropic** | High | Medium | 1M | Thinking, safety |
| **OpenAI** | Medium | Fast | 128k | Reliable, popular |
| **Gemini** | Low | Fast | 128k | Multimodal, free tier |

---

## 🎯 Choosing Your Provider

### For Development & Testing
→ **Local** (LM Studio) - Free, fast iteration

### For Production Apps
→ **OpenAI** - Reliable, well-documented
→ **Anthropic** - Advanced reasoning, safety

### For Cost-Sensitive Apps
→ **Gemini** - Competitive pricing, good performance
→ **Local** - Zero ongoing costs

### For Advanced Features
→ **Anthropic** - Thinking mode, long context
→ **Gemini** - Multimodal capabilities

---

## 🆘 Provider Troubleshooting

**Local models not responding?**
- Check LM Studio server is running
- Verify model is loaded
- Confirm http://localhost:1234 is accessible

**API key errors?**
- Check key format (Anthropic: `sk-ant-`, OpenAI: `sk-`)
- Verify key is exported in environment
- Confirm account has credits/usage available

**Rate limits?**
- Add delays between requests
- Use slower models or smaller contexts
- Check provider documentation for limits