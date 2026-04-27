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
# Localhost — pure client overhead.
mix run bench/http_backend.exs

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

## Why streaming stays on Hackney regardless

The non-streaming bench is about **throughput**: how fast can you
round-trip a request/response. Streaming is about **backpressure**:
can the consumer pace the producer.

Hackney's `:async, :once` mode is the only Elixir HTTP API that gives
true pull-based streaming. The consumer calls `:hackney.stream_next/1`
to ask for ONE more chunk, the producer reads ONE chunk off the socket
and delivers it — the consumer literally cannot fall behind. A slow
LiveView assigns + diff + push pipeline can't OOM under a fast Groq
endpoint, no matter how big the disparity.

`Finch.stream/5`'s callback is push-based: the callback fires for
every chunk that arrives, regardless of whether the consumer is keeping
up. A fast LLM (Groq at 500 tok/s) feeding a slow consumer grows the
consumer's mailbox unboundedly until the BEAM scheduler starves or the
10 MiB SSE buffer cap trips. This was the M-12 finding from the 0.15.0
review and the reason streaming moved to hackney in the first place.

The same per-connection `gen_server` that hurts hackney's parallel
non-streaming throughput is the **feature** that makes streaming safe —
that conn process can throttle. And the throughput cost doesn't bite
in streaming because chunks arrive at token-rate (10–100/sec), so the
mailbox-hop overhead per chunk has plenty of breathing room.

**Trade-off summary:**

| | Non-streaming | Streaming |
|---|---|---|
| **Default** | Req | Hackney |
| **Why** | Lower latency under parallel load, simpler API | Pull-based backpressure (no consumer OOM) |
| **Mint/Finch alternative?** | — (default) | Push-based only — no equivalent today |

If a future Mint version adds pull-based streaming, we'd revisit the
streaming choice. Until then, Hackney for streaming is structural,
not a preference.

## Configuration

See `Nous.Providers.HTTP.post/4` for the resolution order. Quick recap:

- Per-call: `HTTP.post(url, body, headers, backend: Nous.HTTP.Backend.Hackney)`
- Env: `NOUS_HTTP_BACKEND=hackney`
- App config: `config :nous, :http_backend, Nous.HTTP.Backend.Hackney`

The env var also accepts `req`, `hackney`, or any fully-qualified
custom backend module (e.g. `MyApp.MyHTTPBackend`). Custom modules are
resolved via `String.to_existing_atom/1` with rescue, so unknown values
fall back to the app config / default rather than crash.
