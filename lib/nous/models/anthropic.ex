defmodule Nous.Models.Anthropic do
  @moduledoc """
  Anthropic Claude implementation using the native Anthropix library.

  This adapter uses Anthropic's native API (not OpenAI-compatible) via Anthropix,
  providing access to Claude-specific features like extended thinking.

  **Note:** This provider requires the optional `anthropix` dependency.
  Add it to your deps: `{:anthropix, "~> 0.6.2"}`
  """

  @behaviour Nous.Models.Behaviour

  alias Nous.{Messages, Errors}

  require Logger

  # Check if Anthropix is available at runtime (not compile-time)
  defp anthropix_available? do
    Code.ensure_loaded?(Anthropix)
  end

  defp ensure_anthropix! do
    unless anthropix_available?() do
      raise Errors.ConfigurationError,
        message: "anthropix dependency not available. Add {:anthropix, \"~> 0.6.2\"} to your deps."
    end
  end

  @impl true
  def request(model, messages, settings) do
    ensure_anthropix!()

    start_time = System.monotonic_time()

    # Create Anthropix client with optional extended context
    client_opts = build_client_opts(model, settings)
    enable_long_context = Keyword.get(client_opts, :beta) != nil
    thinking_config = settings[:thinking]

    Logger.debug("""
    Anthropic request starting
      Model: #{model.model}
      Messages: #{length(messages)}
      Extended context: #{enable_long_context}
      Thinking mode: #{if thinking_config, do: "enabled", else: "disabled"}
      Tools: #{if settings[:tools], do: length(settings[:tools]), else: 0}
    """)

    # Use dynamic call to avoid compile-time dependency
    client = apply(Anthropix, :init, [model.api_key, client_opts])

    # Build request parameters (this will convert messages)
    params = build_params(model, messages, settings)

    # Make request
    # Use dynamic call to avoid compile-time dependency
    result = case apply(Anthropix, :chat, [client, params]) do
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
    ensure_anthropix!()

    Logger.debug("""
    Anthropic streaming request starting
      Model: #{model.model}
      Messages: #{length(messages)}
    """)

    # Create Anthropix client with optional extended context
    client_opts = build_client_opts(model, settings)
    # Use dynamic call to avoid compile-time dependency
    client = apply(Anthropix, :init, [model.api_key, client_opts])

    # Enable streaming
    settings = Map.put(settings, :stream, true)
    params = build_params(model, messages, settings)

    # Use dynamic call to avoid compile-time dependency
    case apply(Anthropix, :chat, [client, params]) do
      {:ok, stream} ->
        Logger.info("Streaming started for Anthropic #{model.model}")
        # Transform Anthropix stream to our format
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
    # Rough estimation for Claude
    messages
    |> Enum.map(&estimate_message_tokens/1)
    |> Enum.sum()
  end

  # Private functions

  defp build_client_opts(model, settings) do
    # Check if extended context is enabled
    enable_long_context =
      Map.get(settings, :enable_long_context) ||
        Map.get(model.default_settings, :enable_long_context, false)

    if enable_long_context do
      Logger.debug("Enabling extended context (1M tokens) for Anthropic")
      [beta: ["context-1m-2025-08-07"]]
    else
      []
    end
  end

  defp build_params(model, messages_list, settings) do
    # Merge model defaults with request settings
    merged_settings = Map.merge(model.default_settings, settings)

    # Convert messages and extract system prompts
    {system, anthropic_messages} = convert_messages_to_anthropic(messages_list)

    # Build base parameters for Anthropix
    params = [
      model: model.model,
      messages: anthropic_messages
    ]

    # Add system prompt if present
    params = if system, do: Keyword.put(params, :system, system), else: params

    # Add optional parameters
    params
    |> maybe_add_kw(:max_tokens, merged_settings[:max_tokens] || 1024)
    |> maybe_add_kw(:temperature, merged_settings[:temperature])
    |> maybe_add_kw(:top_p, merged_settings[:top_p])
    |> maybe_add_kw(:stream, merged_settings[:stream])
    |> maybe_add_kw(:tools, merged_settings[:tools])
    |> maybe_add_thinking(merged_settings[:thinking])
  end

  defp maybe_add_thinking(params, nil), do: params

  defp maybe_add_thinking(params, thinking) when is_map(thinking) do
    # Build thinking configuration
    thinking_config = %{}

    # Add type if present (must be "enabled")
    thinking_config =
      if Map.has_key?(thinking, :type) or Map.has_key?(thinking, "type") do
        type = Map.get(thinking, :type) || Map.get(thinking, "type")
        Map.put(thinking_config, :type, type)
      else
        thinking_config
      end

    # Add budget_tokens if present
    thinking_config =
      if Map.has_key?(thinking, :budget_tokens) or Map.has_key?(thinking, "budget_tokens") do
        budget = Map.get(thinking, :budget_tokens) || Map.get(thinking, "budget_tokens")
        Map.put(thinking_config, :budget_tokens, budget)
      else
        thinking_config
      end

    if map_size(thinking_config) > 0 do
      type = Map.get(thinking_config, :type, "enabled")
      budget = Map.get(thinking_config, :budget_tokens, "unlimited")
      Logger.debug("Configuring thinking mode: type=#{type}, budget=#{budget}")
      Keyword.put(params, :thinking, thinking_config)
    else
      params
    end
  end

  defp maybe_add_kw(params, _key, nil), do: params
  defp maybe_add_kw(params, key, value), do: Keyword.put(params, key, value)

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
    %{role: "user", content: text}
  end

  defp convert_message({:user_prompt, content}) when is_list(content) do
    %{role: "user", content: convert_content_list(content)}
  end

  defp convert_message({:tool_return, %{call_id: id, result: result}}) do
    %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: id,
          content: Jason.encode!(result)
        }
      ]
    }
  end

  # Previous assistant response
  defp convert_message(%{parts: parts}) do
    text = Messages.extract_text(parts)
    tool_calls = Messages.extract_tool_calls(parts)

    content = []

    # Add text if present
    content =
      if text != "" do
        [%{type: "text", text: text} | content]
      else
        content
      end

    # Add tool uses
    content =
      if not Enum.empty?(tool_calls) do
        tool_content =
          Enum.map(tool_calls, fn call ->
            %{
              type: "tool_use",
              id: call.id,
              name: call.name,
              input: call.arguments
            }
          end)

        tool_content ++ content
      else
        content
      end

    if Enum.empty?(content) do
      nil
    else
      %{role: "assistant", content: Enum.reverse(content)}
    end
  end

  defp convert_message(_), do: nil

  defp convert_content_list(content) do
    Enum.map(content, fn
      {:text, text} -> %{type: "text", text: text}
      {:image_url, url} -> %{type: "image", source: %{type: "url", url: url}}
      text when is_binary(text) -> %{type: "text", text: text}
    end)
  end

  defp parse_response(response, _model) do
    # Handle both atom and string keys (Anthropix returns string keys)
    content = Map.get(response, :content) || Map.get(response, "content")
    usage_data = Map.get(response, :usage) || Map.get(response, "usage")
    model_name = Map.get(response, :model) || Map.get(response, "model")

    parts = parse_content_blocks(content)

    # Build usage - handle string keys
    usage = %Nous.Usage{
      requests: 1,
      input_tokens: Map.get(usage_data, :input_tokens) || Map.get(usage_data, "input_tokens") || 0,
      output_tokens:
        Map.get(usage_data, :output_tokens) || Map.get(usage_data, "output_tokens") || 0,
      total_tokens:
        (Map.get(usage_data, :input_tokens) || Map.get(usage_data, "input_tokens") || 0) +
          (Map.get(usage_data, :output_tokens) || Map.get(usage_data, "output_tokens") || 0)
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
      # Handle both atom and string keys
      type = Map.get(block, :type) || Map.get(block, "type")

      case type do
        "text" ->
          text = Map.get(block, :text) || Map.get(block, "text")
          {:text, text}

        "tool_use" ->
          id = Map.get(block, :id) || Map.get(block, "id")
          name = Map.get(block, :name) || Map.get(block, "name")
          input = Map.get(block, :input) || Map.get(block, "input")
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
    # Parse Anthropix streaming events
    # This is simplified - full implementation would handle all event types
    case event do
      %{type: "content_block_delta", delta: %{text: text}} ->
        {:text_delta, text}

      %{type: "message_stop"} ->
        {:finish, "stop"}

      _ ->
        {:unknown, event}
    end
  end

  defp estimate_message_tokens(message) do
    message
    |> inspect()
    |> String.length()
    |> div(4)
  end
end
