defmodule Nous.HTTP.OpenAIClient do
  @moduledoc """
  Custom HTTP client for OpenAI-compatible APIs using Finch.

  This client handles both streaming and non-streaming requests to
  OpenAI-compatible endpoints (vLLM, SGLang, LM Studio, Ollama, etc.).

  Uses Finch for HTTP and handles SSE (Server-Sent Events) parsing for streaming.
  """

  require Logger

  @default_timeout 60_000

  @doc """
  Make a non-streaming chat completion request.

  Returns `{:ok, response_map}` or `{:error, reason}`.
  """
  def chat_completion(base_url, api_key, params, opts \\ []) do
    url = "#{base_url}/chat/completions"
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    headers = build_headers(api_key)

    case Req.post(url,
           json: params,
           headers: headers,
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Make a streaming chat completion request.

  Returns `{:ok, stream}` where stream is an Enumerable of parsed SSE events,
  or `{:error, reason}`.

  Each event in the stream is a map with string keys matching the OpenAI format:
  - `%{"choices" => [%{"delta" => %{"content" => "..."}}]}`
  """
  def chat_completion_stream(base_url, api_key, params, opts \\ []) do
    url = "#{base_url}/chat/completions"
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Ensure stream is enabled
    params = Map.put(params, :stream, true)

    headers = build_headers(api_key)
    body = Jason.encode!(params)

    finch_name = Keyword.get(opts, :finch_name, Nous.Finch)

    # Create the stream using Stream.resource for proper lifecycle management
    stream = Stream.resource(
      fn -> start_streaming(url, headers, body, finch_name, timeout) end,
      &next_chunk/1,
      &cleanup/1
    )

    {:ok, stream}
  end

  # Build headers for the request
  defp build_headers(api_key) do
    headers = [
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    if api_key && api_key != "" && api_key != "not-needed" do
      [{"authorization", "Bearer #{api_key}"} | headers]
    else
      headers
    end
  end

  # Start streaming - spawn a process to handle Finch.stream
  defp start_streaming(url, headers, body, finch_name, timeout) do
    parent = self()

    # Spawn a dedicated process to run Finch.stream
    pid = spawn_link(fn ->
      # Enable trapping exits so we can handle cleanup signals
      Process.flag(:trap_exit, true)

      # Monitor parent to detect if it dies
      parent_ref = Process.monitor(parent)

      request = Finch.build(:post, url, headers, body)

      # Run the stream in a task we can control
      stream_task = Task.async(fn ->
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
      end)

      # Wait for stream completion or exit signal
      receive do
        {:EXIT, ^parent, _reason} ->
          # Parent died, clean up
          Logger.debug("Parent died, cleaning up stream")
          Task.shutdown(stream_task, 1_000)

        {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
          # Parent monitor fired, clean up
          Logger.debug("Parent monitor fired, cleaning up stream")
          Task.shutdown(stream_task, 1_000)

        {:EXIT, _from, :shutdown} ->
          # Graceful shutdown requested
          Logger.debug("Graceful shutdown requested for stream")
          case Task.shutdown(stream_task, 1_000) do
            :ok -> send(parent, {:sse, :done, :ok})
            _ -> send(parent, {:sse, :done, {:error, :shutdown_timeout}})
          end

        {:EXIT, _from, reason} ->
          # Other exit reason, force shutdown
          Logger.debug("Force shutdown requested for stream: #{inspect(reason)}")
          Task.shutdown(stream_task, :brutal_kill)
          send(parent, {:sse, :done, {:error, reason}})
      after
        0 ->
          # No immediate exit signal, wait for task completion
          case Task.await(stream_task, :infinity) do
            {:ok, _} ->
              send(parent, {:sse, :done, :ok})
            {:error, error} ->
              send(parent, {:sse, :done, {:error, error}})
          end
      end
    end)

    %{
      pid: pid,
      buffer: "",
      done: false,
      status: nil,
      timeout: timeout
    }
  end

  # Get next chunk from the stream
  defp next_chunk(%{done: true} = state), do: {:halt, state}

  defp next_chunk(state) do
    timeout = state.timeout

    receive do
      {:sse, :status, status} when status != 200 ->
        Logger.error("SSE stream got status #{status}")
        {:halt, %{state | done: true}}

      {:sse, :status, status} ->
        next_chunk(%{state | status: status})

      {:sse, :headers, _headers} ->
        next_chunk(state)

      {:sse, :data, data} ->
        {events, new_buffer} = parse_sse_buffer(state.buffer <> data)
        if Enum.empty?(events) do
          # No complete events yet, keep receiving
          next_chunk(%{state | buffer: new_buffer})
        else
          {events, %{state | buffer: new_buffer}}
        end

      {:sse, :done, :ok} ->
        # Parse any remaining buffer
        {events, _} = parse_sse_buffer(state.buffer <> "\n\n")
        final_events = Enum.reject(events, &is_nil/1)
        if Enum.empty?(final_events) do
          {:halt, %{state | done: true}}
        else
          {final_events, %{state | done: true}}
        end

      {:sse, :done, {:error, error}} ->
        Logger.error("SSE stream error: #{inspect(error)}")
        {:halt, %{state | done: true}}

    after
      timeout ->
        Logger.error("SSE stream timeout after #{timeout}ms")
        {:halt, %{state | done: true}}
    end
  end

  # Cleanup when stream is done
  defp cleanup(state) do
    if state[:pid] && Process.alive?(state.pid) do
      # Try graceful shutdown first
      Process.exit(state.pid, :shutdown)

      # Wait a bit for graceful shutdown, then force kill if needed
      :timer.sleep(100)
      if Process.alive?(state.pid) do
        Logger.debug("Stream process didn't respond to graceful shutdown, force killing")
        Process.exit(state.pid, :kill)
      end
    end
    :ok
  end

  # Parse SSE buffer into events
  defp parse_sse_buffer(buffer) do
    # Split on double newlines (SSE event separator)
    parts = String.split(buffer, "\n\n")

    case parts do
      # Only one part means no complete event yet
      [incomplete] ->
        {[], incomplete}

      # Multiple parts - last one is incomplete
      parts ->
        {complete, [incomplete]} = Enum.split(parts, -1)
        events = Enum.map(complete, &parse_sse_event/1) |> Enum.reject(&is_nil/1)
        {events, incomplete}
    end
  end

  # Parse a single SSE event
  defp parse_sse_event(""), do: nil

  # Handle [DONE] event - emit a finish signal
  defp parse_sse_event("data: [DONE]"), do: {:stream_done, "stop"}

  defp parse_sse_event(event) do
    # Handle multi-line events
    lines = String.split(event, "\n")

    Enum.find_value(lines, fn line ->
      case line do
        "data: [DONE]" -> {:stream_done, "stop"}
        "data: " <> json_data ->
          case Jason.decode(json_data) do
            {:ok, parsed} -> parsed
            {:error, _} -> nil
          end
        _ -> nil
      end
    end)
  end
end
