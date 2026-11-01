# 📊 Observability & Telemetry

Nous instruments every layer of agent execution with [`:telemetry`](https://hexdocs.pm/telemetry/)
events. You get structured visibility into agent runs, provider API calls, tool
executions, the fallback chain, hooks, skills, and workflows — without changing a
line of your agent code.

This guide covers attaching the built-in handler, the full event catalog (every
name verified against source), writing custom handlers, and exporting Prometheus
metrics through the bundled `Nous.PromEx.Plugin`.

## Quick Reference

- **Just want logs in dev?** → [Default Handler](#default-handler)
- **Need to wire into your own metrics?** → [Custom Handlers](#custom-handlers)
- **Exporting to Prometheus/Grafana?** → [Prometheus via PromEx](#prometheus-via-promex)
- **What events fire and when?** → [Event Catalog](#event-catalog)
- **Tying events to one run, request or sub-agent?** → [Correlation ids](#correlation-ids)

## Default Handler

For local development and debugging, Nous ships a logging handler that attaches
to the core agent, provider, tool, context, and callback events:

```elixir
Nous.Telemetry.attach_default_handler()
```

It logs at sensible levels:

- Agent runs → `info`
- Provider requests and stream connections → `debug`
- Tool executions, iterations, context updates, callbacks → `debug`
- Tool retries / timeouts → `warning`
- Agent, provider, and stream exceptions → `error`

Provider error reasons are summarized (status + a capped body snippet, headers
dropped) so a failing upstream cannot flood your logs or leak response context.

Detach it when you're done — for example in tests:

```elixir
Nous.Telemetry.detach_default_handler()
```

> The default handler attaches the **core** events only. The model and
> tool-call spans, fallback, guard, hook, skill, compaction and workflow
> events have their own handlers or are meant for custom instrumentation —
> attach to them explicitly (see below).

## Correlation ids

Every Nous event carries four correlation keys in its metadata. They are
**always present** — `nil` outside an agent run — so a handler can pattern
match on them uniformly:

| Key | Value | Meaning |
|-----|-------|---------|
| `trace_id` | 32 lowercase hex chars | One trace: a root agent run and every run nested in it (a `Nous.Plugins.SubAgent` delegation, an agent a tool starts) |
| `agent_run_id` | 16 lowercase hex chars | One agent run. Minted by every entry point (`Nous.run/3`, `run_with_context/3`, `run_stream/3`, each `Nous.AgentServer` turn); concurrent runs never share one |
| `parent_agent_run_id` | 16 hex chars or `nil` | The run this one is nested in; `nil` for a root run |
| `tool_call_id` | provider tool-call id or `nil` | The tool call being executed: set on `[:nous, :agent, :tool_call, ...]`, on hook events about a tool call, and on everything a tool body emits |

`[:nous, :agent, :run, :start]` also carries `parent_tool_call_id` (the tool
call that started a nested run), `role` (`:agent` for your runs), `profile_id`
(the `Nous.Profile` the run's agent applies, `nil` without one; also on
`run.stop` and `run.exception`) and, for sub-agent runs, `sub_agent_template` and
`sub_agent_index`. With `agent_run_id` / `parent_agent_run_id` /
`parent_tool_call_id` a flat stream of events rebuilds into the run tree:
which tool call of which run spawned which sub-agent.

The ids follow the work into the processes Nous starts — parallel tool calls,
timed tool bodies, hook and guard tasks, sub-agents, AgentServer turn tasks,
and a `run_stream/3` stream enumerated in another process. A `Task` you start
inside a tool inherits them through `$callers`; a bare `spawn/1` or a
GenServer does not.

> **Content keys.** `messages`, `response` (model span), `arguments`, `result`
> (tool-call span), guard `details`/`reason`, `errors`, and every raw
> `reason`/`stacktrace`/`error` carry user and model data. They are safe for
> in-process handlers, but **a handler that forwards events off-box (Sentry,
> Honeycomb, log shippers) MUST scrub those keys first.** Nous does not
> redact, to keep failures debuggable for trusted handlers. The ids
> themselves are random and carry no data — but do not use them as metric
> tags (unbounded cardinality).

### Request-id correlation recipe

`:telemetry` handlers run in the process that emits the event, and
`Nous.run/3` called from a Phoenix request runs in the request process. So a
handler on the root run's start can read the request's `Logger` metadata and
record which trace belongs to which request — no Nous option needed:

```elixir
defmodule MyApp.NousRequestCorrelation do
  def attach do
    :telemetry.attach(
      "nous-request-correlation",
      [:nous, :agent, :run, :start],
      &__MODULE__.handle/4,
      nil
    )
  end

  # A root run (no parent) started from a request process.
  def handle(_event, _measurements, %{parent_agent_run_id: nil, trace_id: trace_id}, _config) do
    case Logger.metadata()[:request_id] do
      nil -> :ok
      request_id -> MyApp.TraceIndex.put(trace_id, request_id)
    end
  end

  def handle(_event, _measurements, _metadata, _config), do: :ok
end
```

Every later event of that run and its sub-agents carries the same `trace_id`.
This works where the run executes in the request process; it does not for an
`Nous.AgentServer` turn or a `run_stream/3` stream consumed elsewhere, since
`Logger` metadata is per process.

## Event Catalog

All durations are emitted in `:native` time units. Convert with
`System.convert_time_unit(duration, :native, :millisecond)`. The canonical
source of truth is the moduledoc of `Nous.Telemetry` (and
`Nous.Workflow.Telemetry` for workflow payloads). Every event also carries
the [correlation keys](#correlation-ids); the tables list the rest.

### Agent Events

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :agent, :run, :start]` | `system_time`, `monotonic_time` | `agent_name`, `model_provider`, `model_name`, `tool_count`, `has_tools`, `parent_tool_call_id`, `role`, `profile_id`, `sub_agent_template`, `sub_agent_index` |
| `[:nous, :agent, :run, :stop]` | `duration`, `total_tokens`, `input_tokens`, `output_tokens`, `tool_calls`, `requests`, `iterations` | `agent_name`, `model_provider`, `model_name` (configured), `active_model_provider`, `active_model_name` (last used), `fallback_used`, `profile_id` |
| `[:nous, :agent, :run, :exception]` | `duration` | `agent_name`, `model_provider`, `model_name`, `kind`, `reason`, `stacktrace` (real when the run raised, `[]` when it returned `{:error, _}`), `profile_id` |
| `[:nous, :agent, :iteration, :start]` | `system_time` | `agent_name`, `iteration`, `max_iterations` |
| `[:nous, :agent, :iteration, :stop]` | `duration` | `agent_name`, `iteration`, `tool_calls`, `needs_response` |
| `[:nous, :agent, :model, :start]` | `system_time`, `monotonic_time` | `agent_name`, `iteration`, `model_provider`, `model_name` (requested), `stream`, `tool_names` (offered), `blocked_tool_names` (removed by the permission policy), `messages` |
| `[:nous, :agent, :model, :stop]` | `duration`, `input_tokens`, `output_tokens`, `total_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `tool_calls`; `time_to_first_token` (streamed requests) | `agent_name`, `iteration`, `model_provider`, `model_name`, `active_model_provider`, `active_model_name`, `fallback_used`, `finish_reason`, `requested_tool_calls` (`[%{tool_call_id, tool_name}]`), `response` |
| `[:nous, :agent, :model, :exception]` | `duration` | `agent_name`, `iteration`, `model_provider`, `model_name`, `kind`, `reason` |
| `[:nous, :agent, :tool_call, :start]` | `system_time`, `monotonic_time` | `agent_name`, `tool_call_id`, `tool_name`, `arguments`, `iteration` |
| `[:nous, :agent, :tool_call, :stop]` | `duration` | `agent_name`, `tool_call_id`, `tool_name`, `outcome`, `approval`, `result`, `result_modified`, `error`; post-edit `arguments` when `approval: :edited` |
| `[:nous, :agent, :structured_output, :retry]` | `retries_left` | `agent_name`, `attempt`, `errors` |

Run events fire from all three runner entry points. `run_stream/3`'s `:stop`
fires when the stream yields `{:complete, _}`; a consumer that stops early
leaves a start without a stop. `:stop` also fires after a successful
structured-output retry.

The tool-call span covers one requested call from before its hooks to its
final result message. `outcome` is one of `:executed`, `:invalid_arguments`,
`:collapsed` (Code Mode), `:hook_denied`, `:hook_stage_failed`,
`:approval_rejected`, `:not_found`, `:timeout`, `:crashed`; `approval` one of
`:not_required`, `:approved`, `:edited`, `:rejected`. A tool that returns
`{:error, _}` is `:executed` with the term in `error`; one that raises is
`:crashed`.

### Provider Events

These live under the `[:nous, :provider, ...]` namespace and carry no run
context beyond the correlation keys; the runner-level view of a model call is
the `[:nous, :agent, :model, ...]` span above.

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :provider, :request, :start]` | `system_time`, `monotonic_time` | `provider`, `model_name`, `message_count` |
| `[:nous, :provider, :request, :stop]` | `duration`, `input_tokens`, `output_tokens`, `total_tokens` | `provider`, `model_name`, `has_tool_calls` |
| `[:nous, :provider, :request, :exception]` | `duration` | `provider`, `model_name`, `kind`, `reason` |

### Provider Streaming Events

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :provider, :stream, :start]` | `system_time`, `monotonic_time` | `provider`, `model_name`, `message_count` |
| `[:nous, :provider, :stream, :connected]` | `duration` | `provider`, `model_name` |
| `[:nous, :provider, :stream, :exception]` | `duration` | `provider`, `model_name`, `kind`, `reason` |

### Tool Events

Executor-level, one per attempt; inside a run they carry the call's
`tool_call_id`.

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :tool, :execute, :start]` | `system_time`, `monotonic_time` | `tool_name`, `tool_module`, `attempt`, `max_retries`, `has_timeout` |
| `[:nous, :tool, :execute, :stop]` | `duration` | `tool_name`, `attempt`, `success` |
| `[:nous, :tool, :execute, :exception]` | `duration` | `tool_name`, `attempt`, `will_retry`, `kind`, `reason`, `stacktrace` |
| `[:nous, :tool, :timeout]` | `timeout` | `tool_name` |

### Context & Callback Events

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :context, :update]` | `keys_updated` | `agent_name`, `keys` |
| `[:nous, :callback, :execute]` | `duration` | `callback_type`, `agent_name` |

### Fallback Events

Use these to alert on provider degradation. See the
[workflows](workflows.md) and best-practices guides for fallback configuration.

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :agent, :fallback, :used]` | `system_time` | `agent_name`, `iteration`, `original_provider`, `original_model` (the routed model when a router chose one), `active_provider`, `active_model` |
| `[:nous, :fallback, :activated]` | `system_time` | `failed_provider`, `failed_model`, `next_provider`, `next_model`, `reason` |

### Router Events

One event per `Nous.Router` consultation; see the
[Decision Models guide](decision_models.md#routing).

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :router, :route]` | `duration` | `agent_name`, `router`, `granularity`, `turn`, `iteration`, `cause`, `tier`, `probabilities`, `confidence`, `reason`, `model_provider`, `model_name` |

### Hook & Skill Events

`tool_call_id` on hook events is the `:pre_tool_use` / `:post_tool_use`
payload's `:tool_id`.

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :hook, :execute, :start]` | `system_time` | `event`, `hook_name`, `hook_type`, `tool_call_id` |
| `[:nous, :hook, :execute, :stop]` | `duration` | `event`, `hook_name`, `hook_type`, `tool_call_id`, `result?` |
| `[:nous, :hook, :denied]` | — | `event`, `hook_name`, `hook_type`, `tool_call_id`, `reason?` |
| `[:nous, :hook, :failed_closed]` | `system_time` | `event`, `hook_name`, `hook_type`, `tool_call_id`, `reason` |
| `[:nous, :hook, :decision]` | `duration`, `chunk_count` | `event`, `hook_name`, `tool_call_id`, `verdict`, `result`, `probabilities`, `backend`, `model`, `canary_failed`, `error` |
| `[:nous, :skill, :activate]` | — | `skill_name`, `group`, `activation_type` |
| `[:nous, :skill, :deactivate]` | — | `skill_name`, `group` |

### Guard Events

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :decision_guard, :verdict]` | `duration`, `chunk_count` | `surface`, `agent_name`, `tool_call_id`, `verdict`, `result`, `probabilities`, `canary_failed`, `error` |
| `[:nous, :decision_guard, :canary_failed]` | `count` | `surface` |
| `[:nous, :input_guard, :verdict]` | `duration`, `strategies`, `dropped` | `agent_name`, `severity`, `aggregation`, `fail_closed` (the verdict is a fail-closed result), `action` (`:block`, `:warn`, `:log`, `:callback`, `:custom`, `:none`) |
| `[:nous, :input_guard, :strategy_verdict]`, `[:nous, :decision_guard, :strategy_verdict]` | `duration` | `strategy`, `severity`, `reason`, `details`, `error` |
| `[:nous, :input_guard, :strategy_dropped]`, `[:nous, :decision_guard, :strategy_dropped]` | `count` | `aggregation`, `fail_closed` (the configured flag) |
| `[:nous, :loop_guard, :advisory]` | `chain_length` | `agent_name`, `threshold`, `tier`, `signatures` (tool names) |

On DecisionGuard hook surfaces each check emits both
`[:nous, :decision_guard, :verdict]` and a `[:nous, :hook, :decision]` with
hook name `"decision_guard:<surface>"`; count verdicts on one of the two.

### Compaction, Decision Model, Profile & Session Events

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :compaction, :start]` | `system_time`, `monotonic_time` | `agent_name`, `messages_before` |
| `[:nous, :compaction, :stop]` | `duration`, `bytes_before`, `bytes_after` | `agent_name`, `messages_before`, `messages_after`, `llm_called`, `summarized`, `provider`, `model`, `usage` |
| `[:nous, :compaction, :exception]` | `duration` | `agent_name`, `messages_before`, `messages_after`, `llm_called`, `kind`, `reason`, `stacktrace` |
| `[:nous, :decision_model, :decide, :start]` | `system_time`, `monotonic_time` | `backend`, `model`, `question_count` |
| `[:nous, :decision_model, :decide, :stop]` | `duration`, `input_tokens` | `backend`, `model`, `question_count` |
| `[:nous, :decision_model, :decide, :exception]` | `duration` | `backend`, `model`, `question_count`, `kind`, `reason`, `stacktrace?` |
| `[:nous, :profile, :switched]` | `system_time` | `agent_name`, `profile_id`, `previous_profile_id`, `action` (`:replaced` — the continued conversation's leading system message was replaced by a logged event; `:updated` — no system message in the transcript, only `ctx.system_prompt` changed) |
| `[:nous, :session, :invariant, :violation]` | `count` | violation details (`kind`, …), `agent_name`, `mode` |

### Workflow Events

Full payloads are documented in `Nous.Workflow.Telemetry`. The correlation
keys identify the enclosing agent run (if any), never the workflow execution.

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :workflow, :run, :start]` | `system_time`, `monotonic_time` | `workflow_id`, `workflow_name`, `node_count` |
| `[:nous, :workflow, :run, :stop]` | `duration` | `workflow_id`, `status`, `nodes_executed` |
| `[:nous, :workflow, :run, :exception]` | `duration` | `workflow_id`, `reason` |
| `[:nous, :workflow, :node, :start]` | `system_time`, `monotonic_time` | `workflow_id`, `node_id`, `node_type` |
| `[:nous, :workflow, :node, :stop]` | `duration` | `workflow_id`, `node_id`, `node_type`, `success` |
| `[:nous, :workflow, :node, :exception]` | `duration` | `workflow_id`, `node_id`, `node_type`, `reason` |

### Operational Events

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :rate_limiter, :unavailable]` | `count` | `agent_name` (renamed from `agent` in 0.20.0) |

> **Research observability:** the research pipeline (`Nous.Research`) does not
> emit its own telemetry namespace. Because it runs ordinary agents internally,
> you observe it through the `[:nous, :agent, ...]` and `[:nous, :provider, ...]`
> events above.

## Custom Handlers

Attach your own handler with `:telemetry.attach/4` (single event) or
`:telemetry.attach_many/4` (many events). The handler receives
`event_name, measurements, metadata, config`:

```elixir
:telemetry.attach(
  "my-nous-handler",
  [:nous, :agent, :run, :stop],
  fn _event, measurements, metadata, _config ->
    MyApp.Metrics.track_agent_run(
      metadata.agent_name,
      measurements.duration,
      measurements.total_tokens
    )
  end,
  nil
)
```

### Cost & token tracking

Token counts on `[:nous, :agent, :run, :stop]` make per-run cost tracking
trivial. Aggregate into an `Agent`, ETS table, or your metrics backend:

```elixir
defmodule MyApp.CostTracker do
  use Agent

  def start_link(_),
    do: Agent.start_link(fn -> %{total_tokens: 0, requests: 0} end, name: __MODULE__)

  def stats, do: Agent.get(__MODULE__, & &1)

  def attach do
    :telemetry.attach(
      "cost-tracker",
      [:nous, :agent, :run, :stop],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle([:nous, :agent, :run, :stop], measurements, _meta, _config) do
    Agent.update(__MODULE__, fn s ->
      %{s | total_tokens: s.total_tokens + measurements.total_tokens, requests: s.requests + 1}
    end)
  end
end
```

#### Prompt-cache tokens

The measurements above are enough to count tokens, but **not** enough to
price them once prompt caching is in play. Cached input is billed at a
different rate from fresh input, and the `[:nous, :agent, :run, :stop]`
measurement map carries only `total_tokens`, `input_tokens`,
`output_tokens`, `tool_calls`, `requests`, and `iterations` — no cache
counters. Those live on the `%Nous.Usage{}` struct itself (since 0.16.2):

| Field | Populated from | Meaning |
|-------|----------------|---------|
| `:cache_creation_input_tokens` | Anthropic `usage.cache_creation_input_tokens` | Prompt tokens **written** to the cache by this request. Billed at a premium over the base input rate. |
| `:cache_read_input_tokens` | Anthropic `usage.cache_read_input_tokens`, Gemini `usageMetadata.cachedContentTokenCount` | Prompt tokens **served** from the cache. Billed at a steep discount. |

Both default to `0`, and `Nous.Usage.add/2` sums them like every other
counter, so aggregating usage across runs keeps cache accounting intact.
Per model request, `[:nous, :agent, :model, :stop]` carries both counters as
measurements under the same names, so a telemetry handler can price each
request without the run result.

Two provider-shaped caveats decide the arithmetic:

- **Anthropic reports the cache counters *outside* `input_tokens`**, and
  Nous computes `total_tokens` as `input_tokens + output_tokens` for that
  provider. So on a cache hit `total_tokens` **under**-counts what you are
  billed for; the billed prompt total is
  `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`.
- **Gemini folds cached tokens *into* `promptTokenCount`**, so
  `cache_read_input_tokens` is a subset of `input_tokens`. Charging the
  full input rate on `input_tokens` **over**-counts; subtract the cached
  portion first.
- OpenAI-compatible providers go through `Nous.Messages.OpenAI.parse_usage/1`,
  which does not map `prompt_tokens_details.cached_tokens` — both fields
  stay `0` there, and OpenAI's cache discount is already folded into
  `prompt_tokens`.

That gives one corrected formula with disjoint buckets:

```text
cost = fresh_input_tokens          * input_rate
     + cache_creation_input_tokens * cache_write_rate
     + cache_read_input_tokens     * cache_read_rate
     + output_tokens               * output_rate

where fresh_input_tokens =
  input_tokens                                 # Anthropic (disjoint)
  input_tokens - cache_read_input_tokens       # Gemini (nested)
```

Cache rates are provider pricing, not derived constants — at time of
writing Anthropic charges 1.25x the base input rate for a 5-minute cache
write and 0.1x for a read, and Gemini prices cached input well below fresh
input while billing cache *storage* per hour on the `CachedContent` object
rather than per request. Look up the current numbers; the shape is stable.

```elixir
defmodule MyApp.Cost do
  @moduledoc "Cache-aware cost math over %Nous.Usage{}."

  # USD per 1M tokens. Replace with current provider pricing.
  @rates %{
    anthropic: %{input: 3.00, cache_write: 3.75, cache_read: 0.30, output: 15.00},
    gemini: %{input: 1.25, cache_write: 0.00, cache_read: 0.3125, output: 10.00}
  }

  @doc "Cost in USD for a single `%Nous.Usage{}`."
  def usd(%Nous.Usage{} = usage, provider) do
    rates = Map.fetch!(@rates, provider)
    {fresh_input, cache_write, cache_read} = prompt_buckets(usage, provider)

    millions =
      fresh_input * rates.input +
        cache_write * rates.cache_write +
        cache_read * rates.cache_read +
        usage.output_tokens * rates.output

    millions / 1_000_000
  end

  @doc "Fraction of prompt tokens served from cache, 0.0..1.0."
  def cache_hit_ratio(%Nous.Usage{} = usage, provider) do
    {fresh_input, cache_write, cache_read} = prompt_buckets(usage, provider)

    case fresh_input + cache_write + cache_read do
      0 -> 0.0
      prompt_tokens -> cache_read / prompt_tokens
    end
  end

  # Normalize every provider to three disjoint prompt buckets.
  defp prompt_buckets(usage, :gemini) do
    # Gemini's promptTokenCount already includes the cached tokens.
    fresh = max(usage.input_tokens - usage.cache_read_input_tokens, 0)
    {fresh, usage.cache_creation_input_tokens, usage.cache_read_input_tokens}
  end

  defp prompt_buckets(usage, _anthropic_shaped) do
    # Anthropic reports the cache counters outside input_tokens.
    {usage.input_tokens, usage.cache_creation_input_tokens,
     usage.cache_read_input_tokens}
  end
end
```

Feed it the usage struct off the run result rather than the telemetry
measurements:

```elixir
{:ok, result} = Nous.run(agent, "Summarize the attached contract")

MyApp.Cost.usd(result.usage, :anthropic)
MyApp.Cost.cache_hit_ratio(result.usage, :anthropic)
```

> Keep telemetry handlers fast and crash-free. A raising handler is detached by
> `:telemetry` after one failure, silently dropping your metrics. Do heavy work
> (DB writes, HTTP calls) off the calling process — hand off to a `Task` or a
> queue rather than blocking the agent's hot path.

For a complete, runnable walkthrough — custom handler, the default handler, and a
live cost tracker — see [`examples/advanced/telemetry.exs`](../../examples/advanced/telemetry.exs).

## telemetry_metrics

If you already use `:telemetry_metrics` (e.g. with Phoenix LiveDashboard or a
reporter), define metric specs over the event names above:

```elixir
import Telemetry.Metrics

def metrics do
  [
    counter("nous.agent.run.start.count"),
    distribution("nous.agent.run.stop.duration", unit: {:native, :millisecond}),
    sum("nous.agent.run.stop.total_tokens"),
    counter("nous.tool.execute.stop.count", tags: [:tool_name]),
    counter("nous.tool.timeout.count", tags: [:tool_name])
  ]
end
```

This plugs into `telemetry_metrics_prometheus`, `telemetry_metrics_statsd`, or
Phoenix LiveDashboard. For a turnkey Prometheus setup, prefer the PromEx plugin
below.

## Prometheus via PromEx

Nous bundles `Nous.PromEx.Plugin`, a [PromEx](https://hexdocs.pm/prom_ex/)
plugin that turns the telemetry events into Prometheus metrics. The plugin
module is only compiled when PromEx is present, so it is an opt-in dependency.

### Setup

Add PromEx (and its `:plug` dependency) to your `mix.exs`:

```elixir
{:prom_ex, "~> 1.11"},
{:plug, "~> 1.18"}  # required by PromEx
```

Register the plugin in your PromEx module:

```elixir
defmodule MyApp.PromEx do
  use PromEx, otp_app: :my_app

  @impl true
  def plugins do
    [
      # ... other plugins
      {Nous.PromEx.Plugin, []}
    ]
  end
end
```

### Options

`Nous.PromEx.Plugin` implements `event_metrics/1` and accepts:

- `:otp_app` — OTP app name (defaults to the PromEx module's setting)
- `:metric_prefix` — custom metric prefix (defaults to `[otp_app, :nous]`, or
  `[:nous]` when no `otp_app`)
- `:duration_unit` — `:second`, `:millisecond` (default), `:microsecond`, or
  `:nanosecond`; also selects the histogram bucket scheme

### Exposed metric groups

The plugin builds three `PromEx.MetricTypes.Event` groups:

- `:nous_agent_event_metrics` — from `[:nous, :agent, :run, :stop]` and
  `[:nous, :agent, :run, :exception]`: run duration, total/input/output tokens,
  tool-call count, iteration count, and an exceptions counter. Tagged by
  `agent_name`, `model_provider`, `model_name`.
- `:nous_model_event_metrics` — from the `[:nous, :provider, :request, ...]` and
  `[:nous, :provider, :stream, ...]` events: request duration, token
  distributions, request exceptions, stream-connect duration, and stream
  exceptions. Tagged by `provider`, `model_name` (and `has_tool_calls` for
  duration).
- `:nous_tool_event_metrics` — from `[:nous, :tool, :execute, :stop]` and
  `[:nous, :tool, :execute, :exception]`: execution duration, attempt count, and
  an exceptions counter, tagged by `tool_name`, `success`/`will_retry`; plus
  `nous_tool_call_total` from `[:nous, :agent, :tool_call, :stop]`, tagged by
  `tool_name` and `outcome`.

> **Naming caveat:** the metric *group* and metric *names* use the word `model`
> (e.g. `nous_model_request_duration`), but they are driven by the
> `[:nous, :provider, ...]` **events**, not the runner-level
> `[:nous, :agent, :model, ...]` span. There is no `[:nous, :model, ...]` event.

The plugin deliberately tags no correlation id (`trace_id`, `agent_run_id`,
`tool_call_id`): each is unique per run or call, and as a Prometheus label it
would create one time series per run.

Once exposed via PromEx's `/metrics` endpoint, scrape it with Prometheus and
build Grafana dashboards over agent latency, token spend, and tool failure
rates.

## Related Guides

- [Production Best Practices](best_practices.md) — monitoring, reliability, and
  deployment patterns
- [Workflows](workflows.md) — workflow/node telemetry in context
- [Hooks](hooks.md) — hook lifecycle and the events they emit
- [Skills](skills.md) — skill activation/deactivation events
- [Troubleshooting](troubleshooting.md) — diagnosing failures surfaced by
  exception events
