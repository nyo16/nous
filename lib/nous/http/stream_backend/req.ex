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
  grow the consumer's mailbox unboundedly. This is acceptable for
  typical LLM workloads where token-generation rate is the bottleneck
  and consumers are parsing-bound (parsing throttles naturally).

  Callers whose downstream consumers can block per chunk (LiveView
  fan-out under load, persistence-on-every-chunk, slow IO) should use
  `Nous.HTTP.StreamBackend.Hackney` instead, which provides strict
  pull-based backpressure via `:hackney`'s `{:async, :once}` mode.

  ## TLS verification

  Req's defaults handle TLS verification via Mint/Finch (system CAs
  with peer verification). No additional configuration needed.
  """

  @behaviour Nous.HTTP.StreamBackend

  require Logger

  alias Nous.Providers.HTTP

  @default_timeout 60_000
  @default_connect_timeout 30_000

  @impl Nous.HTTP.StreamBackend
  def stream(url, body, headers, opts \\ [])

  def stream(url, body, headers, opts)
      when is_binary(url) and is_map(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    stream_parser = Keyword.get(opts, :stream_parser)

    parent = self()
    ref = make_ref()

    task = start_request_task(url, body, headers, timeout, connect_timeout, parent, ref)

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

  defp start_request_task(url, body, headers, timeout, connect_timeout, parent, ref) do
    Task.async(fn ->
      result =
        Req.post(url,
          json: body,
          headers: headers,
          receive_timeout: timeout,
          connect_options: [timeout: connect_timeout],
          into: fn {:data, chunk}, {req, resp} ->
            if resp.status in 200..299 do
              send(parent, {ref, {:chunk, chunk}})
              {:cont, {req, resp}}
            else
              # Non-2xx: accumulate body locally so the post-call status
              # check has the full error body to report. Do not forward.
              {:cont, {req, %{resp | body: (resp.body || "") <> chunk}}}
            end
          end
        )

      case result do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          send(parent, {ref, :done})

        {:ok, %Req.Response{status: status, body: response_body}} ->
          Logger.error("Req stream got error status #{status}")
          send(parent, {ref, {:error, %{status: status, body: response_body}}})

        {:error, reason} ->
          Logger.error("Req stream error: #{inspect(reason)}")
          send(parent, {ref, {:error, reason}})
      end
    end)
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

  defp cleanup(%{task: nil}), do: :ok

  defp cleanup(%{task: task}) do
    # Brutal kill: the task may still be in Req.post pulling chunks. We
    # don't care about graceful shutdown — the consumer halted the
    # enumerator, which means it's done with the stream.
    _ = Task.shutdown(task, :brutal_kill)
    :ok
  end
end
