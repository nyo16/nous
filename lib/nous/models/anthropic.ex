defmodule Nous.Models.Anthropic do
  @moduledoc """
  Anthropic Claude model implementation.

  Uses pure Req/Finch HTTP clients via `Nous.Providers.Anthropic`.
  Supports Claude-specific features like extended thinking.
  """

  @behaviour Nous.Models.Behaviour

  alias Nous.{Messages, Errors}
  alias Nous.Providers.Anthropic, as: AnthropicProvider

  require Logger

  @impl true
  def request(model, messages, settings) do
    start_time = System.monotonic_time()

    # Check for extended context and thinking config
    enable_long_context = get_long_context_setting(model, settings)
    thinking_config = settings[:thinking]

    Logger.debug("""
    Anthropic request starting
      Model: #{model.model}
      Messages: #{length(messages)}
      Extended context: #{enable_long_context}
      Thinking mode: #{if thinking_config, do: "enabled", else: "disabled"}
      Tools: #{if settings[:tools], do: length(settings[:tools]), else: 0}
    """)

    # Build request parameters
    params = build_params(model, messages, settings)
    opts = build_provider_opts(model, settings)

    result = case AnthropicProvider.chat(params, opts) do
      {:ok, response} ->
        {:ok, parse_response(response, model)}

      {:error, error} ->
        Logger.error("""
        Anthropic request failed
          Model: #{model.model}
          Error: #{inspect(error)}
        """)

        wrapped_error = Errors.ModelError.exception(
          provider: :anthropic,
          message: "Anthropic request failed: #{inspect(error)}",
          details: error
        )

        {:error, wrapped_error}
    end

    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    case result do
      {:ok, parsed_response} ->
        tool_calls = Messages.extract_tool_calls([parsed_response])

        Logger.info("""
        Anthropic request completed
          Model: #{model.model}
          Duration: #{duration_ms}ms
          Tokens: #{parsed_response.usage.total_tokens} (in: #{parsed_response.usage.input_tokens}, out: #{parsed_response.usage.output_tokens})
          Tool calls: #{length(tool_calls)}
        """)

      {:error, _error} ->
        Logger.error("Request failed after #{duration_ms}ms")
    end

    result
  end

  @impl true
  def request_stream(model, messages, settings) do
    Logger.debug("""
    Anthropic streaming request starting
      Model: #{model.model}
      Messages: #{length(messages)}
    """)

    params = build_params(model, messages, settings)
    opts = build_provider_opts(model, settings)

    case AnthropicProvider.chat_stream(params, opts) do
      {:ok, stream} ->
        Logger.info("Streaming started for Anthropic #{model.model}")
        # Transform stream events to our format
        transformed_stream = Stream.map(stream, &parse_stream_event/1)
        {:ok, transformed_stream}

      {:error, error} ->
        Logger.error("""
        Anthropic streaming request failed
          Model: #{model.model}
          Error: #{inspect(error)}
        """)

        wrapped_error = Errors.ModelError.exception(
          provider: :anthropic,
          message: "Anthropic streaming failed: #{inspect(error)}",
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
  defp build_provider_opts(model, settings) do
    enable_long_context = get_long_context_setting(model, settings)

    opts = [
      api_key: model.api_key,
      timeout: model.receive_timeout,
      finch_name: Application.get_env(:nous, :finch, Nous.Finch),
      enable_long_context: enable_long_context
    ]

    # Add custom base_url if present
    if model.base_url && model.base_url != "" do
      Keyword.put(opts, :base_url, model.base_url)
    else
      opts
    end
  end

  defp get_long_context_setting(model, settings) do
    Map.get(settings, :enable_long_context) ||
      Map.get(model.default_settings, :enable_long_context, false)
  end

  defp build_params(model, messages_list, settings) do
    # Merge model defaults with request settings
    merged_settings = Map.merge(model.default_settings, settings)

    # Convert messages and extract system prompts
    {system, anthropic_messages} = convert_messages_to_anthropic(messages_list)

    # Build base parameters
    params = %{
      "model" => model.model,
      "messages" => anthropic_messages,
      "max_tokens" => merged_settings[:max_tokens] || 1024
    }

    # Add system prompt if present
    params = if system, do: Map.put(params, "system", system), else: params

    # Add optional parameters
    params
    |> maybe_put("temperature", merged_settings[:temperature])
    |> maybe_put("top_p", merged_settings[:top_p])
    |> maybe_put("tools", merged_settings[:tools])
    |> maybe_add_thinking(merged_settings[:thinking])
  end

  defp maybe_add_thinking(params, nil), do: params

  defp maybe_add_thinking(params, thinking) when is_map(thinking) do
    thinking_config = %{}

    thinking_config =
      if Map.has_key?(thinking, :type) or Map.has_key?(thinking, "type") do
        type = Map.get(thinking, :type) || Map.get(thinking, "type")
        Map.put(thinking_config, "type", type)
      else
        thinking_config
      end

    thinking_config =
      if Map.has_key?(thinking, :budget_tokens) or Map.has_key?(thinking, "budget_tokens") do
        budget = Map.get(thinking, :budget_tokens) || Map.get(thinking, "budget_tokens")
        Map.put(thinking_config, "budget_tokens", budget)
      else
        thinking_config
      end

    if map_size(thinking_config) > 0 do
      type = Map.get(thinking_config, "type", "enabled")
      budget = Map.get(thinking_config, "budget_tokens", "unlimited")
      Logger.debug("Configuring thinking mode: type=#{type}, budget=#{budget}")
      Map.put(params, "thinking", thinking_config)
    else
      params
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp convert_messages_to_anthropic(messages_list) do
    # Extract system prompts and convert the rest
    {system_prompts, other_messages} =
      Enum.split_with(messages_list, &match?({:system_prompt, _}, &1))

    # Combine system prompts
    system =
      if not Enum.empty?(system_prompts) do
        system_prompts
        |> Enum.map(fn {:system_prompt, text} -> text end)
        |> Enum.join("\n\n")
      else
        nil
      end

    # Convert other messages
    anthropic_messages =
      other_messages
      |> Enum.map(&convert_message/1)
      |> Enum.reject(&is_nil/1)

    {system, anthropic_messages}
  end

  defp convert_message({:user_prompt, text}) when is_binary(text) do
    %{"role" => "user", "content" => text}
  end

  defp convert_message({:user_prompt, content}) when is_list(content) do
    %{"role" => "user", "content" => convert_content_list(content)}
  end

  defp convert_message({:tool_return, %{call_id: id, result: result}}) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => id,
          "content" => Jason.encode!(result)
        }
      ]
    }
  end

  # Previous assistant response
  defp convert_message(%{parts: parts}) do
    text = Messages.extract_text(parts)
    tool_calls = Messages.extract_tool_calls(parts)

    content = []

    content =
      if text != "" do
        [%{"type" => "text", "text" => text} | content]
      else
        content
      end

    content =
      if not Enum.empty?(tool_calls) do
        tool_content =
          Enum.map(tool_calls, fn call ->
            %{
              "type" => "tool_use",
              "id" => call.id,
              "name" => call.name,
              "input" => call.arguments
            }
          end)

        tool_content ++ content
      else
        content
      end

    if Enum.empty?(content) do
      nil
    else
      %{"role" => "assistant", "content" => Enum.reverse(content)}
    end
  end

  defp convert_message(_), do: nil

  defp convert_content_list(content) do
    Enum.map(content, fn
      {:text, text} -> %{"type" => "text", "text" => text}
      {:image_url, url} -> %{"type" => "image", "source" => %{"type" => "url", "url" => url}}
      text when is_binary(text) -> %{"type" => "text", "text" => text}
    end)
  end

  defp parse_response(response, _model) do
    content = Map.get(response, "content") || Map.get(response, :content) || []
    usage_data = Map.get(response, "usage") || Map.get(response, :usage) || %{}
    model_name = Map.get(response, "model") || Map.get(response, :model)

    parts = parse_content_blocks(content)

    usage = %Nous.Usage{
      requests: 1,
      input_tokens: Map.get(usage_data, "input_tokens") || Map.get(usage_data, :input_tokens) || 0,
      output_tokens: Map.get(usage_data, "output_tokens") || Map.get(usage_data, :output_tokens) || 0,
      total_tokens:
        (Map.get(usage_data, "input_tokens") || Map.get(usage_data, :input_tokens) || 0) +
          (Map.get(usage_data, "output_tokens") || Map.get(usage_data, :output_tokens) || 0)
    }

    %{
      parts: parts,
      usage: usage,
      model_name: model_name,
      timestamp: DateTime.utc_now()
    }
  end

  defp parse_content_blocks(content) when is_list(content) do
    Enum.map(content, fn block ->
      type = Map.get(block, "type") || Map.get(block, :type)

      case type do
        "text" ->
          text = Map.get(block, "text") || Map.get(block, :text)
          {:text, text}

        "tool_use" ->
          id = Map.get(block, "id") || Map.get(block, :id)
          name = Map.get(block, "name") || Map.get(block, :name)
          input = Map.get(block, "input") || Map.get(block, :input)
          {:tool_call, %{id: id, name: name, arguments: input}}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_content_blocks(content) when is_binary(content) do
    [{:text, content}]
  end

  defp parse_stream_event(event) do
    case event do
      %{"type" => "content_block_delta", "delta" => %{"text" => text}} ->
        {:text_delta, text}

      %{type: "content_block_delta", delta: %{text: text}} ->
        {:text_delta, text}

      %{"type" => "message_stop"} ->
        {:finish, "stop"}

      %{type: "message_stop"} ->
        {:finish, "stop"}

      {:stream_done, reason} ->
        {:finish, reason}

      _ ->
        {:unknown, event}
    end
  end

  defp estimate_message_tokens(message) do
    message |> inspect() |> String.length() |> div(4)
  end
end
