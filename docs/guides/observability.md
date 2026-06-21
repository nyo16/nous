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

> The default handler attaches the **core** events only. Fallback, hook, skill,
> and workflow events have their own handlers or are meant for custom
> instrumentation — attach to them explicitly (see below).

## Event Catalog

All durations are emitted in `:native` time units. Convert with
`System.convert_time_unit(duration, :native, :millisecond)`. The canonical
source of truth is the moduledoc of `Nous.Telemetry` (and
`Nous.Workflow.Telemetry` for workflow payloads).

### Agent Events

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :agent, :run, :start]` | `system_time`, `monotonic_time` | `agent_name`, `model_provider`, `model_name`, `tool_count`, `has_tools` |
| `[:nous, :agent, :run, :stop]` | `duration`, `total_tokens`, `input_tokens`, `output_tokens`, `tool_calls`, `requests`, `iterations` | `agent_name`, `model_provider`, `model_name` |
| `[:nous, :agent, :run, :exception]` | `duration` | `agent_name`, `model_provider`, `kind`, `reason`, `stacktrace` |
| `[:nous, :agent, :iteration, :start]` | `system_time` | `agent_name`, `iteration`, `max_iterations` |
| `[:nous, :agent, :iteration, :stop]` | `duration` | `agent_name`, `iteration`, `tool_calls`, `needs_response` |

### Provider Events

These live under the `[:nous, :provider, ...]` namespace (there is **no**
`[:nous, :model, ...]` event namespace — the PromEx metric *names* use `model`,
but the underlying events are always `provider`).

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
| `[:nous, :agent, :fallback, :used]` | `system_time` | `agent_name`, `original_provider`, `original_model`, `active_provider`, `active_model` |
| `[:nous, :fallback, :activated]` | call-site dependent | active model + activation reason |

### Hook & Skill Events

| Event | Measurement | Metadata |
|-------|-------------|----------|
| `[:nous, :hook, :execute, :start]` | `system_time` | `event`, `hook_name`, `hook_type` |
| `[:nous, :hook, :execute, :stop]` | `duration` | `event`, `hook_name`, `hook_type`, `result?` |
| `[:nous, :hook, :denied]` | — | `event`, `hook_name`, `hook_type`, `reason?` |
| `[:nous, :skill, :activate]` | — | `skill_name`, `agent_name` |
| `[:nous, :skill, :deactivate]` | — | `skill_name`, `agent_name` |

### Workflow Events

Full payloads are documented in `Nous.Workflow.Telemetry`.

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
| `[:nous, :rate_limiter, :unavailable]` | `count` | rate-limiter context |
| `[:nous, :input_guard, :strategy_dropped]` | `count` | input-guard strategy context |

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
  an exceptions counter. Tagged by `tool_name`, `success`/`will_retry`.

> **Naming caveat:** the metric *group* and metric *names* use the word `model`
> (e.g. `nous_model_request_duration`), but they are driven by the
> `[:nous, :provider, ...]` **events**. The two are intentionally different — do
> not try to attach to `[:nous, :model, ...]`; no such event exists.

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
