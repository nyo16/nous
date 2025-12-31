defmodule Nous.Providers.HTTP do
  @moduledoc """
  Shared HTTP utilities for all LLM providers.

  Provides both non-streaming (Req) and streaming (Finch) HTTP capabilities
  with provider-agnostic SSE (Server-Sent Events) parsing.

  ## Usage

      # Non-streaming request
      {:ok, body} = HTTP.post(url, body, headers)

      # Streaming request (returns lazy stream)
      {:ok, stream} = HTTP.stream(url, body, headers)
      Enum.each(stream, &process_event/1)

  ## SSE Parsing

  SSE events follow the Server-Sent Events spec (https://html.spec.whatwg.org/multipage/server-sent-events.html):
  - Events are separated by double newlines (`\\n\\n`)
  - Each event contains field lines like `data: {...}`
  - Multiple `data:` fields are concatenated with newlines
  - `[DONE]` signals stream completion (OpenAI convention)
  """

  require Logger

  @default_timeout 60_000
  @max_buffer_size 10 * 1024 * 1024  # 10MB max buffer

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Make a non-streaming POST request.

  Returns `{:ok, body}` or `{:error, reason}`.

  ## Options
    * `:timeout` - Request timeout in ms (default: 60_000)

  ## Error Reasons
    * `%{status: integer(), body: term()}` - HTTP error response
    * `%Mint.TransportError{}` - Network error
    * `%Jason.DecodeError{}` - JSON decode error
  """
  @spec post(String.t(), map(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(url, body, headers, opts \\ [])

  def post(url, body, headers, opts) when is_binary(url) and is_map(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Req.post(url,
           json: body,
           headers: headers,
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        Logger.warning("HTTP request failed with status #{status}: #{truncate_for_log(response_body)}")
        {:error, %{status: status, body: response_body}}

      {:error, %Mint.TransportError{reason: reason} = error} ->
        Logger.error("Transport error: #{inspect(reason)}")
        {:error, error}

      {:error, error} ->
        Logger.error("HTTP request error: #{inspect(error)}")
        {:error, error}
    end
  end

  def post(url, body, headers, _opts) do
    {:error, %ArgumentError{
      message: "Invalid arguments: url must be string, body must be map, headers must be list. " <>
               "Got: url=#{inspect(url)}, body=#{inspect(body)}, headers=#{inspect(headers)}"
    }}
  end

  @doc """
  Make a streaming POST request with SSE parsing.

  Returns `{:ok, stream}` where stream is an Enumerable of parsed events.
  Events are maps with string keys (parsed JSON) or `{:stream_done, reason}` tuples.

  ## Options
    * `:timeout` - Request timeout in ms (default: 60_000)
    * `:finch_name` - Finch pool name (default: Nous.Finch)

  ## Error Handling
  The stream will emit `{:stream_error, reason}` on errors and then halt.
  """
  @spec stream(String.t(), map(), list(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(url, body, headers, opts \\ [])

  def stream(url, body, headers, opts) when is_binary(url) and is_map(body) and is_list(headers) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

    case Jason.encode(body) do
      {:ok, json_body} ->
        # Add streaming headers if not present
        headers = ensure_streaming_headers(headers)

        stream = Stream.resource(
          fn -> start_streaming(url, headers, json_body, finch_name, timeout) end,
          &next_chunk/1,
          &cleanup/1
        )

        {:ok, stream}

      {:error, error} ->
        Logger.error("Failed to encode request body: #{inspect(error)}")
        {:error, %{reason: :json_encode_error, details: error}}
    end
  end

  def stream(url, body, headers, _opts) do
    {:error, %ArgumentError{
      message: "Invalid arguments: url must be string, body must be map, headers must be list. " <>
               "Got: url=#{inspect(url)}, body=#{inspect(body)}, headers=#{inspect(headers)}"
    }}
  end

  # ============================================================================
  # SSE Parsing (Public for testing)
  # ============================================================================

  @doc """
  Parse an SSE buffer into events.

  Returns `{events, remaining_buffer}` where events is a list of parsed
  JSON maps, `{:stream_done, reason}` tuples, or `{:parse_error, reason}` tuples.

  Handles edge cases:
  - Empty events (ignored)
  - Whitespace-only events (ignored)
  - Malformed JSON (emits `{:parse_error, reason}`)
  - Multiple data fields per event (concatenated per spec)
  - Comment lines (ignored)
  - Buffer overflow protection

  ## Examples

      iex> parse_sse_buffer("data: {\\"text\\": \\"hi\\"}\\n\\n")
      {[%{"text" => "hi"}], ""}

      iex> parse_sse_buffer("data: partial")
      {[], "data: partial"}

      iex> parse_sse_buffer("data: [DONE]\\n\\n")
      {[{:stream_done, "stop"}], ""}
  """
  @spec parse_sse_buffer(String.t()) :: {list(), String.t()}
  def parse_sse_buffer(buffer) when is_binary(buffer) do
    # Protect against buffer overflow
    buffer = if byte_size(buffer) > @max_buffer_size do
      Logger.warning("SSE buffer exceeded max size (#{@max_buffer_size} bytes), truncating")
      binary_part(buffer, byte_size(buffer) - @max_buffer_size, @max_buffer_size)
    else
      buffer
    end

    # Split on double newlines (SSE event separator)
    # Handle both \n\n and \r\n\r\n
    parts = String.split(buffer, ~r/\r?\n\r?\n/)

    case parts do
      [incomplete] ->
        # No complete events yet
        {[], incomplete}

      parts ->
        # All but the last part are complete events
        {complete, [incomplete]} = Enum.split(parts, -1)
        events =
          complete
          |> Enum.map(&parse_sse_event/1)
          |> Enum.reject(&is_nil/1)
        {events, incomplete}
    end
  end

  def parse_sse_buffer(nil), do: {[], ""}
  def parse_sse_buffer(_), do: {[], ""}

  @doc """
  Parse a single SSE event.

  Returns parsed JSON map, `{:stream_done, reason}`, `{:parse_error, reason}`, or nil.

  Handles per SSE spec:
  - `data:` fields (with or without space after colon)
  - Multiple `data:` fields concatenated with newlines
  - `:` prefix for comments (ignored)
  - `event:`, `id:`, `retry:` fields (ignored for now)
  - Empty lines within events

  ## Examples

      iex> parse_sse_event("data: {\\"key\\": \\"value\\"}")
      %{"key" => "value"}

      iex> parse_sse_event("data: [DONE]")
      {:stream_done, "stop"}

      iex> parse_sse_event(": this is a comment")
      nil

      iex> parse_sse_event("")
      nil
  """
  @spec parse_sse_event(String.t()) :: map() | {:stream_done, String.t()} | {:parse_error, term()} | nil
  def parse_sse_event(event) when is_binary(event) do
    # Trim and check for empty
    event = String.trim(event)

    if event == "" do
      nil
    else
      parse_sse_event_lines(String.split(event, ~r/\r?\n/))
    end
  end

  def parse_sse_event(_), do: nil

  # ============================================================================
  # Header Helpers (Public for testing)
  # ============================================================================

  @doc """
  Build authorization header for Bearer token auth (OpenAI style).

  Returns empty list for nil, empty string, or "not-needed" values.
  """
  @spec bearer_auth_header(String.t() | nil) :: list()
  def bearer_auth_header(nil), do: []
  def bearer_auth_header(""), do: []
  def bearer_auth_header("not-needed"), do: []
  def bearer_auth_header(api_key) when is_binary(api_key), do: [{"authorization", "Bearer #{api_key}"}]
  def bearer_auth_header(_), do: []

  @doc """
  Build authorization header for API key auth (Anthropic style).

  Returns empty list for nil or empty string values.
  """
  @spec api_key_header(String.t() | nil, String.t()) :: list()
  def api_key_header(nil, _header_name), do: []
  def api_key_header("", _header_name), do: []
  def api_key_header(api_key, header_name) when is_binary(api_key) and is_binary(header_name) do
    [{header_name, api_key}]
  end
  def api_key_header(_, _), do: []

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Ensure headers include streaming-related ones
  defp ensure_streaming_headers(headers) do
    headers
    |> maybe_add_header("content-type", "application/json")
    |> maybe_add_header("accept", "text/event-stream")
  end

  defp maybe_add_header(headers, key, value) do
    key_lower = String.downcase(key)
    if Enum.any?(headers, fn {k, _} -> String.downcase(to_string(k)) == key_lower end) do
      headers
    else
      [{key, value} | headers]
    end
  end

  # Parse SSE event from lines
  defp parse_sse_event_lines(lines) do
    # Collect all data fields
    data_parts =
      lines
      |> Enum.reduce([], fn line, acc ->
        cond do
          # Comment line (starts with :)
          String.starts_with?(line, ":") ->
            acc

          # Data field with space
          String.starts_with?(line, "data: ") ->
            [String.trim_leading(line, "data: ") | acc]

          # Data field without space (valid per spec)
          String.starts_with?(line, "data:") ->
            [String.trim_leading(line, "data:") | acc]

          # Other fields (event:, id:, retry:) - ignore for now
          String.contains?(line, ":") ->
            acc

          # Empty line or continuation
          true ->
            acc
        end
      end)
      |> Enum.reverse()

    if Enum.empty?(data_parts) do
      nil
    else
      # Per SSE spec, multiple data fields are joined with newlines
      data = Enum.join(data_parts, "\n")
      parse_data_content(data)
    end
  end

  # Parse the data content (JSON or special markers)
  defp parse_data_content("[DONE]"), do: {:stream_done, "stop"}
  defp parse_data_content(""), do: nil

  defp parse_data_content(data) do
    case Jason.decode(data) do
      {:ok, parsed} ->
        parsed
      {:error, error} ->
        # Only log at debug level - malformed data is common during streaming
        Logger.debug("Failed to parse SSE data as JSON: #{truncate_for_log(data)}, error: #{inspect(error)}")
        {:parse_error, %{data: data, error: error}}
    end
  end

  # Start streaming - spawn a process to handle Finch.stream
  defp start_streaming(url, headers, body, finch_name, timeout) do
    parent = self()

    pid = spawn_link(fn ->
      Process.flag(:trap_exit, true)
      parent_ref = Process.monitor(parent)

      request = Finch.build(:post, url, headers, body)

      stream_task = Task.async(fn ->
        try do
          Finch.stream(request, finch_name, nil, fn
            {:status, status}, acc ->
              send(parent, {:sse, :status, status})
              acc

            {:headers, resp_headers}, acc ->
              send(parent, {:sse, :headers, resp_headers})
              acc

            {:data, data}, acc ->
              send(parent, {:sse, :data, data})
              acc
          end, receive_timeout: timeout)
        rescue
          e ->
            Logger.error("Finch.stream raised: #{inspect(e)}")
            {:error, e}
        catch
          kind, reason ->
            Logger.error("Finch.stream caught #{kind}: #{inspect(reason)}")
            {:error, {kind, reason}}
        end
      end)

      handle_stream_lifecycle(parent, parent_ref, stream_task)
    end)

    %{
      pid: pid,
      buffer: "",
      done: false,
      status: nil,
      timeout: timeout,
      error: nil
    }
  end

  # Handle the lifecycle of the streaming process
  defp handle_stream_lifecycle(parent, parent_ref, stream_task) do
    receive do
      {:EXIT, ^parent, reason} ->
        Logger.debug("Parent died (#{inspect(reason)}), cleaning up stream")
        Task.shutdown(stream_task, 1_000)

      {:DOWN, ^parent_ref, :process, ^parent, reason} ->
        Logger.debug("Parent monitor fired (#{inspect(reason)}), cleaning up stream")
        Task.shutdown(stream_task, 1_000)

      {:EXIT, _from, :shutdown} ->
        Logger.debug("Graceful shutdown requested for stream")
        case Task.shutdown(stream_task, 1_000) do
          {:ok, _} -> send(parent, {:sse, :done, :ok})
          nil -> send(parent, {:sse, :done, :ok})
          {:exit, reason} -> send(parent, {:sse, :done, {:error, reason}})
        end

      {:EXIT, _from, reason} ->
        Logger.debug("Force shutdown requested for stream: #{inspect(reason)}")
        Task.shutdown(stream_task, :brutal_kill)
        send(parent, {:sse, :done, {:error, reason}})
    after
      0 ->
        case Task.await(stream_task, :infinity) do
          {:ok, _} ->
            send(parent, {:sse, :done, :ok})
          {:error, %Mint.TransportError{reason: :closed}} ->
            # Normal close
            send(parent, {:sse, :done, :ok})
          {:error, error} ->
            Logger.error("Stream task error: #{inspect(error)}")
            send(parent, {:sse, :done, {:error, error}})
          other ->
            Logger.warning("Unexpected stream task result: #{inspect(other)}")
            send(parent, {:sse, :done, {:error, {:unexpected, other}}})
        end
    end
  end

  # Get next chunk from the stream
  defp next_chunk(%{done: true} = state), do: {:halt, state}

  defp next_chunk(state) do
    timeout = state.timeout

    receive do
      {:sse, :status, status} when status not in 200..299 ->
        Logger.error("SSE stream got error status #{status}")
        {[{:stream_error, %{status: status}}], %{state | done: true}}

      {:sse, :status, status} ->
        next_chunk(%{state | status: status})

      {:sse, :headers, _headers} ->
        next_chunk(state)

      {:sse, :data, data} ->
        new_buffer = state.buffer <> data

        # Check buffer size
        if byte_size(new_buffer) > @max_buffer_size do
          Logger.error("SSE buffer overflow, terminating stream")
          {[{:stream_error, %{reason: :buffer_overflow}}], %{state | done: true}}
        else
          {events, remaining_buffer} = parse_sse_buffer(new_buffer)

          # Filter out parse errors if we want to be lenient
          {valid_events, errors} = Enum.split_with(events, fn
            {:parse_error, _} -> false
            _ -> true
          end)

          # Log parse errors but don't emit them (they're usually partial data)
          for {:parse_error, err} <- errors do
            Logger.debug("SSE parse error (ignored): #{inspect(err)}")
          end

          if Enum.empty?(valid_events) do
            next_chunk(%{state | buffer: remaining_buffer})
          else
            {valid_events, %{state | buffer: remaining_buffer}}
          end
        end

      {:sse, :done, :ok} ->
        # Flush any remaining buffer
        {events, _} = parse_sse_buffer(state.buffer <> "\n\n")
        final_events = Enum.reject(events, fn
          nil -> true
          {:parse_error, _} -> true
          _ -> false
        end)

        if Enum.empty?(final_events) do
          {:halt, %{state | done: true}}
        else
          {final_events, %{state | done: true, buffer: ""}}
        end

      {:sse, :done, {:error, error}} ->
        Logger.error("SSE stream error: #{inspect(error)}")
        {[{:stream_error, error}], %{state | done: true}}

    after
      timeout ->
        Logger.error("SSE stream timeout after #{timeout}ms")
        {[{:stream_error, %{reason: :timeout, timeout_ms: timeout}}], %{state | done: true}}
    end
  end

  # Cleanup when stream is done
  defp cleanup(state) do
    if state[:pid] && Process.alive?(state.pid) do
      Process.exit(state.pid, :shutdown)

      # Give it a moment to cleanup gracefully
      Process.sleep(100)

      if Process.alive?(state.pid) do
        Logger.debug("Stream process didn't respond to graceful shutdown, force killing")
        Process.exit(state.pid, :kill)
      end
    end
    :ok
  end

  # Truncate data for logging to avoid huge log messages
  defp truncate_for_log(data) when is_binary(data) do
    if byte_size(data) > 500 do
      String.slice(data, 0, 500) <> "... (truncated)"
    else
      data
    end
  end

  defp truncate_for_log(data), do: inspect(data, limit: 500)
end
