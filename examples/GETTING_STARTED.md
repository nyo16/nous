# 🚀 Getting Started with Yggdrasil AI (5 minutes)

Get from zero to AI agent in 5 minutes! This guide gets you running your first Yggdrasil example as fast as possible.

## ⚡ Option A: Local AI (Free & Fast)

**Best for:** Testing, development, no API costs

### 1. Download LM Studio (2 minutes)
1. Go to [lmstudio.ai](https://lmstudio.ai/) and download
2. Install and open LM Studio
3. Click **"Search"** tab → search **"qwen3-30b"**
4. Download **"qwen/qwen3-30b-a3b-2507"** model

### 2. Start the Server (30 seconds)
1. Click **"Local Server"** tab in LM Studio
2. Load the qwen3-30b model you downloaded
3. Click **"Start Server"** (runs on http://localhost:1234)
4. Keep this running in the background

### 3. Test It Works (30 seconds)
```bash
# In your Yggdrasil project directory
mix run examples/test_lm_studio.exs
```

**Expected output:**
```
Today is Thursday, you see,
A day that brings such glee...
[rhyming poem about Thursday]

✅ Success! Tokens: 112, Time: 2.3s
```

**🎉 You're done!** Skip to [What's Next](#whats-next).

---

## ⚡ Option B: Cloud AI (Instant)

**Best for:** Production, advanced models, no local setup

### 1. Get an API Key (1 minute)

**Anthropic (Recommended):**
1. Go to [console.anthropic.com](https://console.anthropic.com)
2. Create account → get API key
3. `export ANTHROPIC_API_KEY="sk-ant-..."`

**Or OpenAI:**
1. Go to [platform.openai.com](https://platform.openai.com)
2. Get API key
3. `export OPENAI_API_KEY="sk-..."`

**Or Mistral AI:**
1. Go to [console.mistral.ai](https://console.mistral.ai)
2. Get API key
3. `export MISTRAL_API_KEY="..."`

### 2. Test It Works (30 seconds)
```bash
# Anthropic
export ANTHROPIC_API_KEY="sk-ant-your-key"
mix run examples/anthropic_example.exs

# Or OpenAI
export OPENAI_API_KEY="sk-your-key"
mix run examples/simple_working.exs

# Or Mistral AI
export MISTRAL_API_KEY="your-key"
mix run examples/mistral_example.exs
```

**🎉 You're done!** Continue to [What's Next](#whats-next).

---

## 🎯 What's Next?

### Immediate Next Steps (10 minutes)

Now that it's working, try these in order:

**1. Tool Calling (2 minutes)**
```bash
mix run examples/tools_simple.exs
```
*Shows AI automatically calling functions*

**2. Multi-Tool Chaining (3 minutes)**
```bash
mix run examples/calculator_demo.exs
```
*Shows AI solving (12 + 8) * 5 by calling add() then multiply()*

**3. Different Providers (2 minutes)**
```bash
mix run examples/comparing_providers.exs
```
*Shows switching between local/cloud models*

### Learning Paths

Choose your adventure:

- **🥇 Beginner (15 min total)** → [Back to README](README.md#-beginner-path-15-minutes)
- **🥈 Intermediate (1 hour)** → [README intermediate path](README.md#-intermediate-path-1-hour)
- **🥉 Advanced** → [Production patterns](README.md#-advanced-path-deep-dive)

### Browse Examples

- **[By Level](by_level/README.md)** - Beginner → Advanced progression
- **[By Feature](by_feature/README.md)** - Find specific capabilities
- **[By Provider](by_provider/README.md)** - Platform-specific examples

---

## 🛠️ Troubleshooting

### "Connection refused" or "404 Not Found"
- **LM Studio not running?** Make sure server is started (green "Start Server" button)
- **Wrong port?** LM Studio should show `http://localhost:1234`
- **Model not loaded?** Load a model in "Local Server" tab first

### "API key invalid" or "401 Unauthorized"
- **Check your key:** Make sure API key is correct and exported
- **Check provider:** Anthropic keys start with `sk-ant-`, OpenAI with `sk-`
- **Check credits:** Make sure your account has credits/usage available

### "No such file" or "mix: command not found"
- **Run from project root:** Make sure you're in the Yggdrasil project directory
- **Elixir not installed?** See main [README](../README.md#installation) for setup

### Still having issues?
- Check [guides/troubleshooting.md](guides/troubleshooting.md) for detailed help
- Run with debug: add `Logger.configure(level: :debug)` to see what's happening

---

## 💡 Creating Your First Agent

Ready to build your own? Use this template:

```elixir
#!/usr/bin/env elixir

# Create agent
agent = Yggdrasil.new("lmstudio:qwen/qwen3-30b",
  instructions: "You are a helpful assistant"
)

# Ask it anything
{:ok, result} = Yggdrasil.run(agent, "Tell me a joke")

# See the result
IO.puts(result.output)
```

**Next:** Check out [templates/](templates/README.md) for more patterns!

---

## ✅ Success Criteria

You know you're ready to continue when:

- ✅ You can run `mix run examples/test_lm_studio.exs` (or cloud example)
- ✅ You see AI responses in your terminal
- ✅ You understand how to change the prompt/question
- ✅ You've tried both basic Q&A and tool calling examples

**Time taken:** 5 minutes ⚡

**Next step:** Explore the [learning paths](README.md#-learning-paths) or jump into [specific features](by_feature/README.md)!