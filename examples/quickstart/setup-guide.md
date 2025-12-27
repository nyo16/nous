# 🚀 5-Minute Quickstart

Get Nous AI running in 5 minutes or less!

## Option A: Local AI (Free & Fast)
Perfect for development and testing.

### 1. Setup LM Studio (2 minutes)
1. Download [LM Studio](https://lmstudio.ai/) and install
2. Search for and download **"qwen/qwen3-30b-a3b-2507"** model
3. Go to **Local Server** tab, load the model, click **Start Server**
4. Server runs on http://localhost:1234 (keep it running)

### 2. Test It Works (30 seconds)
```bash
mix run examples/quickstart/hello-world.exs
```

**Expected output:**
```
🎉 Hello from Nous AI!
Agent response: Hello! I'm working perfectly...
✅ Success! Ready to build amazing AI applications.
```

**🎉 You're done!** Skip to [What's Next](#whats-next).

---

## Option B: Cloud AI (1 minute)
Perfect for production and advanced models.

### 1. Get API Key (30 seconds)
Choose your provider:

**Anthropic (Recommended):**
```bash
export ANTHROPIC_API_KEY="sk-ant-your-key"
```

**OpenAI:**
```bash
export OPENAI_API_KEY="sk-your-key"
```

**Gemini (Free tier):**
```bash
export GEMINI_API_KEY="AIza-your-key"
```

### 2. Test It Works (30 seconds)
```bash
# Edit hello-world.exs to use your provider:
# Change: "lmstudio:qwen/qwen3-30b"
# To: "anthropic:claude-3-5-sonnet"
mix run examples/quickstart/hello-world.exs
```

---

## What's Next?

### Immediate Next Steps (10 minutes)
Try these examples in order:

```bash
# 1. Basic tool calling (2 min)
mix run examples/tutorials/01-basics/03-tool-calling.exs

# 2. Multi-tool chaining (3 min)
mix run examples/tutorials/01-basics/05-calculator.exs

# 3. Real-time streaming (5 min)
mix run examples/tutorials/02-patterns/01-streaming.exs
```

### Learning Paths

**🥇 New to AI agents?**
→ Follow [tutorials/01-basics/](../tutorials/01-basics/) (15 min)

**🥈 Want specific features?**
→ Browse [reference/](../reference/) by capability

**🥉 Ready for production?**
→ Study [tutorials/03-production/](../tutorials/03-production/)

**🏆 Need inspiration?**
→ Explore [complete projects](../tutorials/04-projects/)

---

## Quick Examples

### Hello World (30 seconds)
```elixir
# Create agent
agent = Nous.new("lmstudio:qwen/qwen3-30b")

# Ask question
{:ok, result} = Nous.run(agent, "Hello!")

# See response
IO.puts(result.output)
```

### Tool Calling (2 minutes)
```elixir
defmodule MyTools do
  def get_weather(_ctx, %{"location" => loc}) do
    "Weather in #{loc}: sunny, 72°F"
  end
end

agent = Nous.new("lmstudio:qwen/qwen3-30b",
  tools: [&MyTools.get_weather/2]
)

{:ok, result} = Nous.run(agent, "What's the weather in Paris?")
# AI automatically calls get_weather function!
```

### Streaming (5 minutes)
```elixir
agent = Nous.new("lmstudio:qwen/qwen3-30b")

Nous.run_stream(agent, "Tell me a story")
|> Enum.each(fn
  {:text_delta, text} -> IO.write(text)  # Print as it arrives
  {:finish, _result} -> IO.puts("\n✅ Complete")
end)
```

---

## Troubleshooting

### "Connection refused"
- **LM Studio**: Make sure server is running (green button)
- **Cloud**: Check your API key is exported correctly

### "Model not found"
- **LM Studio**: Make sure model is loaded in Local Server tab
- **Cloud**: Check model name spelling

### Still having issues?
- Check [troubleshooting guide](../docs/guides/troubleshooting.md)
- Enable debug: `Logger.configure(level: :debug)`

---

## Success Criteria ✅

You know you're ready when:
- ✅ `hello-world.exs` runs and shows AI response
- ✅ You understand how to change the prompt
- ✅ You've tried both Q&A and tool calling
- ✅ You know where to go next for learning

**Total time: 5 minutes** ⚡

**Next step:** Start with [tutorials/01-basics/](../tutorials/01-basics/) for structured learning!