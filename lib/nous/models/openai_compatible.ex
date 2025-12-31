defmodule Nous.Models.OpenAICompatible do
  @moduledoc """
  OpenAI-compatible model implementation.

  Works with any server that implements the OpenAI API:
  - OpenAI (https://api.openai.com/v1)
  - Groq (https://api.groq.com/openai/v1)
  - OpenRouter (https://openrouter.ai/api/v1)
  - Together (https://api.together.xyz/v1)
  - vLLM, SGLang, Ollama, LM Studio, etc.

  Uses pure Req/Finch HTTP clients via `Nous.Providers.OpenAI`.
  """

  @behaviour Nous.Models.Behaviour

  alias Nous.{Messages, Errors}
  alias Nous.Providers.OpenAI, as: OpenAIProvider

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
      [:nous, :model, :request, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      %{
        provider: model.provider,
        model_name: model.model,
        message_count: length(messages)
      }
    )

    # Convert messages to OpenAI format
    openai_messages = Messages.to_openai_format(messages)

    # Build request parameters
    params = build_request_params(model, openai_messages, settings)

    # Make request via provider
    opts = build_provider_opts(model)
    result = case OpenAIProvider.chat(params, opts) do
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

    # Emit telemetry
    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    case result do
      {:ok, parsed_response} ->
        tool_calls = Messages.extract_tool_calls([parsed_response])

        Logger.info("""
        OpenAI-compatible request completed
          Provider: #{model.provider}
          Model: #{model.model}
          Duration: #{duration_ms}ms
          Tokens: #{parsed_response.metadata.usage.total_tokens} (in: #{parsed_response.metadata.usage.input_tokens}, out: #{parsed_response.metadata.usage.output_tokens})
          Tool calls: #{length(tool_calls)}
        """)

        :telemetry.execute(
          [:nous, :model, :request, :stop],
          %{
            duration: duration,
            input_tokens: parsed_response.metadata.usage.input_tokens,
            output_tokens: parsed_response.metadata.usage.output_tokens,
            total_tokens: parsed_response.metadata.usage.total_tokens
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

    openai_messages = Messages.to_openai_format(messages)
    params = build_request_params(model, openai_messages, settings)
    opts = build_provider_opts(model)

    result = OpenAIProvider.chat_stream(params, opts)

    case result do
      {:ok, stream} ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        Logger.info("Streaming started for #{model.provider}:#{model.model} (connected in #{duration_ms}ms)")

        # Emit connected event
        :telemetry.execute(
          [:nous, :model, :stream, :connected],
          %{duration: duration},
          %{
            provider: model.provider,
            model_name: model.model
          }
        )

        # Transform stream events using normalizer
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

  @impl true
  def count_tokens(messages) do
    messages
    |> Enum.map(&estimate_message_tokens/1)
    |> Enum.sum()
  end

  # Build provider options from model config
  defp build_provider_opts(model) do
    opts = [
      base_url: model.base_url,
      api_key: model.api_key,
      timeout: model.receive_timeout,
      finch_name: Application.get_env(:nous, :finch, Nous.Finch)
    ]

    # Add organization if present
    if model.organization do
      Keyword.put(opts, :organization, model.organization)
    else
      opts
    end
  end

  defp build_request_params(model, messages, settings) do
    # Merge model defaults with request settings
    merged_settings = Map.merge(model.default_settings, settings)

    # Build base parameters
    base_params = %{
      "model" => model.model,
      "messages" => messages
    }

    # Add optional parameters
    base_params
    |> maybe_put("temperature", merged_settings[:temperature])
    |> maybe_put("max_tokens", merged_settings[:max_tokens])
    |> maybe_put("top_p", merged_settings[:top_p])
    |> maybe_put("frequency_penalty", merged_settings[:frequency_penalty])
    |> maybe_put("presence_penalty", merged_settings[:presence_penalty])
    |> maybe_put("stop", merged_settings[:stop_sequences])
    |> maybe_put("tools", merged_settings[:tools])
    |> maybe_put("tool_choice", merged_settings[:tool_choice])
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp estimate_message_tokens(message) do
    message |> inspect() |> String.length() |> div(4)
  end
end
