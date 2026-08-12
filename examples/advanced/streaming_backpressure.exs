#!/usr/bin/env elixir

# Nous AI - Streaming Backpressure
#
# Two streaming backends, one deliberately slow consumer, real numbers.
#
#   Nous.HTTP.StreamBackend.Req      (default)  the producer is Req's :into
#     callback running in a supervised Task. It forwards chunks with send/2
#     and only parks when 8 MB of chunk payload is in flight (an :atomics
#     byte counter, 8 MB high water / 1 MB low water). Below the window the
#     producer runs ahead of the consumer as fast as the socket allows.
#
#   Nous.HTTP.StreamBackend.Hackney  (opt-in)   :hackney's {:async, :once}
#     pull mode. The socket is re-armed with `active: once` only when the
#     consumer calls :hackney.stream_next/1, so the producer cannot run
#     ahead at all — the wire is paced chunk-by-chunk by the consumer.
#
# AGENTS.md and docs/guides/http_backends.md describe that difference in
# prose. This script measures it. A dependency-free :gen_tcp listener on
# loopback streams a chunked SSE body and records how long each
# :gen_tcp.send/2 blocked; the consumer samples the server's byte counter
# as it crawls through the events. "Bytes produced vs bytes consumed" is
# therefore a genuine cross-process measurement, not narration.
#
# Offline: no provider, no API key, no extra dependency. Exits 0 either way
# (the hackney half self-skips if :hackney is not in your dep set).
#
#     mix run examples/advanced/streaming_backpressure.exs

IO.puts("=== Nous AI - Streaming Backpressure ===\n")

# ============================================================================
# Local SSE Server (:gen_tcp, no dependencies)
# ============================================================================

defmodule BackpressureLab.Server do
  @moduledoc false

  # Deliberately small socket buffers and inet-driver watermarks. With the
  # defaults, the kernel send buffer plus the port's own output queue absorb
  # megabytes before :gen_tcp.send/2 ever blocks, and a pull-mode consumer
  # would look exactly like a windowed one. Shrinking them makes the wire
  # the bottleneck, which is the thing being measured.
  @listen_opts [
    :binary,
    packet: :raw,
    active: false,
    reuseaddr: true,
    backlog: 4,
    sndbuf: 4096,
    high_watermark: 8192,
    low_watermark: 4096
  ]

  @response_head "HTTP/1.1 200 OK\r\n" <>
                   "content-type: text/event-stream\r\n" <>
                   "cache-control: no-cache\r\n" <>
                   "transfer-encoding: chunked\r\n" <>
                   "connection: close\r\n\r\n"

  @doc """
  Listen on an ephemeral loopback port and serve exactly one request.

  `opts` is a map with `:frames`, `:frame_bytes`, `:produced` (an
  `:atomics` ref the caller polls) and `:t0` (a shared monotonic origin
  in microseconds). Returns `{:ok, port}`; the caller receives
  `{:server_request, user_agent}` and then `{:server_done, stats}`.
  """
  def start(opts) do
    {:ok, listen} = :gen_tcp.listen(0, [{:ip, {127, 0, 0, 1}} | @listen_opts])
    {:ok, port} = :inet.port(listen)
    owner = self()
    spawn_link(fn -> serve(listen, owner, opts) end)
    {:ok, port}
  end

  defp serve(listen, owner, opts) do
    {:ok, sock} = :gen_tcp.accept(listen, 15_000)
    :ok = :gen_tcp.close(listen)

    {head, rest} = read_head(sock, "")
    drain_request_body(sock, head, rest)
    send(owner, {:server_request, header(head, "user-agent")})

    :ok = :gen_tcp.send(sock, @response_head)
    stats = send_frames(sock, opts)
    :ok = :gen_tcp.send(sock, "0\r\n\r\n")
    send(owner, {:server_done, stats})

    # `connection: close`, so the client hangs up once it has the terminating
    # chunk. Waiting for that instead of closing with unread bytes still
    # queued avoids an RST that would truncate the tail of the body.
    _ = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)
  rescue
    error -> send(owner, {:server_error, error})
  end

  # One HTTP chunk per SSE frame, timing every send. A send that takes
  # milliseconds is the producer being throttled: either the kernel send
  # buffer is full (nobody is draining the socket) or the inet driver's
  # output queue crossed its high watermark.
  defp send_frames(sock, %{frames: frames, frame_bytes: frame_bytes} = opts) do
    %{produced: produced, t0: t0} = opts
    filler = String.duplicate("x", filler_bytes(frame_bytes))

    init = %{
      blocked_us: 0,
      stalls: 0,
      first_send_ms: nil,
      last_send_ms: 0.0,
      first_stall_bytes: nil,
      sent_bytes: 0
    }

    Enum.reduce(1..frames, init, fn seq, acc ->
      frame = sse_frame(seq, filler)

      before = System.monotonic_time(:microsecond)
      :ok = :gen_tcp.send(sock, http_chunk(frame))
      took = System.monotonic_time(:microsecond) - before

      :atomics.add(produced, 1, frame_bytes)

      %{
        acc
        | blocked_us: acc.blocked_us + took,
          stalls: acc.stalls + if(took >= 1_000, do: 1, else: 0),
          first_send_ms: acc.first_send_ms || (before - t0) / 1000,
          last_send_ms: (before + took - t0) / 1000,
          first_stall_bytes:
            acc.first_stall_bytes || if(took >= 5_000, do: acc.sent_bytes, else: nil),
          sent_bytes: acc.sent_bytes + frame_bytes
      }
    end)
  end

  defp sse_frame(seq, filler) do
    ["data: {\"seq\":\"", pad(seq), "\",\"pad\":\"", filler, "\"}\n\n"]
  end

  # Padded so every frame is byte-identical in size and the consumer can
  # multiply instead of measuring.
  defp pad(seq), do: seq |> Integer.to_string() |> String.pad_leading(6, "0")

  defp filler_bytes(frame_bytes) do
    overhead = IO.iodata_length(sse_frame(1, ""))
    frame_bytes - overhead
  end

  defp http_chunk(iodata) do
    [Integer.to_string(IO.iodata_length(iodata), 16), "\r\n", iodata, "\r\n"]
  end

  defp read_head(sock, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {pos, 4} ->
        {binary_part(acc, 0, pos), binary_part(acc, pos + 4, byte_size(acc) - pos - 4)}

      :nomatch ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 15_000)
        read_head(sock, acc <> data)
    end
  end

  # Closing a socket that still has unread inbound bytes sends an RST and can
  # discard our own queued response, so the request body gets consumed even
  # though the demo has no use for it.
  defp drain_request_body(sock, head, rest) do
    want = content_length(head) - byte_size(rest)

    if want > 0 do
      _ = :gen_tcp.recv(sock, want, 15_000)
    end

    :ok
  end

  defp content_length(head) do
    case header(head, "content-length") do
      nil -> 0
      value -> String.to_integer(String.trim(value))
    end
  end

  defp header(head, name) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> if String.downcase(key) == name, do: String.trim(value)
        _ -> nil
      end
    end)
  end
end

# ============================================================================
# Backend Availability
# ============================================================================

IO.puts("--- Backend Availability ---")

hackney_ready? =
  Code.ensure_loaded?(:hackney) and match?({:ok, _}, Application.ensure_all_started(:hackney))

IO.puts("  Nous.HTTP.StreamBackend.Req      available (default backend)")

if hackney_ready? do
  IO.puts("  Nous.HTTP.StreamBackend.Hackney  available (:hackney #{Application.spec(:hackney, :vsn)})")
else
  IO.puts("""
    Nous.HTTP.StreamBackend.Hackney  UNAVAILABLE

    :hackney is an optional dependency. To measure the pull-mode backend,
    add it to your deps and re-run:

        {:hackney, "~> 4.0"}

    The Req half below still runs.\
  """)
end

IO.puts("")

# ============================================================================
# Backend Selection (the real resolution chain)
# ============================================================================

# Nous.Providers.HTTP.stream/4 resolves the backend as:
#
#   1. per-call  stream_backend: Module
#   2. env var   NOUS_HTTP_STREAM_BACKEND=req | hackney | My.Backend
#   3. config    config :nous, :http_stream_backend, Module
#   4. default   Nous.HTTP.StreamBackend.Req
#
# The probes below prove each rung. The demo server records the request's
# user-agent header, which is a hackney/Req fingerprint the script cannot
# fake: `hackney/4.6.0` vs `req/0.5.15`.

IO.puts("--- Backend Selection ---")

probe = fn opts ->
  produced = :atomics.new(1, signed: true)

  {:ok, port} =
    BackpressureLab.Server.start(%{
      frames: 1,
      frame_bytes: 256,
      produced: produced,
      t0: System.monotonic_time(:microsecond)
    })

  {:ok, stream} =
    Nous.Providers.HTTP.stream(
      "http://127.0.0.1:#{port}/v1/messages",
      %{"stream" => true},
      [],
      Keyword.merge([timeout: 15_000], opts)
    )

  _ = Enum.to_list(stream)

  user_agent =
    receive do
      {:server_request, ua} -> ua
    after
      5_000 -> nil
    end

  receive do
    {:server_done, _} -> :ok
    {:server_error, error} -> IO.puts("  server error: #{inspect(error)}")
  after
    5_000 -> :ok
  end

  cond do
    user_agent == nil -> "unknown"
    String.starts_with?(user_agent, "hackney") -> "Hackney (#{user_agent})"
    true -> "Req (#{user_agent})"
  end
end

show_probe = fn label, opts ->
  IO.puts("  #{String.pad_trailing(label, 46)} -> #{probe.(opts)}")
end

System.delete_env("NOUS_HTTP_STREAM_BACKEND")
Application.delete_env(:nous, :http_stream_backend)
show_probe.("4. default (nothing set)", [])

if hackney_ready? do
  Application.put_env(:nous, :http_stream_backend, Nous.HTTP.StreamBackend.Hackney)
  show_probe.("3. config :nous, :http_stream_backend", [])

  System.put_env("NOUS_HTTP_STREAM_BACKEND", "req")
  show_probe.("2. NOUS_HTTP_STREAM_BACKEND=req beats config", [])

  show_probe.(
    "1. per-call stream_backend: beats env var",
    stream_backend: Nous.HTTP.StreamBackend.Hackney
  )

  System.delete_env("NOUS_HTTP_STREAM_BACKEND")
  Application.delete_env(:nous, :http_stream_backend)
else
  IO.puts("  (rungs 1-3 exercise the hackney backend and are skipped)")
end

IO.puts("")

# ============================================================================
# The Measurement
# ============================================================================

frames = 200
frame_bytes = 64 * 1024
consumer_delay_ms = 12
total_bytes = frames * frame_bytes

mib = fn bytes -> :erlang.float_to_binary(bytes / 1_048_576, decimals: 2) <> " MiB" end
ms = fn value -> :erlang.float_to_binary(value * 1.0, decimals: 0) <> " ms" end

IO.puts("--- Workload ---")
IO.puts("  frames                #{frames} x #{div(frame_bytes, 1024)} KiB = #{mib.(total_bytes)}")
IO.puts("  consumer              Process.sleep(#{consumer_delay_ms}) per parsed event")
IO.puts("  consumer-bound floor  ~#{frames * consumer_delay_ms} ms of sleep in both runs\n")

# Runs one pass end to end and returns the measurements. The consumer samples
# the server's :atomics byte counter on every event, so `produced` and
# `consumed` are two readings of the same instant in two different processes.
measure = fn backend ->
  produced = :atomics.new(1, signed: true)
  t0 = System.monotonic_time(:microsecond)

  {:ok, port} =
    BackpressureLab.Server.start(%{
      frames: frames,
      frame_bytes: frame_bytes,
      produced: produced,
      t0: t0
    })

  {:ok, stream} =
    Nous.Providers.HTTP.stream(
      "http://127.0.0.1:#{port}/v1/messages",
      %{"stream" => true},
      [],
      stream_backend: backend, timeout: 60_000
    )

  {samples, seen, errors} =
    Enum.reduce(stream, {[], 0, []}, fn
      {:stream_error, reason}, {samples, seen, errors} ->
        {samples, seen, [reason | errors]}

      {:stream_done, _reason}, acc ->
        acc

      _event, {samples, seen, errors} ->
        Process.sleep(consumer_delay_ms)
        seen = seen + 1

        sample = %{
          seq: seen,
          at_ms: (System.monotonic_time(:microsecond) - t0) / 1000,
          consumed: seen * frame_bytes,
          produced: :atomics.get(produced, 1)
        }

        {[sample | samples], seen, errors}
    end)

  consumer_wall_ms = (System.monotonic_time(:microsecond) - t0) / 1000

  # The server sends {:server_request, _} then {:server_done, _}; both were
  # queued behind the stream's own messages while the reduce ran.
  user_agent =
    receive do
      {:server_request, ua} -> ua
    after
      5_000 -> nil
    end

  server =
    receive do
      {:server_done, stats} -> stats
      {:server_error, error} -> %{error: error}
    after
      10_000 -> %{error: :server_timeout}
    end

  %{
    samples: Enum.reverse(samples),
    events: seen,
    errors: Enum.reverse(errors),
    consumer_wall_ms: consumer_wall_ms,
    user_agent: user_agent,
    server: server
  }
end

report = fn label, result ->
  IO.puts("--- #{label} ---")
  IO.puts("  user-agent seen by the server: #{result.user_agent || "(none)"}")

  if result.errors != [] do
    IO.puts("  stream errors: #{inspect(result.errors)}")
  end

  IO.puts("")

  IO.puts("  event    t (ms)      consumed      produced         ahead")

  result.samples
  |> Enum.filter(fn %{seq: seq} -> seq == 1 or rem(seq, 25) == 0 end)
  |> Enum.each(fn s ->
    IO.puts(
      "  " <>
        String.pad_leading(Integer.to_string(s.seq), 5) <>
        String.pad_leading(:erlang.float_to_binary(s.at_ms, decimals: 0), 10) <>
        String.pad_leading(mib.(s.consumed), 14) <>
        String.pad_leading(mib.(s.produced), 14) <>
        String.pad_leading(mib.(s.produced - s.consumed), 14)
    )
  end)

  peak = result.samples |> Enum.map(&(&1.produced - &1.consumed)) |> Enum.max(fn -> 0 end)
  server = result.server

  IO.puts("")
  IO.puts("  events consumed                   #{result.events}")
  IO.puts("  consumer wall                     #{ms.(result.consumer_wall_ms)}")

  if Map.has_key?(server, :error) do
    IO.puts("  server                            error: #{inspect(server.error)}")
  else
    IO.puts(
      "  producer wall (1st->last send)    #{ms.(server.last_send_ms - server.first_send_ms)}"
    )

    IO.puts(
      "  producer blocked in gen_tcp.send  #{ms.(server.blocked_us / 1000)} across " <>
        "#{server.stalls} sends >= 1 ms"
    )

    IO.puts(
      "  wire bytes before 1st >=5ms stall " <>
        if(server.first_stall_bytes,
          do: mib.(server.first_stall_bytes),
          else: "(producer never stalled)"
        )
    )
  end

  IO.puts("  peak producer-ahead               #{mib.(peak)}")
  IO.puts("")

  %{peak: peak}
end

req_run = report.("Req backend (windowed producer)", measure.(Nous.HTTP.StreamBackend.Req))

hackney_run =
  if hackney_ready? do
    report.(
      "Hackney backend (pull-mode producer)",
      measure.(Nous.HTTP.StreamBackend.Hackney)
    )
  end

# ============================================================================
# Reading the Numbers
# ============================================================================

IO.puts("--- Reading the Numbers ---")

if hackney_run do
  IO.puts("""
    peak producer-ahead   Req #{mib.(req_run.peak)}   vs   Hackney #{mib.(hackney_run.peak)}

    `ahead` is bytes handed to the socket minus bytes parsed into events, so
    it counts everything resident between the two: kernel buffers, the
    producer, and the consumer's mailbox.

    Req filled the 8 MB window before the consumer had parsed its first
    event, then parked in a receive; the flat stretch in the "ahead" column
    is that window. It resumed in one burst once the consumer drained back
    under the 1 MB low-water mark, which is why the producer blocks rarely
    but for a long time (few stalls, seconds each).

    Hackney never ran ahead further than the socket buffers allow. With
    {:async, :once} the next read is issued by the consumer, so the producer
    blocks on nearly every send and "ahead" stays flat and small for the
    whole run.

    Both runs took the same wall clock — the consumer's sleep dominates. The
    difference is resident memory per stream, and who decides when the wire
    gets drained.\
  """)
else
  IO.puts("""
    Only the Req half ran. Its producer stops at the 8 MB in-flight window;
    the "ahead" column above plateaus there. Add {:hackney, "~> 4.0"} to
    compare against strict pull-mode backpressure.\
  """)
end

IO.puts("")
IO.puts("--- Choosing a Backend ---")

IO.puts("""
  Req (default)  one HTTP stack for streaming and non-streaming. The 8 MB
                 window bounds memory without pacing the wire, which is the
                 right trade when token generation is the bottleneck.

  Hackney        strict pull-based backpressure. Pick it when the consumer
                 reliably blocks per chunk: LiveView assign + diff + push
                 under fan-out, persistence on every delta, slow IO.

  Selection      config :nous, :http_stream_backend, Nous.HTTP.StreamBackend.Hackney
                 NOUS_HTTP_STREAM_BACKEND=hackney
                 Nous.Providers.HTTP.stream(url, body, headers,
                   stream_backend: Nous.HTTP.StreamBackend.Hackney)
""")

IO.puts("=== Demo Complete ===")
