# HTTP Backend Benchmark

Comparison of `Nous.HTTP.Backend.Req` (default) and
`Nous.HTTP.Backend.Hackney` for non-streaming POST requests.

Two benchmarks are included:

1. **Localhost** (`bench/http_backend.exs`) — in-process `Plug.Cowboy`
   server. Measures pure client overhead (pool contention, encode/decode,
   scheduler interaction). No network in the path.
2. **Real endpoint** (`bench/http_backend_real.exs`) — OpenRouter free
   models. Measures what users actually feel: TLS handshake, real
   network RTT, real LLM response variance.

Both confirm the same conclusion: **Req is the right default**, with the
gap shrinking but never vanishing as response time grows.

## Reproducing

```sh
# Localhost — pure client overhead. MIX_ENV=test because the in-process
# Plug.Cowboy server reaches the build through Bypass, which is `only: :test`
# (keeping cowboy/ranch off the :dev code path).
MIX_ENV=test mix run bench/http_backend.exs

# Real endpoint — needs creds in env (no secrets land in source).
OPENROUTER_API_KEY=sk-or-... \
  OPENROUTER_MODEL=nvidia/nemotron-3-nano-30b-a3b:free \
  OPENROUTER_MAX_TOKENS=8 \
    mix run bench/http_backend_real.exs
```

## Localhost results

Hardware: Apple M1 Max, 10 cores, 64 GB RAM
Runtime: Elixir 1.20-rc.4 / Erlang 28.2 (JIT enabled)
Benchee config: 2 s warmup, 10 s measurement, sequential (`parallel: 1`)

| Scenario                | Backend | Iterations/sec | Median   | p99      |
| ----------------------- | ------- | -------------- | -------- | -------- |
| `small_post`  (1 KB)    | Req     | **9,604**      | 0.102 ms | 0.160 ms |
| `small_post`  (1 KB)    | Hackney | 7,779          | 0.125 ms | 0.174 ms |
| `parallel_50` (1 KB ×50)| Req     | **719**        | 1.35 ms  | 1.64 ms  |
| `parallel_50` (1 KB ×50)| Hackney | 111            | 11.56 ms | 13.03 ms |
| `large_body` (256 KB ×10)| Req    | 351            | 2.84 ms  | 3.14 ms  |
| `large_body` (256 KB ×10)| Hackney| **416**        | 2.41 ms  | 2.62 ms  |

### Observations

1. **Sequential small requests:** Req wins by ~24% on throughput. Both
   are well under a millisecond; the difference is unlikely to matter
   for an LLM workload where the network round-trip dominates by 2–3
   orders of magnitude.

2. **Parallel small requests (50-way):** Req wins decisively (~6.5×).
   Hackney's `:default` pool serializes connections to a single host
   under contention — for a real LLM endpoint this is mitigated by
   higher round-trip latency (the pool drains faster between requests),
   but on `localhost` the contention shows up sharply. Apps doing heavy
   parallel batching against one provider should stay on Req or
   pre-allocate a larger hackney pool via `:hackney_pool.start_pool/2`
   and pass `pool: :my_pool` per call.

3. **Large bodies (256 KB ×10):** Hackney wins by ~19%. Hackney's
   binary handling for large payloads is more efficient than Req's
   middleware stack pays for itself.

## Real-endpoint results (OpenRouter)

Two free models tested: a fast MoE (Nemotron 3 Nano 30B-A3B,
`max_tokens=8`, ~400ms responses) and a thinking model (Liquid LFM-2.5
1.2B,  `max_tokens=300`, ~1s responses with 100+ reasoning tokens
generated internally).

Sequential = 10 paced requests (4s gap). Parallel = 3 batches of 5
concurrent requests (15s gap between batches). Pacing keeps us under
typical free-tier 20/min rate caps.

### Nemotron 3 Nano 30B-A3B (fast, max_tokens=8)

| Scenario   | Backend | p50      | p95       | mean     |
| ---------- | ------- | -------- | --------- | -------- |
| Sequential | Req     | 416 ms   | 1549 ms   | 591 ms   |
| Sequential | Hackney | 415 ms   | 2549 ms   | 645 ms   |
| Parallel   | Req     | 454 ms   | 943 ms    | 543 ms   |
| Parallel   | Hackney | 504 ms   | 894 ms    | 648 ms   |

Within ~10% across the board. At this latency the localhost
"Req is 6.5×" finding completely vanishes.

### Liquid LFM-2.5 1.2B Thinking (slower, max_tokens=300)

| Scenario   | Backend | p50      | p95       | mean     |
| ---------- | ------- | -------- | --------- | -------- |
| Sequential | Req     | 831 ms   | 1004 ms   | 820 ms   |
| Sequential | Hackney | 793 ms   | 1826 ms   | 880 ms   |
| Parallel   | Req     | 1134 ms  | 1389 ms   | 1099 ms  |
| Parallel   | Hackney | **1987 ms** (1.75× slower) | 2490 ms  | 2043 ms  |

Once responses run longer than a few hundred ms, **the parallel gap
reappears**. Hackney's per-connection `gen_server` (`hackney_conn`) does
one mailbox hop per chunk read — long responses = more chunks = more
hops piling up. Mint (Req's underlying client) is process-less, so
chunk count is irrelevant.

Hackney also has consistently worse p95 tails on sequential — cold
connection setup is more expensive than Req's pooled-Mint path.

### When to switch from the default

Default is Req. Switch to Hackney if:

- You need HTTP/3 — hackney 4 auto-upgrades via Alt-Svc; Req/Finch
  doesn't yet.
- Your traffic is purely sequential (no parallel batching) and you want
  to consolidate on one HTTP family across streaming + non-streaming.
- Your provider serves large response *bodies* (long completions,
  embedding batches >100 vectors) — Hackney pulls ahead ~15–20% on the
  256KB-body localhost scenario.

Stay on Req if (most users):

- You batch parallel requests against one provider — gap can be
  1.5–2× slower on Hackney for ~1s+ responses.
- You use Req middleware (`Req.Steps`, custom step pipelines).
- You want the lowest p95 tails on cold connections.
- You want the most idiomatic Elixir HTTP API.

## When to switch streaming to Hackney

Streaming has defaulted to `Nous.HTTP.StreamBackend.Req` since 0.15.4,
matching the non-streaming default. Hackney is the opt-in alternative,
not the incumbent.

The non-streaming bench above is about **throughput**: how fast can you
round-trip a request/response. Streaming is about **backpressure**: can
the consumer pace the producer. Both backends bound the consumer, but
they bound it differently.

**Req (default) — bounded in-flight byte window.** Req's `:into`
callback runs in a supervised `Task` that forwards each chunk to the
consuming `Stream.resource` with `send/2`. Producer and consumer share
an `:atomics` counter of in-flight bytes: the producer adds
`byte_size(chunk)` before sending, the consumer subtracts it on receipt.
Above the **8 MB** high-water mark the producer parks in a `receive`
and resumes once the counter falls below the **1 MB** low-water mark.
The parked producer *is* Req's `:into` callback, so parking it stops
draining the socket — backpressure propagates all the way to the wire.
Resident memory per stream is bounded in bytes rather than in chunk
count. A consumer that stays stalled past `:backpressure_max_wait_ms`
(default 30s) aborts the request and the stream yields
`{:stream_error, %{reason: :backpressure_overflow, inflight_bytes: n}}`
rather than wedging forever.

**Hackney — strict pull.** `[{:async, :once}]` mode: the consumer calls
`:hackney.stream_next/1` to ask for ONE more chunk, hackney reads ONE
chunk off the socket and delivers it. There is no in-flight window
because the mailbox never holds more than one chunk — the producer
literally cannot run ahead, no matter how slow the consumer is. (Note
the tuple form. The legacy `[:async, :once]` two-atom form silently
puts hackney in push mode, because `proplists` resolves a bare `:async`
as `{:async, true}`, forfeiting the guarantee.)

Plain `Finch.stream/5` gives you neither: its callback is push-based
with no window at all, so a fast LLM (Groq at 500 tok/s) feeding a slow
consumer grows the mailbox unboundedly. That was the M-12 finding from
the 0.15.0 review and the reason streaming ran on hackney before
0.15.4; the Req backend's byte window is what closed the gap.

Switch streaming to Hackney if:

- Your consumer can block for an unbounded time per chunk (LiveView
  assigns + diff + push under fan-out, persistence-on-every-chunk, slow
  IO) and you want a hard one-chunk mailbox bound instead of an 8 MB
  window.
- You would rather see the stream slow down than see it fail with
  `:backpressure_overflow` after 30s of a stalled consumer.
- You are already on the Hackney non-streaming backend and want one
  HTTP family across both paths.

Stay on Req (most users):

- Chunks arrive at token rate (10–100/sec) and are parsed immediately,
  so the 8 MB window is never approached.
- One HTTP stack across streaming and non-streaming, with hackney left
  out of the dependency tree entirely.

**Trade-off summary:**

| | Non-streaming | Streaming |
|---|---|---|
| **Default** | Req | Req |
| **Backpressure** | n/a — single response | 8 MB in-flight-byte window; the parked producer stops draining the socket |
| **Opt-in alternative** | Hackney — HTTP/3 via Alt-Svc, large bodies | Hackney — strict `stream_next/1` pull, one-chunk mailbox, no window |

### Opting into the Hackney stream backend

`:hackney` is declared `optional: true`, so it is not in your build
unless you ask for it. Add it to your app's deps:

```elixir
{:hackney, "~> 4.0"}
```

Then select the backend one of three ways, highest precedence first
(the resolution chain lives in `Nous.Providers.HTTP.stream/4`):

```elixir
# 1. Per-call opt
Nous.Providers.HTTP.stream(url, body, headers,
  stream_backend: Nous.HTTP.StreamBackend.Hackney)
```

```bash
# 2. Environment variable — also accepts "req" or a fully-qualified
#    custom module name such as "MyApp.MyStreamBackend"
export NOUS_HTTP_STREAM_BACKEND=hackney
```

```elixir
# 3. App config
config :nous, :http_stream_backend, Nous.HTTP.StreamBackend.Hackney
```

With none of the three set, the default is
`Nous.HTTP.StreamBackend.Req`. If hackney is selected but the
dependency is missing, Nous logs a warning and falls back to the app
config / default instead of crashing on the first request.

## Configuration (non-streaming)

See `Nous.Providers.HTTP.post/4` for the resolution order. Quick recap:

- Per-call: `HTTP.post(url, body, headers, backend: Nous.HTTP.Backend.Hackney)`
- Env: `NOUS_HTTP_BACKEND=hackney`
- App config: `config :nous, :http_backend, Nous.HTTP.Backend.Hackney`

The env var also accepts `req`, `hackney`, or any fully-qualified
custom backend module (e.g. `MyApp.MyHTTPBackend`). Custom modules are
resolved via `String.to_existing_atom/1` with rescue, so unknown values
fall back to the app config / default rather than crash.

These knobs cover the **non-streaming** path only; the streaming path
has its own chain, documented in
[Opting into the Hackney stream backend](#opting-into-the-hackney-stream-backend).
