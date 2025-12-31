defmodule Nous.Models.Gemini do
  @moduledoc """
  Google Gemini model implementation.

  Uses pure Req/Finch HTTP clients via `Nous.Providers.Gemini`.
  Supports Gemini models via the Google AI Generative Language API.
  """

  @behaviour Nous.Models.Behaviour

  alias Nous.{Messages, Errors}
  alias Nous.Providers.Gemini, as: GeminiProvider

  require Logger

  @impl true
  def request(model, messages, settings) do
    start_time = System.monotonic_time()

    Logger.debug("""
    Gemini request starting
      Model: #{model.model}
      Messages: #{length(messages)}
      Tools: #{if settings[:tools], do: length(settings[:tools]), else: 0}
    """)

    # Build request parameters
    params = build_params(model, messages, settings)
    opts = build_provider_opts(model)

    result = case GeminiProvider.chat(params, opts) do
      {:ok, response} ->
        {:ok, parse_response(response, model)}

      {:error, error} ->
        Logger.error("""
        Gemini request failed
          Model: #{model.model}
          Error: #{inspect(error)}
        """)

        wrapped_error = Errors.ModelError.exception(
          provider: :gemini,
          message: "Gemini request failed: #{inspect(error)}",
          details: error
        )

        {:error, wrapped_error}
    end

    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    case result do
      {:ok, parsed_response} ->
        Logger.info("""
        Gemini request completed
          Model: #{model.model}
          Duration: #{duration_ms}ms
          Tokens: #{parsed_response.usage.total_tokens} (in: #{parsed_response.usage.input_tokens}, out: #{parsed_response.usage.output_tokens})
        """)

      {:error, _error} ->
        Logger.error("Request failed after #{duration_ms}ms")
    end

    result
  end

  @impl true
  def request_stream(model, messages, settings) do
    Logger.debug("""
    Gemini streaming request starting
      Model: #{model.model}
      Messages: #{length(messages)}
    """)

    params = build_params(model, messages, settings)
    opts = build_provider_opts(model)

    case GeminiProvider.chat_stream(params, opts) do
      {:ok, stream} ->
        Logger.info("Streaming started for Gemini #{model.model}")
        # Transform stream events to our format
        transformed_stream = Stream.map(stream, &parse_stream_event/1)
        {:ok, transformed_stream}

      {:error, error} ->
        Logger.error("""
        Gemini streaming request failed
          Model: #{model.model}
          Error: #{inspect(error)}
        """)

        wrapped_error = Errors.ModelError.exception(
          provider: :gemini,
          message: "Gemini streaming failed: #{inspect(error)}",
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
      api_key: model.api_key,
      timeout: model.receive_timeout,
      finch_name: Application.get_env(:nous, :finch, Nous.Finch)
    ]

    # Add custom base_url if present
    if model.base_url && model.base_url != "" do
      Keyword.put(opts, :base_url, model.base_url)
    else
      opts
    end
  end

  defp build_params(model, messages_list, settings) do
    # Merge model defaults with request settings
    merged_settings = Map.merge(model.default_settings, settings)

    # Convert messages and extract system prompts
    {system, gemini_contents} = convert_messages_to_gemini(messages_list)

    # Build base parameters
    params = %{
      "model" => model.model,
      "contents" => gemini_contents
    }

    # Add system instruction if present
    params = if system do
      Map.put(params, "systemInstruction", %{"parts" => [%{"text" => system}]})
    else
      params
    end

    # Build generation config
    generation_config = %{}
    |> maybe_put("temperature", merged_settings[:temperature])
    |> maybe_put("maxOutputTokens", merged_settings[:max_tokens])
    |> maybe_put("topP", merged_settings[:top_p])
    |> maybe_put("topK", merged_settings[:top_k])

    params = if map_size(generation_config) > 0 do
      Map.put(params, "generationConfig", generation_config)
    else
      params
    end

    # Add tools if present (Gemini function calling format)
    if settings[:tools] && length(settings[:tools]) > 0 do
      gemini_tools = convert_tools_to_gemini(settings[:tools])
      Map.put(params, "tools", gemini_tools)
    else
      params
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp convert_messages_to_gemini(messages_list) do
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
    gemini_contents =
      other_messages
      |> Enum.map(&convert_message/1)
      |> Enum.reject(&is_nil/1)

    {system, gemini_contents}
  end

  defp convert_message({:user_prompt, text}) when is_binary(text) do
    %{"role" => "user", "parts" => [%{"text" => text}]}
  end

  defp convert_message({:user_prompt, content}) when is_list(content) do
    parts = Enum.map(content, fn
      {:text, text} -> %{"text" => text}
      {:image_url, url} -> %{"inlineData" => %{"mimeType" => "image/jpeg", "data" => url}}
      text when is_binary(text) -> %{"text" => text}
      _ -> nil
    end) |> Enum.reject(&is_nil/1)

    %{"role" => "user", "parts" => parts}
  end

  defp convert_message({:tool_return, %{call_id: _id, result: result}}) do
    %{
      "role" => "function",
      "parts" => [
        %{
          "functionResponse" => %{
            "response" => result
          }
        }
      ]
    }
  end

  # Previous assistant response
  defp convert_message(%{parts: parts}) do
    text = Messages.extract_text(parts)
    tool_calls = Messages.extract_tool_calls(parts)

    gemini_parts = []

    gemini_parts = if text != "", do: [%{"text" => text} | gemini_parts], else: gemini_parts

    gemini_parts =
      if not Enum.empty?(tool_calls) do
        Enum.map(tool_calls, fn call ->
          %{
            "functionCall" => %{
              "name" => call.name,
              "args" => call.arguments
            }
          }
        end) ++ gemini_parts
      else
        gemini_parts
      end

    if Enum.empty?(gemini_parts) do
      nil
    else
      %{"role" => "model", "parts" => Enum.reverse(gemini_parts)}
    end
  end

  defp convert_message(_), do: nil

  defp convert_tools_to_gemini(tools) do
    function_declarations = Enum.map(tools, fn tool ->
      %{
        "name" => tool["name"] || tool[:name],
        "description" => tool["description"] || tool[:description],
        "parameters" => tool["parameters"] || tool[:parameters] || %{}
      }
    end)

    [%{"functionDeclarations" => function_declarations}]
  end

  defp parse_response(response, model) do
    # Extract text from Gemini response
    candidates = Map.get(response, "candidates") || []
    candidate = List.first(candidates)

    parts =
      if candidate do
        content = Map.get(candidate, "content") || %{}
        gemini_parts = Map.get(content, "parts") || []

        Enum.map(gemini_parts, &parse_part/1) |> Enum.reject(&is_nil/1)
      else
        []
      end

    # Extract usage
    usage_data = Map.get(response, "usageMetadata") || %{}

    usage = %Nous.Usage{
      requests: 1,
      input_tokens: Map.get(usage_data, "promptTokenCount") || 0,
      output_tokens: Map.get(usage_data, "candidatesTokenCount") || 0,
      total_tokens: Map.get(usage_data, "totalTokenCount") || 0
    }

    %{
      parts: parts,
      usage: usage,
      model_name: model.model,
      timestamp: DateTime.utc_now()
    }
  end

  defp parse_part(part) when is_map(part) do
    cond do
      Map.has_key?(part, "text") ->
        {:text, Map.get(part, "text")}

      Map.has_key?(part, "functionCall") ->
        func_call = Map.get(part, "functionCall")
        name = Map.get(func_call, "name")
        args = Map.get(func_call, "args") || %{}

        {:tool_call, %{
          id: "gemini_#{:rand.uniform(999_999)}",
          name: name,
          arguments: args
        }}

      true ->
        nil
    end
  end

  defp parse_stream_event(event) do
    case event do
      %{"candidates" => [%{"content" => %{"parts" => parts}} | _]} ->
        # Extract text from parts
        text = parts
        |> Enum.filter(&Map.has_key?(&1, "text"))
        |> Enum.map(&Map.get(&1, "text"))
        |> Enum.join("")

        if text != "", do: {:text_delta, text}, else: {:unknown, event}

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
