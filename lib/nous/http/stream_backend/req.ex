defmodule Nous.HTTP.StreamBackend.Req do
  @moduledoc """
  `Nous.HTTP.StreamBackend` implementation backed by `Req` (Finch
  underneath).

  Default streaming backend. Drives `Req.post/1` with the `:into`
  callback so chunks are pushed into a `Task`, which forwards them to
  the consuming `Stream.resource` via `send/2`.

  ## Backpressure

  Req's `:into` callback runs in the spawned `Task`, which forwards each
  chunk to the consumer with `send/2`. BEAM mailboxes are unbounded, so
  the pair share an `:atomics` counter of **in-flight bytes**: the
  producer adds `byte_size(chunk)` before sending, the consumer subtracts
  it on receipt.

  Above the 8 MB high-water mark the producer stops calling `send/2` and
  parks in a `receive`; the consumer signals `{ref, :resume}` once the
  counter falls below the 1 MB low-water mark. Because the producer is
  Req's `:into` callback, parking it stops draining the socket, so
  backpressure propagates all the way to the wire. Resident memory per
  stream is bounded by the byte watermark rather than by chunk *count*,
  and the steady-state cost is one local `:atomics` read per chunk — no
  polling and no cross-process `Process.info/2`.

  If the consumer is truly unresponsive (the counter stays above the
  high-water mark for longer than `:backpressure_max_wait_ms`, default
  30s), the producer aborts the request and the stream yields
  `{:stream_error, %{reason: :backpressure_overflow, inflight_bytes: n}}`
  rather than wedging forever.

  The consumer process is resolved when enumeration starts, not when the
  stream is built, so a stream may be constructed in one process and
  enumerated in another (task, GenServer, LiveView).

  Callers whose downstream consumers reliably block per chunk (LiveView
  fan-out under load, persistence-on-every-chunk, slow IO) can still
  prefer `Nous.HTTP.StreamBackend.Hackney`, which provides strict
  pull-based backpressure via `:hackney`'s `{:async, :once}` mode: one
  chunk is read from the socket per consumer request, with no in-flight
  window at all.

  ## TLS verification

  Req's defaults handle TLS verification via Mint/Finch (system CAs
  with peer verification). No additional configuration needed.
  """

  @behaviour Nous.HTTP.StreamBackend

  require Logger

  alias Nous.HTTP.Buffer

  # 3 minutes — LLM streams (especially with reasoning) can sit silent
  # between chunks long enough to trip a tighter timeout. Per-call
  # `:timeout` opt overrides.
  @default_timeout 180_000

  # Backpressure watermarks (see @moduledoc), in BYTES of chunk payload
  # in flight between producer and consumer. The previous guard bounded
  # the consumer's mailbox at 1_000 *messages* and never inspected chunk
  # size, so resident memory was 1_000 x whatever Finch/Mint handed back
  # from the socket — roughly 64 MB per stream, multiplied by every
  # concurrent stream since Nous.TaskSupervisor has no :max_children
  # (perf-audit, HIGH).
  @backpressure_high_water_bytes 8 * 1024 * 1024
  @backpressure_low_water_bytes 1 * 1024 * 1024
  @backpressure_max_wait_ms 30_000

  # Bounded re-check while parked. The consumer signals `{ref, :resume}`
  # directly, so this is a lost-wakeup safety net, not a poll loop: it
  # caps the cost of a missed signal at 100ms instead of the full 30s.
  @backpressure_recheck_ms 100

  # :atomics slot indices for the shared producer/consumer counter.
  @inflight_bytes 1
  @producer_parked 2

  @impl Nous.HTTP.StreamBackend
  def stream(url, body, headers, opts \\ [])

  def stream(url, body, headers, opts)
      when is_binary(url) and is_map(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    stream_parser = Keyword.get(opts, :stream_parser)
    finch_name = Keyword.get(opts, :finch_name) || Application.get_env(:nous, :finch, Nous.Finch)

    stream =
      Stream.resource(
        fn -> start_stream(url, body, headers, timeout, finch_name, stream_parser) end,
        &next_chunk/1,
        &cleanup/1
      )

    {:ok, stream}
  end

  # Everything that binds the producer to a mailbox happens here, inside
  # the `Stream.resource/3` start_fun, not in stream/4. `Stream.resource`
  # is lazy: capturing `parent = self()` at build time aimed the producer
  # at whichever process *constructed* the stream, so enumerating it in a
  # different process (task, GenServer, LiveView) delivered every chunk
  # to a mailbox nobody was reading while the consumer blocked until the
  # 180s timeout (perf-audit, HIGH).
  defp start_stream(url, body, headers, timeout, finch_name, stream_parser) do
    parent = self()
    ref = make_ref()

    # Signed so an accounting slip surfaces as a negative counter rather
    # than wrapping to 2^64 and wedging the producer forever.
    inflight = :atomics.new(2, signed: true)

    task = start_request_task(url, body, headers, timeout, finch_name, parent, ref, inflight)

    %{
      ref: ref,
      task: task,
      task_ref: task.ref,
      inflight: inflight,
      buffer: "",
      scan_state: nil,
      done: false,
      timeout: timeout,
      stream_parser: stream_parser
    }
  end

  defp start_request_task(url, body, headers, timeout, finch_name, parent, ref, inflight) do
    # Run under Nous.TaskSupervisor (async_nolink) so the streaming task
    # is supervised — graceful shutdown gets a chance to send :EXIT, and
    # neither the producer task nor the consuming caller takes the other
    # down on crash. The consumer monitors the task pid for completion.
    Task.Supervisor.async_nolink(Nous.TaskSupervisor, fn ->
      result =
        Req.post(url,
          json: body,
          headers: headers,
          receive_timeout: timeout,
          # redirect: false — provider APIs don't 3xx; Req's unvalidated follow
          # would be an SSRF bounce. See Nous.HTTP.Backend.Req.
          redirect: false,
          finch: finch_name,
          into: fn {:data, chunk}, {req, resp} ->
            cond do
              resp.status not in 200..299 ->
                # Non-2xx: accumulate body locally so the post-call status check
                # has the error body to report. Cap it at max_buffer_size so a
                # malicious/broken endpoint can't OOM us with an unbounded error
                # body (the success path already enforces this cap).
                new_body = (resp.body || "") <> chunk

                if byte_size(new_body) > Buffer.max_buffer_size() do
                  {:halt, {req, %{resp | body: new_body}}}
                else
                  {:cont, {req, %{resp | body: new_body}}}
                end

              true ->
                case await_consumer_capacity(inflight, ref) do
                  :ok ->
                    # Account *before* the send so the consumer can never
                    # subtract bytes that were not yet added.
                    :atomics.add(inflight, @inflight_bytes, byte_size(chunk))
                    send(parent, {ref, {:chunk, chunk}})
                    {:cont, {req, resp}}

                  {:error, :backpressure_timeout, bytes} ->
                    overflow = %{reason: :backpressure_overflow, inflight_bytes: bytes}
                    send(parent, {ref, {:error, overflow}})

                    {:halt, {req, resp}}
                end
            end
          end
        )

      case result do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          send(parent, {ref, :done})

        {:ok, %Req.Response{status: status, body: response_body, headers: resp_headers}} ->
          Logger.error("Req stream got error status #{status}")

          send(
            parent,
            {ref,
             {:error,
              %{
                status: status,
                body: response_body,
                headers: normalize_headers(resp_headers)
              }}}
          )

        {:error, reason} ->
          Logger.error("Req stream error: #{inspect(reason)}")
          send(parent, {ref, {:error, reason}})
      end
    end)
  end

  # Producer half of the byte-bounded backpressure handshake.
  #
  # Reading an :atomics slot is a local memory read. The previous guard
  # called Process.info(parent, :message_queue_len) on *every* chunk;
  # since OTP 21 process_info on another process is a signal round-trip,
  # so that cost two context switches per token even with an empty queue.
  #
  # Returns :ok when there is capacity, or {:error, :backpressure_timeout,
  # inflight_bytes} if the consumer doesn't drain within
  # @backpressure_max_wait_ms.
  defp await_consumer_capacity(inflight, ref) do
    if :atomics.get(inflight, @inflight_bytes) < @backpressure_high_water_bytes do
      :ok
    else
      park(inflight, ref, System.monotonic_time(:millisecond) + @backpressure_max_wait_ms)
    end
  end

  # Park until the consumer drains back below the low-water mark.
  #
  # Publish the parked flag *before* the final capacity read: a consumer
  # that drains in between still observes the flag and wakes us, and a
  # consumer that drained just before still shows up in our read. :atomics
  # operations are sequentially consistent, so one side always wins and
  # the wakeup can't be lost by both.
  defp park(inflight, ref, deadline) do
    :atomics.put(inflight, @producer_parked, 1)

    if :atomics.get(inflight, @inflight_bytes) < @backpressure_low_water_bytes do
      :atomics.put(inflight, @producer_parked, 0)
      :ok
    else
      wait_for_resume(inflight, ref, deadline)
    end
  end

  defp wait_for_resume(inflight, ref, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :atomics.put(inflight, @producer_parked, 0)
      {:error, :backpressure_timeout, :atomics.get(inflight, @inflight_bytes)}
    else
      receive do
        # Re-enter park/3 rather than returning :ok: it re-reads the
        # counter, so a stale resume left over from a racing drain can't
        # release the producer while the consumer is still behind.
        {^ref, :resume} -> park(inflight, ref, deadline)
      after
        min(remaining, @backpressure_recheck_ms) -> park(inflight, ref, deadline)
      end
    end
  end

  # Consumer half: account the chunk as delivered and, if the producer
  # parked, wake it exactly once. The compare_exchange makes the wakeup
  # single-shot, so a burst of drained chunks can't pile resume messages
  # into the producer's mailbox.
  defp release_capacity(%{inflight: inflight, ref: ref, task: task}, bytes) do
    :atomics.sub(inflight, @inflight_bytes, bytes)

    if :atomics.get(inflight, @inflight_bytes) < @backpressure_low_water_bytes and
         :atomics.compare_exchange(inflight, @producer_parked, 1, 0) == :ok do
      send(task.pid, {ref, :resume})
    end

    :ok
  end

  # Get the next batch of events.
  defp next_chunk(%{done: true} = state), do: {:halt, state}

  defp next_chunk(state) do
    receive do
      {ref, :done} when ref == state.ref ->
        {events, _, _} =
          Buffer.flush_stream_buffer(state.buffer, state.stream_parser, state.scan_state)

        final_events =
          Enum.reject(events, fn
            nil -> true
            {:parse_error, _} -> true
            _ -> false
          end)

        if Enum.empty?(final_events) do
          {:halt, %{state | done: true}}
        else
          {final_events, %{state | done: true, buffer: "", scan_state: nil}}
        end

      {ref, {:error, reason}} when ref == state.ref ->
        {[{:stream_error, reason}], %{state | done: true}}

      # Task crashed without sending an explicit completion message —
      # surface it as a stream error instead of waiting for the receive
      # timeout. The :normal case here can only fire if a stale DOWN
      # arrives before our explicit messages, which doesn't happen with
      # Task.async monitor ordering, so any DOWN here is abnormal.
      {:DOWN, task_ref, :process, _pid, reason} when task_ref == state.task_ref ->
        Logger.error("Req stream task died: #{inspect(reason)}")
        {[{:stream_error, %{reason: :task_died, details: reason}}], %{state | done: true}}

      {ref, {:chunk, chunk}} when ref == state.ref ->
        release_capacity(state, byte_size(chunk))
        new_buffer = state.buffer <> chunk

        if byte_size(new_buffer) > Buffer.max_buffer_size() do
          Logger.error("SSE buffer overflow, terminating stream")
          {[{:stream_error, %{reason: :buffer_overflow}}], %{state | done: true}}
        else
          {events, remaining_buffer, scan_state} =
            Buffer.parse_stream_buffer(new_buffer, state.stream_parser, state.scan_state)

          {valid_events, errors} =
            Enum.split_with(events, fn
              {:parse_error, _} -> false
              _ -> true
            end)

          for {:parse_error, err} <- errors do
            Logger.debug("SSE parse error (ignored): #{inspect(err)}")
          end

          state = %{state | buffer: remaining_buffer, scan_state: scan_state}

          if Enum.empty?(valid_events) do
            next_chunk(state)
          else
            {valid_events, state}
          end
        end
    after
      state.timeout ->
        Logger.error("Req stream timeout after #{state.timeout}ms")
        {[{:stream_error, %{reason: :timeout, timeout_ms: state.timeout}}], %{state | done: true}}
    end
  end

  # Mirror Nous.HTTP.Backend.Req.normalize_headers/1 — flatten the map shape
  # Req returns into [{name, value}] tuples that RetryInfo expects.
  defp normalize_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {k, vs} -> Enum.map(vs, &{k, &1}) end)
  end

  defp cleanup(%{task: nil}), do: :ok

  defp cleanup(%{task: task}) do
    # Brutal kill: the task may still be in Req.post pulling chunks. We
    # don't care about graceful shutdown — the consumer halted the
    # enumerator, which means it's done with the stream.
    _ = Task.shutdown(task, :brutal_kill)
    :ok
  end
end
