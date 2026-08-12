# Migration Guide

Version-to-version upgrade notes for Nous. One section per release boundary,
oldest first. Every entry here was checked against the code that shipped it —
`CHANGELOG.md` is the full record, this guide is only the part that requires you
to change something.

## Version compatibility

| | |
|---|---|
| Current version | `0.17.0` |
| Elixir | `~> 1.18` |

```elixir
defp deps do
  [{:nous, "~> 0.17.0"}]
end
```

Boundaries are cumulative: if you are skipping versions, read every section
between your current version and your target in order. Only **0.16.1** is
formally breaking. **0.16.3** and **0.16.5** tighten security defaults, which
can change the behaviour of a working setup — those are called out inline.

## Contents

- [0.15.x to 0.16.0](#015x-to-0160) — Gemini/Vertex request surface
- [0.16.0 to 0.16.1](#0160-to-0161) — **breaking**: provider error contract, Goth precedence
- [0.16.1 to 0.16.2](#0161-to-0162) — four deprecations, AgentServer PubSub topic
- [0.16.2 to 0.16.5](#0162-to-0165) — approval-gate and InputGuard defaults
- [0.16.5 to 0.17.0](#0165-to-0170) — `parallel_tool_calls`, AgentRunner split
- [Related guides](#related-guides)

## 0.15.x to 0.16.0

Additive. Nothing to change; a large new request surface for `gemini:` and
`vertex_ai:` becomes available, plus one timeout default worth knowing about.

### New Gemini / Vertex settings

These are `model_settings` (or `default_settings`) keys. They are read by
`Nous.Messages.Gemini` and wired through `build_request_params/3` on both
`Nous.Providers.Gemini` and `Nous.Providers.VertexAI`, so the same key works
against either entry point.

| Setting | Lands in the request as | Notes |
|---------|-------------------------|-------|
| `:thinking_config` | `generationConfig.thinkingConfig` | Accepts `%{thinking_budget: 1024, include_thoughts: true}` or the native `%{"thinkingBudget" => 1024, "includeThoughts" => true}` |
| `:json_response` | `generationConfig.responseMimeType` | `true` forces JSON with no schema |
| `:json_schema` | `generationConfig.responseSchema` | Also forces the JSON mime type |
| `:response_format` | both of the above | Cross-provider shape: `%{type: :json_schema, schema: schema}` or `%{type: :json_object}` |
| `:safety_settings` | top-level `safetySettings` | Atom-keyed entries are stringified for you |
| `:tool_config` | top-level `toolConfig` | Raw map, passed through |
| `:tool_choice` | top-level `toolConfig` | Friendly form: `:auto`, `:any`, `:required`, `:none`, `{:any, ["fn_a"]}` |
| `:native_tools` | extra entries in `tools` | `:google_search`, `:url_context`, `:code_execution`, `{tool, config}` tuples, or raw maps |
| `:cached_content` | top-level `cachedContent` | Pass-through; create the cache via the Vertex REST API |
| `:top_k` | `generationConfig.topK` | |
| `:seed` | `generationConfig.seed` | |
| `:candidate_count` | `generationConfig.candidateCount` | |
| `:presence_penalty` | `generationConfig.presencePenalty` | |
| `:frequency_penalty` | `generationConfig.frequencyPenalty` | |
| `:response_modalities` | `generationConfig.responseModalities` | |

`:tool_config` and `:tool_choice` write the same field, and the raw map wins:
the resolver is `settings[:tool_config] || normalize_tool_choice(settings[:tool_choice])`.
Set one or the other, not both.

```elixir
agent =
  Nous.new("vertex_ai:gemini-3.1-pro-preview",
    instructions: "Answer with citations.",
    model_settings: %{
      thinking_config: %{thinking_budget: 1024, include_thoughts: true},
      native_tools: [:google_search],
      tool_choice: :auto,
      safety_settings: [%{category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_ONLY_HIGH"}]
    }
  )

{:ok, result} = Nous.run(agent, "What shipped in Elixir 1.18?")
```

### Function calling on Gemini/Vertex now works

Before 0.16.0 the high-level `Nous.LLM` path silently dropped `:tools` for
`gemini:` and `vertex_ai:`. Declarations are now serialized into Vertex's
`tools[].functionDeclarations` shape via `Nous.ToolSchema.to_gemini/1`, which
strips OpenAI's `strict` field and unsupported `additionalProperties` from the
parameter schema.

If you worked around the gap by hand-building requests against the Vertex REST
API, you can move back to the normal `:tools` option. Tool calls also survive a
thinking loop now: `thoughtSignature` is preserved on parsed tool calls under
`tool_call["metadata"]["thought_signature"]` and echoed back on the next
assistant turn, including on `{:tool_call_delta, ...}` stream events.

`Nous.LLM.stream_text/3` honours `:tools` as of this release: tool-call deltas
are aggregated per turn, tools execute between turns, and text deltas keep
flowing to the caller as they are produced.

### Streaming timeouts now come from `receive_timeout`

The separate streaming-timeout constants inside `Nous.Providers.VertexAI` (300s)
and `Nous.Providers.Gemini` (120s) were removed. Streaming and non-streaming
both use `model.receive_timeout`, which for every cloud provider defaults to
`180_000` ms.

That is a **shorter** ceiling than the old Vertex streaming path and a **longer**
one than the old Gemini streaming path. If you depended on either, set it
explicitly:

```elixir
agent = Nous.new("vertex_ai:gemini-3.1-pro-preview", receive_timeout: 300_000)
```

## 0.16.0 to 0.16.1

Two breaking changes. Both are about how a misconfiguration surfaces.

### Provider config errors return a tuple instead of raising

`Nous.Providers.LMStudio`, `Nous.Providers.SGLang`, `Nous.Providers.VLLM` and
`Nous.Providers.Custom` return `{:error, {:invalid_config, reason}}` where they
previously raised `ArgumentError`. `Nous.Providers.LlamaCpp` returns
`{:error, %Nous.Errors.ProviderError{}}` where it previously raised, when the
`:llamacpp_model` option is missing.

```elixir
# Before 0.16.1
try do
  Nous.Providers.LMStudio.chat(params)
rescue
  ArgumentError -> {:error, :bad_config}
end

# 0.16.1+
case Nous.Providers.LMStudio.chat(params) do
  {:ok, response} -> {:ok, response}
  {:error, {:invalid_config, reason}} -> {:error, {:bad_config, reason}}
  {:error, reason} -> {:error, reason}
end
```

```elixir
# 0.16.1+ — llamacpp with no :llamacpp_model
{:error, %Nous.Errors.ProviderError{details: :missing_llamacpp_model}} =
  Nous.Providers.LlamaCpp.chat(params)
```

Where the error actually fires depends on the provider's base-URL mode:

- `custom:` requires a base URL. It is resolved from the `:base_url` option,
  then `CUSTOM_BASE_URL`, then `config :nous, :custom, base_url: "..."`. If all
  three are empty you get `{:error, {:invalid_config, reason}}`.
- `lmstudio:`, `vllm:` and `sglang:` resolve `:base_url`, then
  `LMSTUDIO_BASE_URL` / `VLLM_BASE_URL` / `SGLANG_BASE_URL`, then the provider's
  built-in localhost default — so they only fail when the URL you supplied is
  rejected by `Nous.Tools.UrlGuard.validate/2` (bad scheme, unresolvable host,
  SSRF-blocked target).

Per-provider settings live under a provider key, not in a `providers:` map:

```elixir
config :nous, :custom,
  base_url: "http://localhost:8080/v1",
  allow_private_hosts: true
```

Cloud API keys are flat top-level keys read by `Nous.Model`:

```elixir
config :nous,
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  google_ai_api_key: System.get_env("GOOGLE_AI_API_KEY")
```

The high-level entry points — `Nous.run/3`, `Nous.generate_text/3`,
`Nous.Agent.run/3` — already returned result tuples and are unaffected.

One raise survives on purpose and is *not* part of this change:
`Nous.Model.parse/2` still raises `ArgumentError` for `"custom:<model>"` when no
base URL can be resolved, because that happens while you are building the model
struct rather than while dispatching a request. `Nous.new("custom:my-model")`
with nothing configured therefore raises; the tuple contract above governs the
provider call.

### Vertex AI prefers Goth over `VERTEX_AI_ACCESS_TOKEN`

Credential precedence in `Nous.Providers.VertexAI` is now:

1. `:api_key` passed in options — explicit always wins.
2. A configured Goth instance (`:goth` in options or
   `config :nous, :vertex_ai, goth: MyApp.Goth`) — used **exclusively**.
3. `VERTEX_AI_ACCESS_TOKEN` / `config :nous, :vertex_ai, api_key: "..."`.

Previously a Goth failure fell through to step 3, so a stale or missing env var
produced a confusing 401 instead of the real cause. A Goth failure now surfaces
directly:

```elixir
# 0.16.1+
{:error, %{reason: :goth_error, message: _, details: _}} = Nous.run(agent, "hi")

# Goth configured but the dependency is not compiled in
{:error, %{reason: :goth_not_available}} = Nous.run(agent, "hi")
```

If you configured both a Goth instance and `VERTEX_AI_ACCESS_TOKEN` and relied
on the env var as a fallback, pick one. To keep using the env var, drop the
`:goth` configuration:

```elixir
# Before — Goth configured, env var used as a silent fallback
config :nous, :vertex_ai, goth: MyApp.Goth

# After — env-var-only: remove the :goth key entirely
config :nous, :vertex_ai, []
```

See [Vertex AI setup](vertex_ai_setup.md) for the service-account path.

## 0.16.1 to 0.16.2

Four deprecations, one topic change with no compatibility shim, and several
struct/return-shape additions.

### Deprecated functions

All six functions below still exist in 0.17.0 and still behave as they always
did. Each carries `@deprecated`, so calling one produces a compile-time warning
in your project. They are thin wrappers with no logic of their own — migrating
is a mechanical rename, and doing it now is what stops the warning.

| Deprecated | Replacement |
|------------|-------------|
| `Nous.ToolSchema.to_openai/1` | `Nous.Tool.to_openai_schema/1` |
| `Nous.Agent.tool/3` | `Nous.Agent.new/2` with `:tools`, or a `%Nous.Tool{}` |
| `Nous.Eval.run!/2` | `Nous.Eval.run/2` |
| `Nous.Decisions.path_between/4` | `store_mod.query(state, :path_between, from_id: ..., to_id: ...)` |
| `Nous.Decisions.descendants/3` | `store_mod.query(state, :descendants, node_id: ...)` |
| `Nous.Decisions.ancestors/3` | `store_mod.query(state, :ancestors, node_id: ...)` |

```elixir
# Deprecated:
schema = Nous.ToolSchema.to_openai(tool)

# Preferred:
schema = Nous.Tool.to_openai_schema(tool)
```

`Nous.Agent.tool/3` prepended one tool at a time to an existing agent. Build the
list up front instead — `Nous.Agent.new/2` accepts function references, `%Nous.Tool{}`
structs, and `Nous.Tool.Behaviour` modules in the same list.

```elixir
# Deprecated:
agent =
  "openai:gpt-4o"
  |> Nous.Agent.new(instructions: "Be concise")
  |> Nous.Agent.tool(&MyTools.search/2)
  |> Nous.Agent.tool(&MyTools.calculate/2)

# Preferred:
agent =
  Nous.Agent.new("openai:gpt-4o",
    instructions: "Be concise",
    tools: [&MyTools.search/2, &MyTools.calculate/2]
  )
```

`Nous.Eval.run!/2` raised on failure; `Nous.Eval.run/2` returns the tuple the
rest of the library uses.

```elixir
# Deprecated:
report = Nous.Eval.run!(suite)

# Preferred:
{:ok, report} = Nous.Eval.run(suite)
```

The three graph-traversal helpers delegate straight to the store's `query/3`.
Call the store yourself — it is one fewer indirection and the same result.

```elixir
# Deprecated:
{:ok, path} = Nous.Decisions.path_between(Nous.Decisions.Store.ETS, state, from_id, to_id)

# Preferred:
{:ok, path} =
  Nous.Decisions.Store.ETS.query(state, :path_between, from_id: from_id, to_id: to_id)
```

`active_goals/2` and `recent_decisions/3` on `Nous.Decisions` are **not**
deprecated. See [Decision Graph](decisions.md) for the full query list.

### AgentServer publishes on `"nous:agent:<id>"`

`Nous.AgentServer` used to subscribe to a bare `"agent:#{session_id}"` while
`Nous.PubSub.agent_topic/1` already returned `"nous:agent:#{session_id}"` — so
anything publishing through the helper never reached the server. As of 0.16.2
the server subscribes and broadcasts on the helper's topic.

There is no backward-compatible alias. The bare `"agent:<id>"` topic is neither
published to nor subscribed by any part of Nous. Any hardcoded topic string in
your app must be replaced:

```elixir
# Before 0.16.2 — no longer matches anything
Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:#{session_id}")

# 0.16.2+ — always build the topic with the helper
Phoenix.PubSub.subscribe(MyApp.PubSub, Nous.PubSub.agent_topic(session_id))
```

Use the helper rather than the literal string; the prefix is an implementation
detail. See [LiveView integration](liveview-integration.md) for the full
subscribe/handle_info pattern.

### Shape changes to check

- **`%Nous.Usage{}` gained two fields**: `cache_creation_input_tokens` and
  `cache_read_input_tokens`, both defaulting to `0` and summed by
  `Nous.Usage.add/2`. Anthropic and Gemini now populate them, and both providers
  also set `requests: 1` where they previously left it at `0`. Code that
  pattern-matches the struct exhaustively, or that aggregates usage by hand,
  needs updating.
- **`Nous.Messages.OpenAI.decode_arguments/1` returns a tuple**:
  `{:ok, map()} | {:error, {:invalid_json, raw}}` instead of a bare map. Malformed
  tool-call JSON is now tagged and short-circuited into a tool error the model
  can retry against, rather than handed to your tool as bogus arguments.
- **`Nous.Message.tool/3` accepts `:name`**, which threads the original
  `functionCall.name` through. This is required for Gemini/Vertex tool
  roundtrips; if you construct tool-result messages by hand for those providers,
  pass it.

  ```elixir
  Nous.Message.tool(tool_call_id, "Search results: ...", name: "search")
  ```

- **`Nous.Hook` gained `fail_closed`** (default `false`). On a blocking event
  (`:pre_tool_use`, `:pre_request`), a hook that raises or times out currently
  fails open. Opt security-gating hooks into denying instead:

  ```elixir
  hook = Nous.Hook.new(:pre_tool_use, handler: &MyApp.Guard.check/2, fail_closed: true)
  ```

- **Telemetry events were reconciled.** `[:nous, :agent, :iteration, :start]`,
  `[:nous, :agent, :iteration, :stop]`, `[:nous, :context, :update]` and
  `[:nous, :callback, :execute]` are documented *and* emitted now. Conversely
  `[:nous, :provider, :stream, :chunk]` was never reachable and has been removed
  — detach any handler attached to it. See [Observability](observability.md).

## 0.16.2 to 0.16.5

0.16.3 and 0.16.4 are security and hardening releases; 0.16.5 changes two
security defaults. Two of the three items below can make a previously-working
agent start asking for approval, so read them before upgrading an unattended
deployment.

### 0.16.3: module-registered tools honour `requires_approval`

`Nous.Tool.from_module/2` hardcoded `requires_approval: false` instead of
reading it from the tool's metadata, so `Nous.Tools.Bash`, `Nous.Tools.FileWrite`
and `Nous.Tools.FileEdit` registered through the standard path ran with **no**
human-approval gate. It now falls back to the module's metadata the same way
`name`, `description` and `parameters` already did.

No code change is required, but the gate that was silently absent is now active:
make sure an approval handler is wired up, or those tool calls will be denied.
See [Permissions](permissions.md).

### 0.16.5: InputGuard fails closed on dropped strategies

**Behaviour change.** Under the default `aggregation: :any`, a detection
strategy that errored or timed out used to be silently dropped — and if it was
the only real detector, flagged input passed as `:safe`. A dropped strategy now
upgrades an otherwise-`:safe` verdict to `:suspicious`.

The new `:fail_closed` option controls this. It defaults to `true` for
`aggregation: :any` (where a single surviving detector decides the outcome) and
`false` for `:majority` / `:all`, which already count drops against the
configured denominator. Drops emit a `Logger` warning and a
`[:nous, :input_guard, :strategy_dropped]` telemetry event.

A new `:strategy_timeout` option (default `30_000` ms) bounds the parallel,
non-short-circuit path; a strategy exceeding it is killed and counts as a drop.

An `:any` guard with a flaky strategy may now warn or block where it previously
passed. To restore the old behaviour, opt out explicitly:

```elixir
agent = Nous.new("openai:gpt-4o", plugins: [Nous.Plugins.InputGuard])

{:ok, result} =
  Nous.run(agent, user_input,
    deps: %{
      input_guard_config: %{
        strategies: [{Nous.Plugins.InputGuard.Strategies.Pattern, []}],
        aggregation: :any,
        fail_closed: false,
        strategy_timeout: 30_000
      }
    }
  )
```

The better fix is usually to find out why the strategy is being dropped — the
telemetry event and log line carry the count.

### 0.16.5: `:permissive` no longer auto-approves execute-class tools

**Behaviour change.** `Nous.Permissions.requires_approval?/3` is category-aware
and keeps the approval gate on `category: :execute` tools even under
`:permissive` mode. The two-argument `requires_approval?/2` is unchanged and
still returns `false` for every tool under `:permissive`.

Built-in `Nous.Tools.Bash` was already self-gated via its own
`requires_approval: true`, so this closes the gap for **custom** execute-class
tools that relied on the policy for their gate.

```elixir
# Before 0.16.5 — :permissive dropped the gate on everything
policy = Nous.Permissions.build_policy(mode: :permissive)

# 0.16.5+ — unattended shell execution must be requested explicitly
policy = Nous.Permissions.build_policy(mode: :permissive, allow_unattended_execute: true)
```

`allow_unattended_execute` defaults to `false`, so a single `:permissive` switch
can no longer turn an LLM into unattended remote code execution.

0.16.5 also fixed a bypass where a `pre_tool_use` hook returning `{:modify, ...}`
skipped policy approval. No action needed — the modify branch now applies the
same gate as the allow branch.

## 0.16.5 to 0.17.0

One opt-in feature, one internal reorganisation, and three fixes that change
what you observe.

### `parallel_tool_calls`

`%Nous.Agent{}` gains `:parallel_tool_calls`, default `false`. When a single
model response contains multiple tool calls, approved executions fan out under
`Nous.TaskSupervisor`.

```elixir
agent =
  Nous.new("openai:gpt-4o",
    tools: [&MyTools.fetch_user/2, &MyTools.fetch_orders/2],
    parallel_tool_calls: true
  )
```

What stays sequential, in original call order:

- `pre_tool_use` hooks and approval checks, which run *before* the fan-out.
- `post_tool_use` hooks, `on_tool_response` callbacks, the behaviour's
  `:after_tool`, and `Context.merge_deps`, which run *after* it.
- The result messages themselves — providers require call order.

Only the tool executions overlap. Per-tool timeouts remain
`Nous.ToolExecutor`'s job; there is no second outer timeout. A crashed task
surfaces as a per-call tool error instead of sinking the turn.

Leave it off if your tools depend on sequential external side effects within a
single response — HTTP calls and DB writes will interleave. Tools already could
not observe each other's context updates within a turn (the run context is
snapshotted before the tool loop), so that part is unchanged.

If you build `%Nous.Agent{}` structs literally rather than through
`Nous.Agent.new/2`, add the field or accept its default.

### `Nous.AgentRunner` split into a facade plus submodules

Move-only refactor of a 2,188-line module. `Nous.AgentRunner` is now a facade
delegating to internal (`@moduledoc false`) submodules:

| Submodule | Responsibility |
|-----------|----------------|
| `Nous.AgentRunner.PromptAssembly` | Prompt and settings assembly |
| `Nous.AgentRunner.Streaming` | Stream wrapping and consumption |
| `Nous.AgentRunner.RequestDispatch` | Fallback chains, rate limiting, provider settings |
| `Nous.AgentRunner.ToolExecution` | Sequential/parallel tool execution, hooks, approval and policy enforcement |

The public API — `Nous.AgentRunner.run/2,3`, `run_with_context/2,3`,
`run_stream/2,3` — and every telemetry event are unchanged. `Nous.AgentRunner`
stays the documented entry point and holds the canonical option docs that
`Nous.Agent` points at.

No action is required unless you reached into the module's internals, or you
match on module names in stack traces or telemetry metadata.

### Fixes that change what you observe

- **`run_stream/3` emits exactly one `{:complete, _}` event.**
  OpenAI-compatible streams yield two `{:finish, _}` events (the `finish_reason`
  chunk plus the end-of-stream marker) and the result wrapper previously emitted
  a `{:complete, _}` for each — the second one empty. If your consumer skipped
  the first completion, or deduplicated, or read output from the last event, it
  needs updating: the single event now carries the accumulated output.
- **`Nous.Message.extract_text/1` returns `""` for `content: nil`** instead of
  raising `FunctionClauseError`. Thinking models truncated mid-reasoning return
  assistant messages with only `reasoning_content` set; those no longer fail the
  whole run. A `rescue` around this call can go.
- **`Nous.Tools.SearchScrape` is gated on Floki**, like `Nous.Tools.WebFetch`.
  `floki` is an optional dependency (`{:floki, "~> 0.36", optional: true}`); if
  you use either tool, declare it in your own `mix.exs`. Apps that do not
  depend on Floki now compile without the undefined-module warnings.

## Related guides

- [Providers](providers.md) — provider matrix, configuration, and defaults.
- [Vertex AI setup](vertex_ai_setup.md) — service accounts, Goth, regions.
- [Permissions](permissions.md) — policies, approval handlers, tool categories.
- [Decision Graph](decisions.md) — the store `query/3` API behind the deprecated helpers.
- [Observability](observability.md) — telemetry events and default handlers.
- [Hooks](hooks.md) — lifecycle interception and `fail_closed`.
- [Troubleshooting](troubleshooting.md) — symptoms and their causes.
