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
  backpressure propagates all the way to the wire, and the steady-state
  cost is one local `:atomics` read per chunk — no polling and no
  cross-process `Process.info/2`.

  ### What the watermark actually bounds

  Resident memory per stream is bounded by *bytes* rather than by chunk
  *count*, but 8 MB is not the whole ceiling:

    * the window is read *before* the chunk is accounted for, so a producer
      that finds room then adds a full chunk on top of it. The in-flight
      bound is 8 MB plus one chunk, not 8 MB.
    * the consumer's SSE accumulator is separate memory, capped at
      `Nous.HTTP.Buffer.max_buffer_size/0` (10 MB) and checked after the
      concat. It stacks on the in-flight window rather than sharing it.

  So a single stream can hold ~18 MB before either guard fires. Across
  streams the bound is `Nous.TaskSupervisor`'s `:max_children`
  (`config :nous, :task_supervisor_max_children`, default 1_000): a stream
  occupies exactly one task there, so that count times the per-stream
  figure is the aggregate ceiling. Until that limit existed, N concurrent
  streams were bounded by nothing.

  Because a stream holds its task for its whole duration, that number is
  also the ceiling on *concurrent streams*, and it is reachable. When it is
  reached the stream returned by `stream/4` is still a well-formed stream:
  it yields a single `{:stream_error, %{reason: :saturated}}` event and
  halts, the same shape a connect failure or a read timeout produces, so
  callers already handling transport errors need no new branch. It never
  raises — the task is spawned lazily inside the `Stream.resource/3`
  start_fun, so a raise would surface in the consumer at whatever `Enum`
  call first touched the stream, arbitrarily far from the `stream/4` that
  built it.

  ### Buffer and scan state

  The consumer carries `buffer` and `scan_state` as a **pair**. The parser
  hands back the unconsumed tail together with a byte offset into it, so a
  chunk scans only what it just added rather than rescanning the whole
  accumulation. Store both or neither: a stale offset beside a rewritten
  buffer silently skips events.

  Plain `<>` append is load-bearing here. Matching the accumulator with bit
  syntax, or retaining a `binary_part/3` slice of it, defeats ERTS's
  in-place append and makes every subsequent append copy the whole buffer.

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
  alias Nous.HTTP.StreamBackend.Chunking
  alias Nous.Tasks

  # 3 minutes — LLM streams (especially with reasoning) can sit silent
  # between chunks long enough to trip a tighter timeout. Per-call
  # `:timeout` opt overrides.
  @default_timeout 180_000

  # Backpressure watermarks (see @moduledoc), in BYTES of chunk payload
  # in flight between producer and consumer. The previous guard bounded
  # the consumer's mailbox at 1_000 *messages* and never inspected chunk
  # size, so resident memory was 1_000 x whatever Finch/Mint handed back
  # from the socket — roughly 64 MB per stream, multiplied by an unbounded
  # number of concurrent streams (perf-audit, HIGH). This window is the
  # per-stream half of the fix; the aggregate half is Nous.TaskSupervisor's
  # :max_children, since each stream holds exactly one task there.
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

    state = %{
      ref: ref,
      task: nil,
      task_ref: nil,
      inflight: inflight,
      buffer: "",
      scan_state: nil,
      done: false,
      error: nil,
      timeout: timeout,
      stream_parser: stream_parser
    }

    case start_request_task(url, body, headers, timeout, finch_name, parent, ref, inflight) do
      {:ok, task} ->
        %{state | task: task, task_ref: task.ref}

      # Supervisor at its ceiling. Degrade exactly like Hackney's connect
      # failure: carry the error in the state and let next_chunk/1 hand the
      # consumer one {:stream_error, _} event, staying `done: false` so that
      # clause fires once before the halt. Letting the refusal raise here
      # would raise out of a lazy PUBLIC stream, in the consumer, at
      # whichever `Enum` call first touched it.
      {:error, :saturated} ->
        Tasks.warn_saturated("an outbound LLM stream")
        %{state | error: {:stream_error, %{reason: :saturated}}}
    end
  end

  defp start_request_task(url, body, headers, timeout, finch_name, parent, ref, inflight) do
    # Run under Nous.TaskSupervisor (async_nolink) so the streaming task
    # is supervised — graceful shutdown gets a chance to send :EXIT, and
    # neither the producer task nor the consuming caller takes the other
    # down on crash. The consumer monitors the task pid for completion.
    Tasks.async_nolink(fn ->
      result =
        Req.post(url,
          json: body,
          headers: headers,
          receive_timeout: timeout,
          # redirect: false — provider APIs don't 3xx; Req's unvalidated follow
          # would be an SSRF bounce. See Nous.HTTP.Backend.Req.
          redirect: false,
          finch: [name: finch_name],
          into: &forward_chunk(&1, &2, parent, ref, inflight)
        )

      report_result(result, parent, ref)
    end)
  end

  # Non-2xx: accumulate the body locally so the post-call status check has the
  # error body to report. Cap it at max_buffer_size so a malicious/broken
  # endpoint can't OOM us with an unbounded error body (the success path already
  # enforces this cap).
  defp forward_chunk({:data, chunk}, {req, %{status: status} = resp}, _parent, _ref, _inflight)
       when status not in 200..299 do
    new_body = (resp.body || "") <> chunk
    resp = %{resp | body: new_body}

    if byte_size(new_body) > Buffer.max_buffer_size() do
      {:halt, {req, resp}}
    else
      {:cont, {req, resp}}
    end
  end

  defp forward_chunk({:data, chunk}, {req, resp}, parent, ref, inflight) do
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

  defp report_result({:ok, %Req.Response{status: status}}, parent, ref)
       when status in 200..299 do
    send(parent, {ref, :done})
  end

  defp report_result(
         {:ok, %Req.Response{status: status, body: response_body, headers: resp_headers}},
         parent,
         ref
       ) do
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
  end

  defp report_result({:error, reason}, parent, ref) do
    Logger.error("Req stream error: #{inspect(reason)}")
    send(parent, {ref, {:error, reason}})
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

  # Refused spawn: emit the carried error, then halt on the next pass.
  defp next_chunk(%{task: nil, error: {:stream_error, _} = err} = state) do
    {[err], %{state | done: true}}
  end

  defp next_chunk(state) do
    receive do
      {ref, :done} when ref == state.ref ->
        Chunking.flush(state)

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

        case Chunking.absorb(state, chunk) do
          {:emit, events, state} -> {events, state}
          {:cont, state} -> next_chunk(state)
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
