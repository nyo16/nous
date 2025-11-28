defmodule Yggdrasil.Models.OpenAICompatible do
  @moduledoc """
  OpenAI-compatible model implementation using openai_ex library.

  This implementation works with any server that implements the OpenAI API:
  - OpenAI (https://api.openai.com/v1)
  - Groq (https://api.groq.com/openai/v1)
  - Ollama (http://localhost:11434/v1)
  - LM Studio (http://localhost:1234/v1)
  - OpenRouter (https://openrouter.ai/api/v1)
  - Together AI, and more...
  """

  @behaviour Yggdrasil.Models.Behaviour

  alias Yggdrasil.{Model, Messages, Errors}
  alias OpenaiEx.Chat

  require Logger

  @impl true
  def request(model, messages, settings) do
    start_time = System.monotonic_time()

    Logger.debug("""
    OpenAI-compatible request starting
      Provider: #{model.provider}
      Model: #{model.model}
      Base URL: #{model.base_url}
      Messages: #{length(messages)}
      Tools: #{if settings[:tools], do: length(settings[:tools]), else: 0}
    """)

    # Emit start event
    :telemetry.execute(
      [:yggdrasil, :model, :request, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      %{
        provider: model.provider,
        model_name: model.model,
        message_count: length(messages)
      }
    )

    # Create OpenaiEx client
    client = Model.to_client(model)

    # Convert messages to OpenAI format
    openai_messages = Messages.to_openai_messages(messages)

    # Build request parameters
    params = build_request_params(model, openai_messages, settings)

    # Make request using openai_ex
    result = case Chat.Completions.create(client, params) do
      {:ok, response} ->
        {:ok, Messages.from_openai_response(response)}

      {:error, error} ->
        Logger.error("""
        OpenAI-compatible request failed
          Provider: #{model.provider}
          Model: #{model.model}
          Error: #{inspect(error)}
        """)

        wrapped_error = Errors.ModelError.exception(
          provider: model.provider,
          message: "Request failed: #{inspect(error)}",
          details: error
        )

        {:error, wrapped_error}
    end

    # Emit stop or exception event
    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    case result do
      {:ok, parsed_response} ->
        tool_calls = Messages.extract_tool_calls(parsed_response.parts)

        Logger.info("""
        OpenAI-compatible request completed
          Provider: #{model.provider}
          Model: #{model.model}
          Duration: #{duration_ms}ms
          Tokens: #{parsed_response.usage.total_tokens} (in: #{parsed_response.usage.input_tokens}, out: #{parsed_response.usage.output_tokens})
          Tool calls: #{length(tool_calls)}
        """)

        :telemetry.execute(
          [:yggdrasil, :model, :request, :stop],
          %{
            duration: duration,
            input_tokens: parsed_response.usage.input_tokens,
            output_tokens: parsed_response.usage.output_tokens,
            total_tokens: parsed_response.usage.total_tokens
          },
          %{
            provider: model.provider,
            model_name: model.model,
            has_tool_calls: length(tool_calls) > 0
          }
        )

      {:error, error} ->
        Logger.error("Request failed after #{duration_ms}ms")

        :telemetry.execute(
          [:yggdrasil, :model, :request, :exception],
          %{duration: duration},
          %{
            provider: model.provider,
            model_name: model.model,
            kind: :error,
            reason: error
          }
        )
    end

    result
  end

  @impl true
  def request_stream(model, messages, settings) do
    start_time = System.monotonic_time()

    Logger.debug("""
    OpenAI-compatible streaming request starting
      Provider: #{model.provider}
      Model: #{model.model}
      Messages: #{length(messages)}
    """)

    # Emit start event for streaming
    :telemetry.execute(
      [:yggdrasil, :model, :stream, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      %{
        provider: model.provider,
        model_name: model.model,
        message_count: length(messages)
      }
    )

    client = Model.to_client(model)
    openai_messages = Messages.to_openai_messages(messages)

    # Enable streaming
    settings = Map.put(settings, :stream, true)
    params = build_request_params(model, openai_messages, settings)

    case Chat.Completions.create(client, params) do
      {:ok, stream} ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        Logger.info("Streaming started for #{model.provider}:#{model.model} (connected in #{duration_ms}ms)")

        # Emit connected event (stream is ready to consume)
        :telemetry.execute(
          [:yggdrasil, :model, :stream, :connected],
          %{duration: duration},
          %{
            provider: model.provider,
            model_name: model.model
          }
        )

        # Transform OpenAI.Ex stream events to our format
        transformed_stream = Stream.map(stream, &parse_stream_chunk/1)
        {:ok, transformed_stream}

      {:error, error} ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        Logger.error("""
        OpenAI-compatible streaming request failed
          Provider: #{model.provider}
          Model: #{model.model}
          Duration: #{duration_ms}ms
          Error: #{inspect(error)}
        """)

        # Emit exception event
        :telemetry.execute(
          [:yggdrasil, :model, :stream, :exception],
          %{duration: duration},
          %{
            provider: model.provider,
            model_name: model.model,
            kind: :error,
            reason: error
          }
        )

        wrapped_error = Errors.ModelError.exception(
          provider: model.provider,
          message: "Streaming request failed: #{inspect(error)}",
          details: error
        )

        {:error, wrapped_error}
    end
  end

  @impl true
  def count_tokens(messages) do
    # Rough estimation: ~4 characters per token
    messages
    |> Enum.map(&estimate_message_tokens/1)
    |> Enum.sum()
  end

  # Private functions

  defp build_request_params(model, messages, settings) do
    # Merge model defaults with request settings
    merged_settings = Map.merge(model.default_settings, settings)

    # Build base parameters
    base_params = %{
      model: model.model,
      messages: messages
    }

    # Add optional parameters
    base_params
    |> maybe_put(:temperature, merged_settings[:temperature])
    |> maybe_put(:max_tokens, merged_settings[:max_tokens])
    |> maybe_put(:top_p, merged_settings[:top_p])
    |> maybe_put(:frequency_penalty, merged_settings[:frequency_penalty])
    |> maybe_put(:presence_penalty, merged_settings[:presence_penalty])
    |> maybe_put(:stop, merged_settings[:stop_sequences])
    |> maybe_put(:stream, merged_settings[:stream])
    |> maybe_put(:tools, merged_settings[:tools])
    |> maybe_put(:tool_choice, merged_settings[:tool_choice])
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp parse_stream_chunk(chunk) do
    # OpenAI.Ex provides chunk with choices
    choice = List.first(chunk.choices)

    if choice do
      delta = choice.delta

      cond do
        delta.content ->
          {:text_delta, delta.content}

        delta.tool_calls ->
          {:tool_call_delta, delta.tool_calls}

        choice.finish_reason ->
          {:finish, choice.finish_reason}

        true ->
          {:unknown, chunk}
      end
    else
      {:unknown, chunk}
    end
  end

  defp estimate_message_tokens(message) do
    # Rough estimation: ~4 characters per token
    message
    |> inspect()
    |> String.length()
    |> div(4)
  end
end
