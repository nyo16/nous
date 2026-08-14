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
- **Streaming** (Req default; opt into the hackney `:async, :once` pull-mode backend for strict backpressure)

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

# Streaming agent run (text deltas only, no tool execution)
{:ok, stream} = Nous.run_stream(agent, "Summarize this repo")

# Streaming + tool execution in the same call (Nous 0.15.3+)
{:ok, result} = Nous.run(agent, "Search and summarize",
  stream: true,
  callbacks: %{
    on_llm_new_delta: fn _, t -> IO.write(t) end,
    on_llm_new_thinking_delta: fn _, t -> IO.write(["[thinking] ", t]) end
  }
)
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
  parallel_tool_calls: true,      # default false; fan out multi-call turns (side effects interleave)

  # Memory backend (optional)
  memory: %{store: Nous.Memory.Store.ETS, opts: []},

  # Plugins (optional, composable)
  plugins: [Nous.Plugins.SubAgent, Nous.Plugins.HumanInTheLoop],

  # OS confinement for subprocesses (Nous.Tools.Bash). Sibling to :permissions —
  # permissions decide whether a tool runs, the sandbox confines what its
  # subprocess may touch. :read_only | :workspace_write | :danger_full_access.
  sandbox: :workspace_write,

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
  @behaviour Nous.Tool.Behaviour

  @impl Nous.Tool.Behaviour
  def metadata do
    %{
      name: "get_weather",
      description: "Get current weather for a city",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "city" => %{"type" => "string", "description" => "City name"}
        },
        "required" => ["city"]
      }
    }
  end

  # Context comes FIRST, args second.
  @impl Nous.Tool.Behaviour
  def execute(_ctx, %{"city" => city}) do
    {:ok, "Weather in #{city}: 72°F, sunny"}
  end
end
```

Pass the module in the `tools:` list (`tools: [MyApp.WeatherTool]`) — bare
behaviour modules are converted via `Nous.Tool.from_module/1` automatically.
The `_ctx` arg gives access to `deps`, the workspace root, and the approval
handler. Use `Nous.Tool.Validator` for input validation — it runs automatically
when `validate_args: true` (the default).

## HTTP backend (don't change unless you need to)

Default backend is `Nous.HTTP.Backend.Req` — Req on top of Finch. It's
faster under parallel batching than the alternative. Override only if:

- You need HTTP/3 → `NOUS_HTTP_BACKEND=hackney`
- You want one HTTP family across streaming + non-streaming → same

Pool config (hackney pool, used by the Hackney backend):

```elixir
config :nous, :hackney_pool,
  max_connections: 200,
  timeout: 1_500   # idle keepalive ms (hackney 4 caps at 2_000)
```

Streaming defaults to `Nous.HTTP.StreamBackend.Req` (push-based, with an
8 MB in-flight-byte window that parks the producer — and therefore the
socket — until the consumer drains). For STRICT pull-based backpressure
(`:async, :once` — one chunk read per consumer request, no in-flight window
at all), opt into the Hackney stream backend via
`config :nous, :http_stream_backend, Nous.HTTP.StreamBackend.Hackney`,
`NOUS_HTTP_STREAM_BACKEND=hackney`, or the per-call `stream_backend:` option.
See `docs/benchmarks/http_backend.md`.

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
4. **`Nous.Tools.Bash` is confined by `Nous.Sandbox` when a mode is set.**
   `confine/2` wraps argv so the OS enforces the policy; it is pure and never
   spawns. Fail closed: with no usable provider the tool refuses to run rather
   than running unconfined — don't add a passthrough. Runner failure ("bwrap
   could not start") is classified *before* denial, because "the command never
   ran" must not read as "confinement worked". The default is still
   `:danger_full_access` (unconfined, warns once); set
   `config :nous, :sandbox_mode, :workspace_write` or `sandbox:` per agent/run.
   `FileGrep` is a documented exemption — neither provider restricts reads.
5. **HTTP from agents goes through `UrlGuard`.** Don't make raw `Req.get/1`
   calls from a tool to a user-controlled URL — use `Nous.Tools.WebFetch` or
   call `UrlGuard.validate/2` first. Blocks RFC1918, loopback, link-local,
   cloud-metadata IPs.
6. **`PromptTemplate` rejects `<% ... %>` blocks** — only `<%= @var %>`
   substitution is allowed. Don't try to enable EEx evaluation on
   LLM-touched templates; it's an RCE vector.
7. **Sub-agent deps don't auto-forward.** If you spawn a sub-agent via
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

For strict backpressure under LiveView fan-out (so the stream paces itself to
match diff/push throughput, one chunk at a time), opt into the Hackney stream
backend (see the HTTP backend section); the default Req stream backend bounds
in-flight chunks at 8 MB rather than pacing per chunk.

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

The public API is `Nous.*` and `Nous.Tools.*`. The rule is mechanical:
**if a module carries a `@moduledoc` and appears in <https://hexdocs.pm/nous>,
it is public and covered by semver; if it is `@moduledoc false`, it is not.**
Nothing here is "internal by convention" — the code is the contract.

Currently hidden, do not call:

- `Nous.Application`, `Nous.Persistence.ETS.TableOwner`,
  `Nous.Workflow.Checkpoint.ETS.TableOwner` — internal supervision tree and
  ETS table owners
- every `Nous.AgentRunner.*` submodule (prompt assembly, request dispatch,
  the iteration loop, streaming, tool execution) — internal to the runner;
  the entry point is `Nous.AgentRunner` itself
- `Nous.OutputSchema.UseMacro` — implementation of `use Nous.OutputSchema`
- `Nous.Workflow.Engine.Executor`, `Nous.Workflow.Engine.ParallelExecutor`,
  `Nous.Workflow.Engine.StateMerger` — internal node dispatch; use
  `Nous.Workflow` to build and `Nous.Workflow.Engine.execute/1,2` to run
- `Nous.JSON` — internal pretty-printing wrapper over the standard `JSON`
  module
- `Nous.Util` — small shared helpers (atom coercion, option splitting) used
  across internals
- `Nous.Memory.Embedding.Bumblebee.ServingSupervisor` and
  `Nous.Memory.Embedding.Bumblebee.ServingHolder` — process plumbing behind the
  public `Nous.Memory.Embedding.Bumblebee` provider, and only compiled when
  Bumblebee is available

Up to 0.17.0 this section also claimed `Nous.AgentRunner`, `Nous.AgentServer`,
`Nous.Providers.HTTP`, `Nous.HTTP.Backend.*`, `Nous.HTTP.StreamBackend.*` and
`Nous.Workflow.Engine` were private. They never were: all six are documented
extension points that this file, `docs/guides/http_backends.md`, the LiveView
guide and `examples/` already tell you to call. The list was wrong, not the
code — they stay public.

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
