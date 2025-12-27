defmodule Nous.Models.OpenAICompatible do
  @moduledoc """
  OpenAI-compatible model implementation.

  Uses OpenaiEx for official OpenAI, and custom Req-based client for other providers.

  This implementation works with any server that implements the OpenAI API:
  - OpenAI (https://api.openai.com/v1) - uses OpenaiEx
  - Groq (https://api.groq.com/openai/v1) - uses OpenaiEx
  - OpenRouter (https://openrouter.ai/api/v1) - uses OpenaiEx
  - vLLM, SGLang, Ollama, LM Studio, etc. - uses custom HTTP client
  """

  @behaviour Nous.Models.Behaviour

  alias Nous.{Model, Messages, Errors}
  alias Nous.HTTP.OpenAIClient
  alias OpenaiEx.Chat

  require Logger

  # Providers that work well with OpenaiEx (cloud providers with proper SSE)
  @openaiex_providers [:openai, :groq, :openrouter]

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
      [:nous, :model, :request, :start],
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
          [:nous, :model, :request, :stop],
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
          [:nous, :model, :request, :exception],
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
      [:nous, :model, :stream, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      %{
        provider: model.provider,
        model_name: model.model,
        message_count: length(messages)
      }
    )

    openai_messages = Messages.to_openai_messages(messages)

    # Enable streaming
    settings = Map.put(settings, :stream, true)
    params = build_request_params(model, openai_messages, settings)

    # Use OpenaiEx for cloud providers, custom client for local/custom
    result = if model.provider in @openaiex_providers do
      request_stream_openaiex(model, params)
    else
      request_stream_custom(model, params)
    end

    case result do
      {:ok, stream} ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        Logger.info("Streaming started for #{model.provider}:#{model.model} (connected in #{duration_ms}ms)")

        # Emit connected event (stream is ready to consume)
        :telemetry.execute(
          [:nous, :model, :stream, :connected],
          %{duration: duration},
          %{
            provider: model.provider,
            model_name: model.model
          }
        )

        # Transform stream events to our format using the normalizer
        normalizer = model.stream_normalizer || Nous.StreamNormalizer.OpenAI
        transformed_stream = Nous.StreamNormalizer.normalize(stream, normalizer)
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
          [:nous, :model, :stream, :exception],
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

  # Use OpenaiEx for cloud providers with proper SSE support
  defp request_stream_openaiex(model, params) do
    client = Model.to_client(model)
    Chat.Completions.create(client, params)
  end

  # Use custom HTTP client for local/custom providers
  defp request_stream_custom(model, params) do
    OpenAIClient.chat_completion_stream(
      model.base_url,
      model.api_key,
      params,
      timeout: model.receive_timeout,
      finch_name: Application.get_env(:nous, :finch, Nous.Finch)
    )
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

  defp estimate_message_tokens(message) do
    # Rough estimation: ~4 characters per token
    message
    |> inspect()
    |> String.length()
    |> div(4)
  end
end
