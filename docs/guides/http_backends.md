# HTTP Backends (Req vs Hackney)

[Back to README](../../README.md#supported-providers)

Both the non-streaming and streaming HTTP paths go through pluggable
backends. Defaults are `Nous.HTTP.Backend.Req` and
`Nous.HTTP.StreamBackend.Req` (both on Req + Finch).
`Nous.HTTP.Backend.Hackney` and `Nous.HTTP.StreamBackend.Hackney` are
shipped as alternatives.

For headline numbers and full benchmark methodology, see the
[HTTP backend benchmark report](../benchmarks/http_backend.md).

## Non-streaming (`Nous.HTTP.Backend`)

Pick per-call, per-environment, or per-app:

```elixir
# Per-call
HTTP.post(url, body, headers, backend: Nous.HTTP.Backend.Hackney)

# Env (highest precedence after per-call):
# NOUS_HTTP_BACKEND=hackney   # also accepts "req" or a fully-qualified
#                             # custom module name like "MyApp.MyBackend"

# App config
config :nous, :http_backend, Nous.HTTP.Backend.Hackney
```

## Streaming (`Nous.HTTP.StreamBackend`)

Same resolution chain, separate config knob:

```elixir
# Per-call
HTTP.stream(url, body, headers,
  stream_backend: Nous.HTTP.StreamBackend.Hackney)

# Env
# NOUS_HTTP_STREAM_BACKEND=hackney

# App config
config :nous, :http_stream_backend, Nous.HTTP.StreamBackend.Hackney
```

When to pick which streaming backend:

| Backend | Pick it when |
|---------|--------------|
| `Nous.HTTP.StreamBackend.Req` *(default)* | One HTTP stack across streaming + non-streaming. Right default for almost every app. Backpressure is bounded by parsing speed, not strict pull pacing — fine for typical LLM workloads where token rate is the bottleneck. |
| `Nous.HTTP.StreamBackend.Hackney` | Strict pull-based backpressure via `[{:async, :once}]`. Pick this when downstream consumers can block per chunk (LiveView fan-out under load, persistence-on-every-chunk, slow IO). |

Both emit identical normalized event streams (parsed JSON maps,
`{:stream_done, _}`, `{:stream_error, _}`); switching backends needs no
other code changes.

## Hackney pool

Tune the shared hackney `:default` pool from app config (used by both
the Hackney non-streaming and Hackney streaming backends):

```elixir
config :nous, :hackney_pool,
  max_connections: 200,
  timeout: 1_500   # idle keepalive ms (hackney 4 caps at 2_000)
```

See [the HTTP backend benchmark report](../benchmarks/http_backend.md)
for localhost + real-endpoint benchmark numbers and guidance on when
to switch backends. Headline: stick with the Req defaults unless you
have a specific reason (strict backpressure, HTTP/3 upgrade, single-HTTP-stack consolidation).
