defmodule Nous.HTTP.StreamBackend.Req do
  @moduledoc """
  `Nous.HTTP.StreamBackend` implementation backed by `Req` (Finch
  underneath).

  Default streaming backend. Drives `Req.post/1` with the `:into`
  callback so chunks are pushed into a `Task`, which forwards them to
  the consuming `Stream.resource` via `send/2`.

  ## Backpressure

  Req's `:into` callback runs in the spawned `Task`. Forwarding to the
  consumer process is `send/2`, so a fast producer + slow consumer can
  grow the consumer's mailbox.

  The producer task watches the consumer's mailbox via
  `Process.info(parent, :message_queue_len)`. When the queue length
  crosses `@backpressure_high_water` (default 1_000 chunks) the task
  busy-waits in 5ms increments until it drops below
  `@backpressure_low_water` (default 100). This gives Req's `:into`
  callback natural backpressure — the producing socket doesn't read
  more bytes while we're waiting — without requiring the consumer to
  switch to the Hackney backend.

  If the consumer is *truly* unresponsive (the mailbox stays high for
  longer than `:backpressure_max_wait_ms`), the task emits
  `{:backpressure_overflow, %{queue_len: n}}` and aborts the stream
  rather than wedging forever.

  Callers whose downstream consumers reliably block per chunk
  (LiveView fan-out under load, persistence-on-every-chunk, slow IO)
  can still prefer `Nous.HTTP.StreamBackend.Hackney`, which provides
  strict pull-based backpressure via `:hackney`'s `{:async, :once}`
  mode.

  ## TLS verification

  Req's defaults handle TLS verification via Mint/Finch (system CAs
  with peer verification). No additional configuration needed.
  """

  @behaviour Nous.HTTP.StreamBackend

  require Logger

  alias Nous.Providers.HTTP

  # 3 minutes — LLM streams (especially with reasoning) can sit silent
  # between chunks long enough to trip a tighter timeout. Per-call
  # `:timeout` opt overrides.
  @default_timeout 180_000

  # Backpressure watermarks (see @moduledoc). Tuned so that an under-load
  # LiveView consumer pauses the producer rather than OOMing.
  @backpressure_high_water 1_000
  @backpressure_low_water 100
  @backpressure_max_wait_ms 30_000

  @impl Nous.HTTP.StreamBackend
  def stream(url, body, headers, opts \\ [])

  def stream(url, body, headers, opts)
      when is_binary(url) and is_map(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    stream_parser = Keyword.get(opts, :stream_parser)
    finch_name = Keyword.get(opts, :finch_name) || Application.get_env(:nous, :finch, Nous.Finch)

    parent = self()
    ref = make_ref()

    task = start_request_task(url, body, headers, timeout, finch_name, parent, ref)

    state = %{
      ref: ref,
      task: task,
      task_ref: task.ref,
      buffer: "",
      done: false,
      timeout: timeout,
      stream_parser: stream_parser
    }

    stream =
      Stream.resource(
        fn -> state end,
        &next_chunk/1,
        &cleanup/1
      )

    {:ok, stream}
  end

  defp start_request_task(url, body, headers, timeout, finch_name, parent, ref) do
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
          finch: finch_name,
          into: fn {:data, chunk}, {req, resp} ->
            cond do
              resp.status not in 200..299 ->
                # Non-2xx: accumulate body locally so the post-call status
                # check has the full error body to report. Do not forward.
                {:cont, {req, %{resp | body: (resp.body || "") <> chunk}}}

              true ->
                case await_consumer_capacity(parent) do
                  :ok ->
                    send(parent, {ref, {:chunk, chunk}})
                    {:cont, {req, resp}}

                  {:error, :backpressure_timeout, queue_len} ->
                    send(
                      parent,
                      {ref, {:error, %{reason: :backpressure_overflow, queue_len: queue_len}}}
                    )

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

  # Block the producer task while the consumer's mailbox is above the
  # high-water mark, releasing once it drops back below the low-water mark.
  # Returns :ok when capacity is available, or {:error, :backpressure_timeout, queue_len}
  # if the consumer doesn't drain within @backpressure_max_wait_ms.
  defp await_consumer_capacity(parent) do
    case message_queue_len(parent) do
      n when n < @backpressure_high_water ->
        :ok

      _ ->
        wait_for_drain(parent, System.monotonic_time(:millisecond))
    end
  end

  defp wait_for_drain(parent, started_at) do
    case message_queue_len(parent) do
      n when n < @backpressure_low_water ->
        :ok

      n ->
        if System.monotonic_time(:millisecond) - started_at > @backpressure_max_wait_ms do
          {:error, :backpressure_timeout, n}
        else
          Process.sleep(5)
          wait_for_drain(parent, started_at)
        end
    end
  end

  defp message_queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      # parent already gone — let the next send/2 fail and surface that
      nil -> 0
    end
  end

  # Get the next batch of events.
  defp next_chunk(%{done: true} = state), do: {:halt, state}

  defp next_chunk(state) do
    receive do
      {ref, :done} when ref == state.ref ->
        {events, _} = HTTP.flush_stream_buffer(state.buffer, state.stream_parser)

        final_events =
          Enum.reject(events, fn
            nil -> true
            {:parse_error, _} -> true
            _ -> false
          end)

        if Enum.empty?(final_events) do
          {:halt, %{state | done: true}}
        else
          {final_events, %{state | done: true, buffer: ""}}
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
        new_buffer = state.buffer <> chunk

        if byte_size(new_buffer) > HTTP.max_buffer_size() do
          Logger.error("SSE buffer overflow, terminating stream")
          {[{:stream_error, %{reason: :buffer_overflow}}], %{state | done: true}}
        else
          {events, remaining_buffer} =
            HTTP.parse_stream_buffer(new_buffer, state.stream_parser)

          {valid_events, errors} =
            Enum.split_with(events, fn
              {:parse_error, _} -> false
              _ -> true
            end)

          for {:parse_error, err} <- errors do
            Logger.debug("SSE parse error (ignored): #{inspect(err)}")
          end

          if Enum.empty?(valid_events) do
            next_chunk(%{state | buffer: remaining_buffer})
          else
            {valid_events, %{state | buffer: remaining_buffer}}
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
