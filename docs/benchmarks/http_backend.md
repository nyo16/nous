# HTTP Backend Benchmark

Comparison of `Nous.HTTP.Backend.Req` and `Nous.HTTP.Backend.Hackney` for
non-streaming POST requests. The benchmark uses an in-process
`Plug.Cowboy` server on `localhost`, so the numbers reflect HTTP-client
overhead (encode/decode, connection pooling, scheduler interaction) and
not real-world LLM latency.

This is **descriptive, not prescriptive** — neither backend is the
"winner." Pick based on what you value:

- **Req** — better for apps that want middleware (`Req.Steps`), built-in
  retries, content-type negotiation, the Elixir-idiomatic API, and the
  best small-payload throughput.
- **Hackney** — better for apps that want one HTTP family across
  streaming + non-streaming, HTTP/3 support (Alt-Svc auto-upgrade), and
  the best large-payload throughput.

## Reproducing

```sh
mix run bench/http_backend.exs
```

(The benchmark script is `bench/http_backend.exs`. It needs `:benchee`
and `:bypass`/`:plug_cowboy` from the dev/test deps, both already in
`mix.exs`.)

## Results

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

### When to switch from the default

Default is Req. Switch to Hackney if:

- You're already using hackney for streaming and want to consolidate.
- Your provider serves large responses (long completions, embedding
  batches >100 vectors) and you want to shave 15–20% off body decode.
- You need HTTP/3 — hackney 4 auto-upgrades via Alt-Svc; Req/Finch
  doesn't yet.

Stay on Req if:

- You batch many parallel requests against one provider.
- You use Req middleware (`Req.Steps`, custom step pipelines).
- You want the most idiomatic Elixir HTTP API.

## Configuration

See `Nous.Providers.HTTP.post/4` for the resolution order. Quick recap:

- Per-call: `HTTP.post(url, body, headers, backend: Nous.HTTP.Backend.Hackney)`
- Env: `NOUS_HTTP_BACKEND=hackney`
- App config: `config :nous, :http_backend, Nous.HTTP.Backend.Hackney`

The env var also accepts `req`, `hackney`, or any fully-qualified
custom backend module (e.g. `MyApp.MyHTTPBackend`). Custom modules are
resolved via `String.to_existing_atom/1` with rescue, so unknown values
fall back to the app config / default rather than crash.
