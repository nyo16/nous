# AGENTS.md

Quick-reference for AI coding agents (Claude, Cursor, Copilot, Codex, etc.)
working with the **Nous** Elixir AI agent framework. This file is for agents
that want to *use* the library, not for agents maintaining the library
itself (see `CONTRIBUTING.md` and `docs/` for that). Conforms to
<https://agents.md>.

## What Nous is

Multi-provider LLM framework for Elixir/OTP. Provides:

- **One-shot LLM calls** (`Nous.generate_text/2,3`, `Nous.stream_text/2,3`)
- **Stateful agents** with tool-calling, memory, plugins (`Nous.new/2`, `Nous.run/2,3`)
- **Pluggable providers** — OpenAI, Anthropic, Gemini, Vertex AI, Groq, Mistral,
  OpenRouter, Together, Ollama, LM Studio, vLLM, SGLang, LlamaCpp, and a
  generic `custom:` adapter for any OpenAI-compatible endpoint
- **Tool system** — file ops, bash, web fetch + search, plus easy custom tools
- **Pluggable HTTP backend** (Req default, hackney alternative)
- **Streaming with backpressure** (hackney `:async, :once` pull mode)

## Minimal API surface (start here)

```elixir
# Drop-in: one-shot text generation
{:ok, text} = Nous.generate_text("openai:gpt-4o", "Explain GenServer in one sentence.")

# Streaming
{:ok, stream} = Nous.stream_text("anthropic:claude-sonnet-4-5", "Write a haiku")
Enum.each(stream, &IO.write/1)

# Stateful agent with tools
agent =
  Nous.new("openai:gpt-4o",
    tools: [Nous.Tools.FileRead, Nous.Tools.FileGrep],
    system_prompt: "You are a code reviewer."
  )

{:ok, result} = Nous.run(agent, "Find all TODOs in lib/")
# result.text, result.messages, result.usage

# Streaming agent run
{:ok, stream} = Nous.run_stream(agent, "Summarize this repo")
```

That's 90% of what most apps need. Everything else is configuration.

## Provider quick-pick (model strings)

Format is `"<provider>:<model_id>"`. Pick one:

| If you want… | Use |
|---|---|
| Best general-purpose, high quality | `openai:gpt-4o` or `anthropic:claude-sonnet-4-5-20250929` |
| Cheap and fast | `groq:llama-3.1-70b-versatile` or `gemini:gemini-2.0-flash` |
| Local / no API key | `lmstudio:<your-loaded-model>` (default port 1234) |
| Local high-throughput inference | `vllm:<huggingface-id>` (default port 8000) |
| Local with structured generation | `sglang:<model>` (default port 30000) |
| Anything else with an OpenAI-compatible API | `custom:<model>` + `:base_url` opt |

Auth picks up the env var by convention: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`GROQ_API_KEY`, `GEMINI_API_KEY`, `OPENROUTER_API_KEY`, etc. Local providers
don't need a key. Override per-call with `api_key:` opt.

## Key opts you'll actually use

```elixir
Nous.new("openai:gpt-4o",
  # LLM behavior
  system_prompt: "...",
  temperature: 0.7,
  max_tokens: 2_000,
  receive_timeout: 60_000,        # ms; 120_000 for local models

  # Tools (modules implementing Nous.Tool.Behaviour)
  tools: [Nous.Tools.Bash, MyApp.MyTool],

  # Memory backend (optional)
  memory: %{store: Nous.Memory.Store.ETS, opts: []},

  # Plugins (optional, composable)
  plugins: [Nous.Plugins.SubAgent, Nous.Plugins.HumanInTheLoop],

  # Resilience
  fallback: ["anthropic:claude-sonnet-4-5", "groq:llama-3.1-70b-versatile"],

  # Vendor-specific body params (vLLM/SGLang/LM Studio/llama.cpp)
  extra_body: %{top_k: 50, repetition_penalty: 1.1}
)
```

## Built-in tools

In `Nous.Tools.*`. The five most useful:

- **`Nous.Tools.Bash`** — execute shell commands (requires approval handler in production)
- **`Nous.Tools.FileRead`** / **`FileWrite`** / **`FileEdit`** — workspace-sandboxed file ops
- **`Nous.Tools.FileGlob`** / **`FileGrep`** — find files / search content
- **`Nous.Tools.WebFetch`** — fetch + extract text from a URL (SSRF-protected)
- **`Nous.Tools.TavilySearch`** / **`BraveSearch`** — web search

File tools enforce a workspace root. Default is `cwd`. Override per-agent:

```elixir
Nous.new("openai:gpt-4o",
  tools: [Nous.Tools.FileRead],
  deps: %{workspace_root: "/path/to/project"}
)
```

## Building a custom tool

```elixir
defmodule MyApp.WeatherTool do
  use Nous.Tool

  @impl Nous.Tool.Behaviour
  def name, do: "get_weather"

  @impl Nous.Tool.Behaviour
  def description, do: "Get current weather for a city"

  @impl Nous.Tool.Behaviour
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "city" => %{"type" => "string", "description" => "City name"}
      },
      "required" => ["city"]
    }
  end

  @impl Nous.Tool.Behaviour
  def execute(%{"city" => city}, _ctx) do
    {:ok, "Weather in #{city}: 72°F, sunny"}
  end
end
```

Pass it in the `tools:` list. The `_ctx` arg gives access to `deps`,
the workspace root, and the approval handler. Use `Nous.Tool.Validator`
for input validation — it runs automatically when `validate_args: true`
(the default).

## HTTP backend (don't change unless you need to)

Default backend is `Nous.HTTP.Backend.Req` — Req on top of Finch. It's
faster under parallel batching than the alternative. Override only if:

- You need HTTP/3 → `NOUS_HTTP_BACKEND=hackney`
- You want one HTTP family across streaming + non-streaming → same

Pool config (hackney pool, used by streaming + Hackney backend):

```elixir
config :nous, :hackney_pool,
  max_connections: 200,
  timeout: 1_500   # idle keepalive ms (hackney 4 caps at 2_000)
```

Streaming **always** uses hackney's pull-based `:async, :once` mode for
backpressure (slow consumer can't OOM under fast LLM). This is structural,
not configurable. See `docs/benchmarks/http_backend.md`.

## Critical rules (security & correctness)

These are project-wide and non-negotiable. If you write code that breaks
these, it will be rejected.

1. **Never `String.to_atom/1` on untrusted input.** Use
   `String.to_existing_atom/1` with rescue, or pattern-match on a
   whitelist of literal strings. The atom table is finite and a
   prompt-injection input can OOM the BEAM.
2. **Tools requiring approval are rejected without an `:approval_handler`.**
   `Bash`, `FileWrite`, `FileEdit` need one wired in `RunContext` or they
   refuse to run. Don't disable this.
3. **File tools enforce a workspace root.** Don't bypass `PathGuard`. Pass
   paths within the workspace; the guard rejects `..` traversal, absolute
   paths outside, and symlink escapes.
4. **HTTP from agents goes through `UrlGuard`.** Don't make raw `Req.get/1`
   calls from a tool to a user-controlled URL — use `Nous.Tools.WebFetch` or
   call `UrlGuard.validate/2` first. Blocks RFC1918, loopback, link-local,
   cloud-metadata IPs.
5. **`PromptTemplate` rejects `<% ... %>` blocks** — only `<%= @var %>`
   substitution is allowed. Don't try to enable EEx evaluation on
   LLM-touched templates; it's an RCE vector.
6. **Sub-agent deps don't auto-forward.** If you spawn a sub-agent via
   `Nous.Plugins.SubAgent`, declare which deps it sees with
   `:sub_agent_shared_deps, [:key1, :key2]`. The default `[]` is correct
   for security.

## Common workflows

### Streaming to LiveView

```elixir
# In your LiveView mount or handle_event:
{:ok, stream} = Nous.stream_text("anthropic:claude-sonnet-4-5", prompt)

stream
|> Stream.each(fn chunk ->
  send(self(), {:llm_chunk, chunk})
end)
|> Stream.run()
```

The hackney backpressure means the stream paces itself to match LiveView's
diff/push throughput — no mailbox accumulation.

### Tool-using agent loop

```elixir
agent =
  Nous.new("openai:gpt-4o",
    tools: [Nous.Tools.FileGrep, Nous.Tools.FileRead, Nous.Tools.Bash],
    max_iterations: 10
  )

{:ok, result} = Nous.run(agent, "Find the bug in lib/foo.ex and explain it")

# result.messages contains the full transcript including tool calls
# result.usage gives token counts per provider
```

### Provider failover

```elixir
agent =
  Nous.new("openai:gpt-4o",
    fallback: [
      "anthropic:claude-sonnet-4-5-20250929",
      "groq:llama-3.1-70b-versatile"
    ]
  )
```

Falls through on transport errors, 5xx, and rate-limit (429) responses.

### Local dev with LM Studio

```elixir
# 1. Start LM Studio, load a model, start the server (default port 1234).
# 2. In Elixir:
{:ok, text} = Nous.generate_text("lmstudio:<exact-model-name-shown-in-lmstudio>",
                                  "Hello!")

# Or override the URL:
agent = Nous.new("lmstudio:my-model", base_url: "http://gpu-host:1234/v1")
```

## Testing your code that uses Nous

```elixir
# Use the test helpers in Nous.Tool.Testing for tool unit tests.
# For end-to-end agent tests, the recommended pattern is to use Bypass to
# stub the LLM HTTP endpoint:

setup do
  bypass = Bypass.open()
  base = "http://localhost:#{bypass.port}/v1"
  {:ok, bypass: bypass, base: base}
end

test "agent calls the model", %{bypass: bypass, base: base} do
  Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(200, ~s({"choices":[{"message":{"content":"hi!"}}]}))
  end)

  agent = Nous.new("custom:test-model", base_url: base, api_key: "test")
  assert {:ok, %{text: "hi!"}} = Nous.run(agent, "hello")
end
```

Don't mock `Req`/`hackney` directly — Bypass is the supported test seam.

## What NOT to use

The public API is `Nous.*` and `Nous.Tools.*`. These are NOT public:

- `Nous.HTTP.Backend.*` — internal; use `HTTP.post/4`'s `:backend` opt instead
- `Nous.Providers.HTTP` — internal helper for provider authors
- `Nous.AgentRunner`, `Nous.AgentServer` — internal supervision; use `Nous.run/3`
- `Nous.Application`, `Nous.Persistence.ETS.TableOwner` — internal supervision tree
- Anything under `Nous.Workflow.Engine.*` — internal; the public API is `Nous.Workflow`
- Anything marked `@moduledoc false` — hidden on purpose; will change without notice

Stick to the documented modules and your code will survive minor version bumps.

## Where to look for more

- **Hex docs:** <https://hexdocs.pm/nous>
- **Getting started:** `docs/getting-started.md`
- **Production guides:** `docs/guides/` (skills, hooks, LiveView integration,
  best practices, tool development, troubleshooting, evaluation, structured
  output, workflows, memory, context, knowledge base)
- **Examples:** `examples/`
- **CHANGELOG:** behavioral changes per release; **read the "Behavioral /
  breaking changes" sections before upgrading**.
