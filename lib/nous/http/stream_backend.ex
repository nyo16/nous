defmodule Nous.HTTP.StreamBackend do
  @moduledoc """
  Behaviour for SSE / chunked streaming HTTP backends.

  Implemented by `Nous.HTTP.StreamBackend.Req` (default) and
  `Nous.HTTP.StreamBackend.Hackney`. Selection mirrors the non-streaming
  `Nous.HTTP.Backend` resolution chain (per-call → env var → app config →
  default). See `Nous.Providers.HTTP.stream/4` for the resolution order.

  Pick a backend three ways, highest precedence first:

      # 1. Per-call opt
      Nous.Providers.HTTP.stream(url, body, headers,
        stream_backend: Nous.HTTP.StreamBackend.Hackney)

      # 2. Environment variable (req | hackney | "MyApp.MyStreamBackend")
      export NOUS_HTTP_STREAM_BACKEND=hackney

      # 3. Application config
      config :nous, :http_stream_backend, Nous.HTTP.StreamBackend.Hackney

  Default: `Nous.HTTP.StreamBackend.Req`.

  ## When to pick which

  - `Nous.HTTP.StreamBackend.Req` — one HTTP stack across streaming and
    non-streaming, simpler dependency story. Right default for most apps.
    Backpressure is bounded by parsing speed, not by `stream_next/1`
    pacing — a fast LLM + slow consumer can grow the consumer's mailbox.
    Acceptable for typical LLM workloads where token rate is the
    bottleneck.
  - `Nous.HTTP.StreamBackend.Hackney` — strict pull-based backpressure
    via `:hackney`'s `{:async, :once}` mode. The consumer paces the
    producer chunk-by-chunk. Pick this when downstream consumers can
    block per chunk (LiveView assigns + diff + push under load,
    persistence-on-every-chunk, slow IO).

  Both backends emit the same normalized event stream (parsed JSON maps,
  `{:stream_done, reason}`, `{:stream_error, reason}`). Switching between
  them does not require changes elsewhere.

  ## Custom backends

  Implement `c:stream/4` and return `{:ok, Enumerable.t()}` where the
  enumerable emits parsed JSON maps, `{:stream_done, reason}` tuples, or
  `{:stream_error, reason}` tuples. The stream MUST halt after the first
  `{:stream_error, _}` and after `{:stream_done, _}`.
  """

  @doc """
  Issue a streaming POST request and return a lazy `Enumerable.t()` of
  parsed events.

  ## Options
    * `:timeout` — receive timeout in milliseconds (default: `180_000`)
    * `:connect_timeout` — TCP connect timeout in milliseconds (default: `30_000`)
    * `:stream_parser` — module implementing `parse_buffer/1` for non-SSE
      formats (e.g. JSON-array streams). Defaults to SSE.

      A parser MAY additionally export the resumable arity
      `parse_buffer(buffer, scan_state)` returning
      `{events, remaining_buffer, scan_state}`. `scan_state` is an opaque
      token the parser hands back to itself on the next chunk so it can
      resume scanning instead of re-walking the accumulated buffer from
      byte 0 — the difference between O(n) and O(n²) when one object spans
      many chunks. `Nous.HTTP.Buffer` probes for it with
      `function_exported?/3`; parsers exporting only `parse_buffer/1` are
      unaffected. See `Nous.Providers.HTTP.JSONArrayParser`.

  Backends MAY accept additional options; unknown options should be ignored.

  ## Enumerate in a process with a quiet mailbox

  Both bundled backends drive their `Stream.resource/3` from a `receive`
  that matches on a ref carried in the resource state. The BEAM can only
  emit receive markers — skip straight to messages newer than the ref —
  when `make_ref/0` and the `receive` sit in the *same* function, which
  `Stream.resource/3`'s split between start_fun and next_fun rules out.
  Every chunk therefore rescans the mailbox from the head. That is free in
  a dedicated consumer and O(pending x chunks) in a process also taking
  PubSub, timer, or monitor traffic. Under LiveView fan-out, enumerate the
  stream in a `Task` and forward results, rather than in the LiveView
  process itself.
  """
  @callback stream(
              url :: String.t(),
              body :: map(),
              headers :: [{String.t(), String.t()}],
              opts :: keyword()
            ) :: {:ok, Enumerable.t()} | {:error, term()}
end
