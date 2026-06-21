# Fallback Chains Guide

This guide covers automatic provider/model failover in Nous: declaring a chain of
backup models that are tried in order when the primary model fails with an
infrastructure-level error.

## Overview

A fallback chain is an ordered list of models tried one after another. The first
model is your primary; each subsequent model is a backup. When the primary fails
with a **provider/model-layer error** (an outage, rate limit, server 5xx, auth
failure, timeout), Nous transparently retries the request against the next model
in the chain. The first model that succeeds wins, and its result is returned.

Crucially, fallback only fires for errors where retrying with a *different model*
could plausibly help. Application-level errors (validation failures, hitting the
iteration limit, cancellation, tool errors) are returned immediately — see
[Gotchas](#gotchas).

The feature is implemented by `Nous.Fallback` and wired into every run path:
`Nous.run/3`, `Nous.run_stream/3`, `Nous.LLM.generate_text/3`, and
`Nous.LLM.stream_text/3`.

## Declaring a Fallback Chain

Pass the `:fallback` option to `Nous.new/2`. It accepts an ordered list of model
strings (`"provider:model"`) and/or `%Nous.Model{}` structs.

```elixir
agent =
  Nous.new("openai:gpt-4o",
    instructions: "You are a helpful assistant.",
    fallback: [
      "anthropic:claude-sonnet-4-5-20250929",
      "groq:llama-3.1-70b-versatile"
    ]
  )

{:ok, result} = Nous.run(agent, "Summarize the theory of relativity.")
```

If `openai:gpt-4o` returns a provider error, Nous tries
`anthropic:claude-sonnet-4-5-20250929`; if that also fails, it tries
`groq:llama-3.1-70b-versatile`. If all fail, the last error is returned.

The same `:fallback` option works on the one-shot `Nous.LLM` helpers:

```elixir
{:ok, text} =
  Nous.LLM.generate_text("openai:gpt-4o", "What is 2+2?",
    fallback: ["anthropic:claude-haiku-4-5"]
  )
```

### How the chain is built

When you pass `:fallback`, Nous calls `Nous.Fallback.parse_fallback_models/2` to
normalize the list into `[%Model{}]` (strings are run through `Model.parse/2`,
existing structs pass through). At request time, the primary model is prepended
with `Nous.Fallback.build_model_chain/2` to form the full chain:

```elixir
fallbacks = Nous.Fallback.parse_fallback_models(["anthropic:claude-haiku-4-5"])
#=> [%Nous.Model{provider: :anthropic, model: "claude-haiku-4-5"}]

chain = Nous.Fallback.build_model_chain(primary, fallbacks)
#=> [primary, %Nous.Model{provider: :anthropic, ...}]
```

You normally never call these directly — `Nous.new/2` does it for you — but they
are public if you want to build a chain by hand.

## The Engine: `Fallback.with_fallback/3`

All run paths funnel through `Nous.Fallback.with_fallback/3`:

```elixir
Nous.Fallback.with_fallback(model_chain, fn model ->
  dispatch_request(model)   # returns {:ok, result} | {:error, reason}
end, opts)
```

It walks the chain head-first:

- On `{:ok, result}` it returns immediately.
- On `{:error, reason}` it asks `fallback_eligible?/1`. If eligible **and** there
  is a next model, it logs a warning, emits a telemetry event, and recurses on
  the rest of the chain.
- If the error is **not** eligible, it returns `{:error, reason}` right away — no
  further models are tried.
- On the last model, its result (ok or error) is returned as-is.
- An empty chain returns `{:error, %Nous.Errors.ConfigurationError{}}`.

## What Triggers Failover: `fallback_eligible?/1`

Only two error types are eligible. From `Nous.Fallback.fallback_eligible?/1`:

```elixir
def fallback_eligible?(%Errors.ProviderError{}), do: true
def fallback_eligible?(%Errors.ModelError{}), do: true
def fallback_eligible?(_), do: false
```

| Error | Eligible? | Why |
|-------|-----------|-----|
| `Nous.Errors.ProviderError` | yes | API call failed (rate limit, 5xx, auth, timeout). A different provider may succeed. |
| `Nous.Errors.ModelError` | yes | Model-level failure from the provider. |
| `Nous.Errors.ValidationError` | no | Structured output failed validation — a different model won't fix bad schema output. |
| `Nous.Errors.MaxIterationsExceeded` | no | The agent loop limit was hit. |
| `Nous.Errors.ExecutionCancelled` | no | Run was explicitly cancelled. |
| `Nous.Errors.ToolError` / `ToolTimeout` | no | A tool failed — not a model problem. |
| `Nous.Errors.UsageLimitExceeded` | no | Budget exhausted; retrying spends more. |
| `Nous.Errors.ConfigurationError` | no | Misconfiguration; deterministic. |

The guiding principle: fallback covers **transport/provider-layer** failures, not
**application-layer** outcomes. If a fresh model wouldn't change the result,
Nous doesn't waste a call on it.

## Telemetry

Two distinct events let you observe failover, and they mean different things.

### `[:nous, :fallback, :activated]`

Emitted by `Fallback.with_fallback/3` **each time it steps from one model to the
next** because of an eligible error. The measurement is `%{system_time: ...}` and
the metadata is:

```elixir
%{
  failed_provider: :openai,
  failed_model: "gpt-4o",
  next_provider: :anthropic,
  next_model: "claude-sonnet-4-5-20250929",
  reason: %Nous.Errors.ProviderError{...}
}
```

This is the low-level signal: one event per *hop* in the chain. (The event prefix
is configurable via the `:telemetry_prefix` option to `with_fallback/3`, which
defaults to `[:nous, :fallback]`.)

### `[:nous, :agent, :fallback, :used]`

Emitted once by the agent runner when a run *actually completed on a non-primary
model*. This is the "sticky-fallback" signal: once an agent iteration promotes to
a fallback model, subsequent iterations of the same run reuse that model rather
than retrying the known-bad primary every loop. Metadata:

```elixir
%{
  agent_name: "agent_x1y2",
  original_provider: :openai,
  original_model: "gpt-4o",
  active_provider: :anthropic,
  active_model: "claude-sonnet-4-5-20250929"
}
```

The runner deliberately does **not** mutate `agent.model` when it falls back —
doing so would make the run's start/stop telemetry tag with different providers
and silently drift your metrics apart. Instead the active model is tracked in run
context and surfaced both here and on the run result (`fallback_used`).

Use `[:nous, :fallback, :activated]` to count how often a provider is flaking,
and `[:nous, :agent, :fallback, :used]` to count how many user-facing runs were
served by a backup.

```elixir
:telemetry.attach_many(
  "nous-fallback-logger",
  [
    [:nous, :fallback, :activated],
    [:nous, :agent, :fallback, :used]
  ],
  fn event, _measurements, metadata, _config ->
    IO.inspect({event, metadata}, label: "fallback")
  end,
  nil
)
```

## Worked Example

A production-grade agent that prefers OpenAI, falls back to Anthropic, with a fast
local model as a last resort:

```elixir
agent =
  Nous.new("openai:gpt-4o",
    instructions: "Answer concisely and cite sources when possible.",
    fallback: [
      "anthropic:claude-sonnet-4-5-20250929",
      "lmstudio:qwen3"
    ]
  )

case Nous.run(agent, "What changed in Elixir 1.18?") do
  {:ok, result} ->
    IO.puts(result.output)
    if result.fallback_used, do: IO.puts("(served by a fallback model)")

  {:error, %Nous.Errors.ProviderError{} = err} ->
    # Every model in the chain failed at the provider layer.
    IO.puts("All providers unavailable: #{Exception.message(err)}")

  {:error, reason} ->
    # A non-eligible error short-circuited the chain (e.g. validation).
    IO.inspect(reason, label: "non-fallback error")
end
```

Streaming honors the same chain — `Nous.run_stream/3` initializes the stream
through the fallback path, so a provider that fails to *start* the stream triggers
failover before any chunk is emitted:

```elixir
{:ok, stream} = Nous.run_stream(agent, "Write a haiku about BEAM.")
stream |> Stream.each(&IO.inspect/1) |> Stream.run()
```

## Gotchas

- **Tool errors never fall over.** If a tool raises, times out, or returns
  `{:error, _}`, that is a `ToolError`/`ToolTimeout` — the run fails on the
  current model. A different LLM can't fix your tool.
- **Validation failures never fall over.** A `ValidationError` from structured
  output is returned immediately. Re-running a different model is unlikely to
  produce schema-valid output and would just burn tokens.
- **Iteration/usage limits never fall over.** `MaxIterationsExceeded` and
  `UsageLimitExceeded` are terminal by design.
- **Cancellation is honored immediately.** `ExecutionCancelled` short-circuits.
- **Config errors are terminal.** A `ConfigurationError` (e.g. a missing API key
  surfaced as config rather than a provider call) does not trigger fallback.
- **An empty chain is a config error.** Passing an empty `:fallback` is fine (you
  just get the primary), but an internally empty chain yields a
  `ConfigurationError`.
- **Sticky within a run.** Once a run falls back, it stays on the fallback model
  for the remaining iterations of *that* run; it does not re-probe the primary
  mid-run.

## Comparison: Manual Failover

Before built-in chains, you would hand-roll failover, as in
`examples/advanced/error_handling.exs`. That example loops over a list of provider
configs and calls `Nous.run/2` on each in turn:

```elixir
defp attempt_providers(message, [%{model: model} = config | rest], attempt) do
  agent = Nous.new(model, build_opts(config))

  case Nous.run(agent, message) do
    {:ok, result} -> {:ok, result, model}
    {:error, _reason} when rest != [] -> attempt_providers(message, rest, attempt + 1)
    {:error, _reason} -> {:error, :all_providers_failed}
  end
end
```

The manual approach is useful when you need bespoke per-provider options (distinct
API keys, instructions, base URLs) or want to retry on errors that the built-in
path treats as terminal. But it has tradeoffs the `:fallback` option solves:

| Aspect | Manual loop | `:fallback` chain |
|--------|-------------|-------------------|
| Error filtering | Falls over on **any** `{:error, _}`, including tool/validation errors | Only `ProviderError`/`ModelError` |
| Telemetry | You instrument it yourself | Built-in `activated` + `used` events |
| Sticky within a run | No — re-runs the whole agent | Yes — promoted model reused across iterations |
| Streaming | Manual | Stream init goes through the chain |

Prefer `:fallback` for resilience against provider outages; reach for a manual
loop only when you need failover semantics the built-in path intentionally
excludes.

## Related Guides

- [Best Practices](best_practices.md) — production patterns including resilience.
- [Custom Providers](custom_providers.md) — wiring up the providers you might
  chain together.
- [Troubleshooting](troubleshooting.md) — diagnosing provider and model errors.
