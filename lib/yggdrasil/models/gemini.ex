defmodule Yggdrasil.Models.Gemini do
  @moduledoc """
  Google Gemini implementation using the gemini_ex library.

  Uses Google's native Gemini API for access to Gemini models.
  """

  @behaviour Yggdrasil.Models.Behaviour

  alias Yggdrasil.{Messages, Errors}

  require Logger

  @impl true
  def request(model, messages, settings) do
    start_time = System.monotonic_time()

    # Extract just the text content for simple generation
    {system, gemini_contents} = extract_system_and_messages(messages)

    Logger.debug("""
    Gemini request starting
      Model: #{model.model}
      Messages: #{length(messages)}
      System prompt: #{if system, do: "present", else: "none"}
      Tools: #{if settings[:tools], do: length(settings[:tools]), else: 0}
    """)

    # For now, just use the last user message as simple text
    # gemini_ex has strict validations, so keep it simple
    content_text = extract_simple_text(gemini_contents)

    Logger.debug("Gemini content text: #{String.slice(content_text, 0, 100)}...")

    # Simple generation with just text and model
    result = case Gemini.generate(content_text, model: model.model) do
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
  def request_stream(_model, _messages, _settings) do
    Logger.warning("Streaming not yet implemented for Gemini")
    # Streaming support - placeholder for now
    {:error, :streaming_not_implemented}
  end

  @impl true
  def count_tokens(messages) do
    # Rough estimation
    messages
    |> Enum.map(&estimate_message_tokens/1)
    |> Enum.sum()
  end

  # Private functions

  defp extract_system_and_messages(messages) do
    {system_prompts, other_messages} =
      Enum.split_with(messages, &match?({:system_prompt, _}, &1))

    system =
      if not Enum.empty?(system_prompts) do
        system_prompts
        |> Enum.map(fn {:system_prompt, text} -> text end)
        |> Enum.join("\n\n")
      else
        nil
      end

    gemini_contents = Enum.map(other_messages, &convert_message/1) |> Enum.reject(&is_nil/1)

    {system, gemini_contents}
  end

  defp convert_message({:user_prompt, text}) when is_binary(text) do
    %{
      role: "user",
      parts: [%{text: text}]
    }
  end

  defp convert_message({:user_prompt, content}) when is_list(content) do
    parts = Enum.map(content, fn
      {:text, text} -> %{text: text}
      text when is_binary(text) -> %{text: text}
      _ -> nil
    end) |> Enum.reject(&is_nil/1)

    %{role: "user", parts: parts}
  end

  defp convert_message(%{parts: parts}) do
    # Previous assistant response
    text = Messages.extract_text(parts)
    tool_calls = Messages.extract_tool_calls(parts)

    gemini_parts = []

    gemini_parts = if text != "", do: [%{text: text} | gemini_parts], else: gemini_parts

    gemini_parts =
      if not Enum.empty?(tool_calls) do
        Enum.map(tool_calls, fn call ->
          %{
            functionCall: %{
              name: call.name,
              args: call.arguments
            }
          }
        end) ++ gemini_parts
      else
        gemini_parts
      end

    if Enum.empty?(gemini_parts) do
      nil
    else
      %{role: "model", parts: Enum.reverse(gemini_parts)}
    end
  end

  defp convert_message({:tool_return, %{call_id: _id, result: result}}) do
    %{
      role: "function",
      parts: [
        %{
          functionResponse: %{
            response: result
          }
        }
      ]
    }
  end

  defp convert_message(_), do: nil

  defp parse_response(response, model) do
    # Extract text from Gemini response
    candidates = Map.get(response, :candidates) || Map.get(response, "candidates") || []
    candidate = List.first(candidates)

    parts =
      if candidate do
        content = Map.get(candidate, :content) || Map.get(candidate, "content")
        gemini_parts = Map.get(content, :parts) || Map.get(content, "parts") || []

        Enum.map(gemini_parts, &parse_part/1) |> Enum.reject(&is_nil/1)
      else
        []
      end

    # Extract usage
    usage_data = Map.get(response, :usageMetadata) || Map.get(response, "usageMetadata") || %{}

    usage = %Yggdrasil.Usage{
      requests: 1,
      input_tokens:
        Map.get(usage_data, :promptTokenCount) || Map.get(usage_data, "promptTokenCount") || 0,
      output_tokens:
        Map.get(usage_data, :candidatesTokenCount) ||
          Map.get(usage_data, "candidatesTokenCount") || 0,
      total_tokens:
        Map.get(usage_data, :totalTokenCount) || Map.get(usage_data, "totalTokenCount") || 0
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
      Map.has_key?(part, :text) or Map.has_key?(part, "text") ->
        text = Map.get(part, :text) || Map.get(part, "text")
        {:text, text}

      Map.has_key?(part, :functionCall) or Map.has_key?(part, "functionCall") ->
        func_call = Map.get(part, :functionCall) || Map.get(part, "functionCall")
        name = Map.get(func_call, :name) || Map.get(func_call, "name")
        args = Map.get(func_call, :args) || Map.get(func_call, "args") || %{}

        {:tool_call,
         %{
           id: "gemini_#{:rand.uniform(999_999)}",
           name: name,
           arguments: args
         }}

      true ->
        nil
    end
  end

  defp extract_simple_text(gemini_contents) when is_list(gemini_contents) do
    # Extract text from the last user message
    last_msg = List.last(gemini_contents)

    if last_msg && Map.has_key?(last_msg, :parts) do
      parts = last_msg.parts
      text_part = Enum.find(parts, &Map.has_key?(&1, :text))

      if text_part, do: text_part.text, else: "Hello"
    else
      "Hello"
    end
  end

  defp extract_simple_text(_), do: "Hello"

  defp estimate_message_tokens(message) do
    message
    |> inspect()
    |> String.length()
    |> div(4)
  end
end
