defmodule Nous.HTTP.StreamBackend.Chunking do
  @moduledoc false

  # Buffer bookkeeping shared by `Nous.HTTP.StreamBackend.Req` and
  # `Nous.HTTP.StreamBackend.Hackney`.
  #
  # The two backends differ only in the transport messages they receive. Once
  # a chunk is in hand, both hold the same `{buffer, scan_state,
  # stream_parser, done}` quartet and must treat it identically: accumulate,
  # bail on overflow, parse, drop parse errors, and store the new buffer and
  # scan offset together. Keeping that as one definition is not cosmetic —
  # when these were two copies, a fix to one produced a streaming bug that
  # reproduced on exactly one provider path.

  require Logger

  alias Nous.HTTP.Buffer

  @typedoc """
  The slice of a backend's `Stream.resource/3` state this module touches.

  Backends carry transport fields (`ref`, `task`, `inflight`, ...) alongside;
  those are passed through untouched.
  """
  @type state :: %{
          required(:buffer) => binary(),
          required(:scan_state) => term(),
          required(:stream_parser) => module() | nil,
          required(:done) => boolean(),
          optional(atom()) => term()
        }

  @doc """
  Append `chunk` and parse whatever it completed.

  Returns `{:emit, events, state}` when there is something for the consumer —
  including the terminating `:buffer_overflow` error — or `{:cont, state}`
  when the chunk only advanced a partial event and the backend should go back
  to waiting for the next transport message.
  """
  @spec absorb(state(), binary()) :: {:emit, [term()], state()} | {:cont, state()}
  def absorb(state, chunk) do
    # Plain `<>` only. Matching the accumulator (bit syntax, `binary_part/3`)
    # makes ERTS drop the writable-binary optimisation and copy the whole
    # buffer on every subsequent append.
    new_buffer = state.buffer <> chunk

    if byte_size(new_buffer) > Buffer.max_buffer_size() do
      Logger.error("SSE buffer overflow, terminating stream")
      {:emit, [{:stream_error, %{reason: :buffer_overflow}}], %{state | done: true}}
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

      # `scan_state` is a byte offset into `remaining_buffer`. The two come
      # from one parse call and MUST be stored together — a stale offset
      # beside a rewritten buffer silently skips events.
      state = %{state | buffer: remaining_buffer, scan_state: scan_state}

      if Enum.empty?(valid_events) do
        {:cont, state}
      else
        {:emit, valid_events, state}
      end
    end
  end

  @doc """
  Drain the buffer at end of stream.

  Returns a `Stream.resource/3` next-fun reply directly: `{:halt, state}` when
  the tail held nothing usable, otherwise `{events, state}`. A trailing event
  without its delimiter is still delivered; parse errors and `nil` are not.
  """
  @spec flush(state()) :: {:halt, state()} | {[term()], state()}
  def flush(state) do
    {events, _remaining, _scan_state} =
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
  end
end
