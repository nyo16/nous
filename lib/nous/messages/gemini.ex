defmodule Nous.Messages.Gemini do
  @moduledoc """
  Gemini format message conversion.

  Handles conversion between internal Message structs and Google Gemini API format.
  """

  alias Nous.{Message, Usage}
  alias Nous.Message.ContentPart

  require Logger

  @doc """
  Convert messages to Gemini format.

  Returns `{system_prompt, contents}` where system prompt is extracted
  and messages are converted to Gemini contents format.

  ## Examples

      iex> messages = [Message.system("Be helpful"), Message.user("Hello")]
      iex> Messages.Gemini.to_format(messages)
      {"Be helpful", [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}]}

  """
  @spec to_format([Message.t()]) :: {String.t() | nil, [map()]}
  def to_format(messages) when is_list(messages) do
    {system_prompt, other_messages} = Message.split_system(messages)
    {system_prompt, Enum.map(other_messages, &message_to_gemini/1)}
  end

  @doc """
  Parse Gemini response into a Message.

  ## Examples

      iex> response = %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]}
      iex> Messages.Gemini.from_response(response)
      %Message{role: :assistant, content: "Hello"}

  """
  @spec from_response(map()) :: Message.t()
  def from_response(response) when is_map(response) do
    candidates = Map.get(response, "candidates", [])
    usage_data = Map.get(response, "usageMetadata", %{})
    model_version = Map.get(response, "modelVersion", "gemini-model")
    prompt_feedback = Map.get(response, "promptFeedback")

    candidate = List.first(candidates) || %{}
    content_data = Map.get(candidate, "content", %{})
    parts_data = Map.get(content_data, "parts", [])
    finish_reason = Map.get(candidate, "finishReason")

    {content_parts, reasoning_content, tool_calls} = parse_content(parts_data)

    consolidated_content = ContentPart.consolidate(content_parts)

    log_if_blocked(
      consolidated_content,
      tool_calls,
      finish_reason,
      prompt_feedback,
      model_version
    )

    metadata =
      %{
        model_name: model_version,
        usage: parse_usage(usage_data),
        timestamp: DateTime.utc_now()
      }
      |> maybe_put_metadata(:finish_reason, finish_reason)
      |> maybe_put_metadata(:prompt_feedback, prompt_feedback)

    attrs = %{
      role: :assistant,
      content: consolidated_content,
      reasoning_content: ContentPart.consolidate(reasoning_content),
      metadata: metadata
    }

    attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

    Message.new!(attrs)
  end

  @doc """
  Convert Gemini format messages to internal Message structs.
  """
  @spec from_messages([map()]) :: [Message.t()]
  def from_messages(gemini_messages) when is_list(gemini_messages) do
    Enum.map(gemini_messages, fn msg ->
      role =
        case Map.get(msg, "role") do
          "user" -> :user
          "model" -> :assistant
          _ -> :user
        end

      parts = Map.get(msg, "parts", [])
      {text_content, reasoning_content, tool_calls} = parse_parts(parts)

      attrs = %{role: role, content: text_content}

      attrs =
        if reasoning_content != "",
          do: Map.put(attrs, :reasoning_content, reasoning_content),
          else: attrs

      attrs = if length(tool_calls) > 0, do: Map.put(attrs, :tool_calls, tool_calls), else: attrs

      Message.new!(attrs)
    end)
  end

  # Private helpers

  defp message_to_gemini(%Message{role: :user, metadata: %{content_parts: content_parts}})
       when is_list(content_parts) do
    gemini_parts = Enum.map(content_parts, &content_part_to_gemini/1)
    %{"role" => "user", "parts" => gemini_parts}
  end

  defp message_to_gemini(%Message{role: :user, content: content}) when is_binary(content) do
    %{"role" => "user", "parts" => [%{"text" => content}]}
  end

  defp message_to_gemini(%Message{
         role: :assistant,
         content: content,
         reasoning_content: reasoning,
         tool_calls: tool_calls
       }) do
    parts = []

    parts = if content && content != "", do: [%{"text" => content} | parts], else: parts

    parts =
      if reasoning && reasoning != "",
        do: [%{"text" => reasoning, "thought" => true} | parts],
        else: parts

    parts =
      if length(tool_calls) > 0 do
        tool_parts =
          Enum.map(tool_calls, fn call ->
            %{
              "functionCall" => %{
                "name" => Map.get(call, "name") || Map.get(call, :name),
                "args" => Map.get(call, "arguments") || Map.get(call, :arguments, %{})
              }
            }
            |> maybe_put_signature_on_part(extract_thought_signature(call))
          end)

        tool_parts ++ parts
      else
        parts
      end

    %{"role" => "model", "parts" => Enum.reverse(parts)}
  end

  defp message_to_gemini(%Message{
         role: :tool,
         content: content,
         tool_call_id: tool_call_id,
         name: name
       }) do
    # Gemini's API requires functionResponse.name to match the original
    # functionCall.name. Prefer the explicit :name field; fall back to
    # tool_call_id only for legacy callers that didn't set it.
    response =
      case JSON.decode(content) do
        {:ok, decoded} -> decoded
        # Treat as plain text
        {:error, _} -> %{"result" => content}
      end

    %{
      "role" => "user",
      "parts" => [
        %{
          "functionResponse" => %{
            "name" => name || tool_call_id,
            "response" => response
          }
        }
      ]
    }
  end

  defp content_part_to_gemini(%ContentPart{type: :text, content: text}) do
    %{"text" => text}
  end

  defp content_part_to_gemini(%ContentPart{type: :image_url, content: url}) do
    cond do
      ContentPart.data_url?(url) ->
        case ContentPart.parse_data_url(url) do
          {:ok, mime_type, base64_data} ->
            %{"inlineData" => %{"mimeType" => mime_type, "data" => base64_data}}

          {:error, _} ->
            %{"text" => "[Image: invalid data URL]"}
        end

      ContentPart.http_url?(url) ->
        mime_type =
          url
          |> URI.parse()
          |> Map.get(:path, "")
          |> ContentPart.detect_mime_type()
          |> then(fn
            "application/octet-stream" -> "image/jpeg"
            type -> type
          end)

        %{"fileData" => %{"mimeType" => mime_type, "fileUri" => url}}

      true ->
        %{"text" => "[Image: #{url}]"}
    end
  end

  defp content_part_to_gemini(%ContentPart{type: :image, content: data, options: opts}) do
    %{
      "inlineData" => %{
        "mimeType" => Map.get(opts, :media_type, "image/png"),
        "data" => data
      }
    }
  end

  defp content_part_to_gemini(%ContentPart{} = part) do
    # Fallback: convert to text representation
    %{"text" => ContentPart.to_text([part])}
  end

  # Two parsers exist intentionally:
  # - parse_content/1 is for API responses (from_response/1) and returns
  #   ContentPart structs that are later consolidated; whitespace-only text
  #   parts are dropped because Gemini emits them between tool calls.
  # - parse_parts/1 is for round-tripping Gemini-format messages back into
  #   our Message struct (from_messages/1) and returns plain joined strings.
  # Do not consolidate these: from_response needs structured parts so the
  # downstream tool-call/text ordering is preserved; from_messages flattens
  # to text because the on-disk format is already user-edited.
  defp parse_content(parts_data) when is_list(parts_data) do
    {content_parts, reasoning_content, tool_calls} =
      Enum.reduce(parts_data, {[], [], []}, fn item, {parts, reasoning, tools} ->
        case item do
          %{"text" => text} when is_binary(text) ->
            cond do
              # Drop whitespace-only text. Gemini emits these between tool
              # calls and after blocked generations. Carrying them forward
              # produces empty ContentParts that add no value.
              String.trim(text) == "" ->
                {parts, reasoning, tools}

              Map.get(item, "thought") ->
                {parts, [ContentPart.thinking(text) | reasoning], tools}

              true ->
                {[ContentPart.text(text) | parts], reasoning, tools}
            end

          %{"functionCall" => %{"name" => name} = function_call} when is_binary(name) ->
            tool_call =
              %{
                "id" => generate_tool_call_id(),
                "name" => name,
                "arguments" => Map.get(function_call, "args", %{})
              }
              |> maybe_put_thought_signature(Map.get(item, "thoughtSignature"))

            {parts, reasoning, [tool_call | tools]}

          _ ->
            {parts, reasoning, tools}
        end
      end)

    {Enum.reverse(content_parts), Enum.reverse(reasoning_content), Enum.reverse(tool_calls)}
  end

  defp parse_parts(parts) when is_list(parts) do
    {text_parts, reasoning_parts, tool_calls} =
      Enum.reduce(parts, {[], [], []}, fn part, {texts, reasoning, tools} ->
        cond do
          Map.has_key?(part, "text") ->
            text = Map.get(part, "text", "")

            if Map.get(part, "thought") do
              {texts, [text | reasoning], tools}
            else
              {[text | texts], reasoning, tools}
            end

          Map.has_key?(part, "functionCall") ->
            function_call = Map.get(part, "functionCall")

            tool_call =
              %{
                "id" => generate_tool_call_id(),
                "name" => Map.get(function_call, "name"),
                "arguments" => Map.get(function_call, "args", %{})
              }
              |> maybe_put_thought_signature(Map.get(part, "thoughtSignature"))

            {texts, reasoning, [tool_call | tools]}

          true ->
            {texts, reasoning, tools}
        end
      end)

    text_content = text_parts |> Enum.reverse() |> Enum.join(" ") |> String.trim()
    reasoning_content = reasoning_parts |> Enum.reverse() |> Enum.join(" ") |> String.trim()
    # Add space after text if there are tool calls
    text_content =
      if text_content != "" and length(tool_calls) > 0 do
        text_content <> " "
      else
        text_content
      end

    {text_content, reasoning_content, Enum.reverse(tool_calls)}
  end

  @doc """
  Build the `generateContent` request params shared by the Gemini and
  Vertex AI providers (both speak the same wire format).

  Expects already-merged settings (`model.default_settings` merged with the
  per-request settings). Handles system-instruction extraction, the
  `generationConfig` mapping, tools, safety settings, tool config, and cached
  content. Vendor `:extra_body` merging stays provider-side, where the
  `Nous.Provider` macro enforces the blocked-key policy.
  """
  @spec build_request_params(Nous.Model.t(), [Message.t()], map()) :: map()
  def build_request_params(model, messages, merged_settings) do
    {system_prompt, contents} = to_format(messages)

    params = %{"model" => model.model, "contents" => contents}

    params =
      if system_prompt do
        Map.put(params, "systemInstruction", %{"parts" => [%{"text" => system_prompt}]})
      else
        params
      end

    # Map generic settings to Gemini's generationConfig
    generation_config =
      %{}
      |> maybe_put("temperature", merged_settings[:temperature])
      |> maybe_put("maxOutputTokens", merged_settings[:max_tokens])
      |> maybe_put("topP", merged_settings[:top_p])
      |> maybe_put("topK", merged_settings[:top_k])
      |> maybe_put("seed", merged_settings[:seed])
      |> maybe_put("candidateCount", merged_settings[:candidate_count])
      |> maybe_put("presencePenalty", merged_settings[:presence_penalty])
      |> maybe_put("frequencyPenalty", merged_settings[:frequency_penalty])
      |> maybe_put("responseModalities", merged_settings[:response_modalities])
      |> maybe_put("stopSequences", merged_settings[:stop_sequences] || merged_settings[:stop])
      |> maybe_put(
        "thinkingConfig",
        normalize_thinking_config(merged_settings[:thinking_config])
      )
      |> Map.merge(json_config_for_settings(merged_settings))

    # Merge any explicit generationConfig from settings
    generation_config =
      Map.merge(generation_config, merged_settings[:generationConfig] || %{})

    params =
      if map_size(generation_config) > 0 do
        Map.put(params, "generationConfig", generation_config)
      else
        params
      end

    params
    |> maybe_put(
      "tools",
      build_tools(merged_settings[:tools] || [], merged_settings[:native_tools])
    )
    |> maybe_put(
      "safetySettings",
      normalize_safety_settings(merged_settings[:safety_settings])
    )
    |> maybe_put("toolConfig", resolve_tool_config(merged_settings))
    |> maybe_put("cachedContent", merged_settings[:cached_content])
  end

  defp resolve_tool_config(settings) do
    settings[:tool_config] || normalize_tool_choice(settings[:tool_choice])
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  @doc """
  Derive Gemini's `responseMimeType`/`responseSchema` pair from generic settings.

  Honors three settings keys, in priority order:

  - `:json_schema` (map) — forces JSON mime type and sets the schema.
  - `:response_format` (map) — accepts `%{type: :json_schema, schema: schema}` or
    `%{type: :json_object}` for cross-provider consistency.
  - `:json_response` (boolean) — forces JSON mime type without a schema.

  Returns a map with `"responseMimeType"` and (optionally) `"responseSchema"`,
  or `%{}` when none apply.
  """
  @spec json_config_for_settings(map() | keyword()) :: map()
  def json_config_for_settings(settings) do
    schema = get_setting(settings, :json_schema)
    response_format = get_setting(settings, :response_format)
    json_response = get_setting(settings, :json_response)

    cond do
      is_map(schema) ->
        %{"responseMimeType" => "application/json", "responseSchema" => schema}

      response_format_schema(response_format) ->
        %{
          "responseMimeType" => "application/json",
          "responseSchema" => response_format_schema(response_format)
        }

      json_object_response_format?(response_format) ->
        %{"responseMimeType" => "application/json"}

      json_response == true ->
        %{"responseMimeType" => "application/json"}

      true ->
        %{}
    end
  end

  defp get_setting(settings, key) when is_map(settings),
    do: Map.get(settings, key) || Map.get(settings, Atom.to_string(key))

  defp get_setting(settings, key) when is_list(settings), do: Keyword.get(settings, key)
  defp get_setting(_, _), do: nil

  defp response_format_schema(%{type: :json_schema, schema: %{} = schema}), do: schema
  defp response_format_schema(%{"type" => "json_schema", "schema" => %{} = schema}), do: schema
  defp response_format_schema(_), do: nil

  defp json_object_response_format?(%{type: :json_object}), do: true
  defp json_object_response_format?(%{"type" => "json_object"}), do: true
  defp json_object_response_format?(_), do: false

  @doc """
  Build Vertex's `tools` array from function declarations and native tools.

  - `function_declarations` — list of Gemini-shaped function declarations
    (already converted via `Nous.ToolSchema.to_gemini/1`). May be empty.
  - `native_tools` — list of native Vertex tools, each one of:
      * `:google_search`
      * `:url_context`
      * `:code_execution`
      * `{atom_or_string, %{config}}` — for tools that take configuration
      * a raw map — passed through (e.g. `%{"googleSearch" => %{}}`)

  Returns `nil` when both lists are empty so callers can `maybe_put`.
  """
  @spec build_tools([map()], [atom() | tuple() | map()] | nil) :: [map()] | nil
  def build_tools(function_declarations, native_tools)

  def build_tools([], native_tools) when native_tools in [nil, []], do: nil

  def build_tools(function_declarations, native_tools) do
    declarations_entry =
      case function_declarations do
        [] -> []
        list -> [%{"functionDeclarations" => list}]
      end

    native_entries = native_tools |> List.wrap() |> Enum.map(&native_tool_entry/1)

    declarations_entry ++ native_entries
  end

  defp native_tool_entry(:google_search), do: %{"googleSearch" => %{}}
  defp native_tool_entry(:url_context), do: %{"urlContext" => %{}}
  defp native_tool_entry(:code_execution), do: %{"codeExecution" => %{}}

  defp native_tool_entry({name, config}) when is_atom(name) and is_map(config),
    do: %{atom_to_camel(name) => config}

  defp native_tool_entry({name, config}) when is_binary(name) and is_map(config),
    do: %{name => config}

  defp native_tool_entry(map) when is_map(map), do: map

  defp atom_to_camel(:google_search), do: "googleSearch"
  defp atom_to_camel(:url_context), do: "urlContext"
  defp atom_to_camel(:code_execution), do: "codeExecution"
  defp atom_to_camel(atom), do: atom |> Atom.to_string() |> camelize()

  defp camelize(string) do
    [head | rest] = String.split(string, "_")
    [head | Enum.map(rest, &String.capitalize/1)] |> Enum.join()
  end

  @doc """
  Normalize a list of safety settings into Vertex's `safetySettings` shape.

  Accepts atom-keyed (`%{category: ..., threshold: ...}`) or string-keyed
  (`%{"category" => ..., "threshold" => ...}`) entries. Passes unknown keys
  through so newer Vertex fields (e.g. `"method"`) work without a library
  bump. Returns `nil` for nil input.
  """
  @spec normalize_safety_settings([map()] | nil) :: [map()] | nil
  def normalize_safety_settings(nil), do: nil

  def normalize_safety_settings(settings) when is_list(settings) do
    Enum.map(settings, fn entry ->
      Map.new(entry, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
    end)
  end

  @doc """
  Normalize a `:tool_choice` setting into Vertex's `toolConfig` shape.

  Accepts:

    * `:auto` → mode `AUTO`
    * `:any` / `:required` → mode `ANY` (model must call a function)
    * `:none` → mode `NONE`
    * `{:any, ["name_a", ...]}` → mode `ANY` with `allowedFunctionNames`
    * a raw map (passed through as-is)
    * `nil` (returns nil)
  """
  @spec normalize_tool_choice(atom() | tuple() | map() | nil) :: map() | nil
  def normalize_tool_choice(nil), do: nil
  def normalize_tool_choice(:auto), do: function_calling_mode("AUTO")
  def normalize_tool_choice(:any), do: function_calling_mode("ANY")
  def normalize_tool_choice(:required), do: function_calling_mode("ANY")
  def normalize_tool_choice(:none), do: function_calling_mode("NONE")

  def normalize_tool_choice({:any, names}) when is_list(names) do
    %{
      "functionCallingConfig" => %{"mode" => "ANY", "allowedFunctionNames" => names}
    }
  end

  def normalize_tool_choice(map) when is_map(map), do: map

  defp function_calling_mode(mode) do
    %{"functionCallingConfig" => %{"mode" => mode}}
  end

  @doc """
  Normalize a Nous-shaped `thinking_config` into Gemini's `thinkingConfig`.

  Accepts either the Elixir shape (`%{thinking_budget: 1024, include_thoughts:
  true}`) or the native Vertex shape (`%{"thinkingBudget" => 1024,
  "includeThoughts" => true}`). Returns `nil` when the input is nil.

  Unrecognized keys are passed through unchanged so newer Vertex fields work
  without a library bump.
  """
  @spec normalize_thinking_config(map() | nil) :: map() | nil
  def normalize_thinking_config(nil), do: nil

  def normalize_thinking_config(config) when is_map(config) do
    Map.new(config, fn
      {:thinking_budget, v} -> {"thinkingBudget", v}
      {:include_thoughts, v} -> {"includeThoughts", v}
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Parse a Gemini-format `usageMetadata` map into a `%Nous.Usage{}` struct.

  Used by both the non-streaming response parser and the streaming normalizer.
  """
  @spec parse_usage(map() | nil) :: Usage.t()
  def parse_usage(usage_data) when is_map(usage_data) do
    %Usage{
      requests: 1,
      input_tokens: Map.get(usage_data, "promptTokenCount", 0),
      output_tokens: Map.get(usage_data, "candidatesTokenCount", 0),
      total_tokens: Map.get(usage_data, "totalTokenCount", 0),
      cache_read_input_tokens: Map.get(usage_data, "cachedContentTokenCount", 0)
    }
  end

  def parse_usage(_), do: %Usage{}

  # Gemini doesn't provide tool call IDs, so we synthesize one. 64 bits of
  # entropy keeps collision probability negligible across high-volume jobs.
  defp generate_tool_call_id do
    "gemini_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  # Parse path: store Vertex's thoughtSignature inside the tool_call's
  # internal metadata bag so it survives until the next turn.
  defp maybe_put_thought_signature(tool_call, nil), do: tool_call
  defp maybe_put_thought_signature(tool_call, ""), do: tool_call

  defp maybe_put_thought_signature(tool_call, signature) when is_binary(signature) do
    metadata =
      tool_call
      |> Map.get("metadata", %{})
      |> Map.put("thought_signature", signature)

    Map.put(tool_call, "metadata", metadata)
  end

  # Encode path: emit thoughtSignature at the top level of the Gemini part,
  # as required by the Vertex API shape.
  defp maybe_put_signature_on_part(part, nil), do: part
  defp maybe_put_signature_on_part(part, ""), do: part

  defp maybe_put_signature_on_part(part, signature) when is_binary(signature),
    do: Map.put(part, "thoughtSignature", signature)

  # Read the signature back from a tool_call's metadata, supporting both
  # string-keyed and atom-keyed metadata bags so callers building tool_calls
  # by hand don't have to think about it.
  defp extract_thought_signature(call) do
    metadata = Map.get(call, "metadata") || Map.get(call, :metadata) || %{}

    Map.get(metadata, "thought_signature") || Map.get(metadata, :thought_signature)
  end

  # Surface non-STOP finish reasons (SAFETY, RECITATION, MAX_TOKENS, etc.)
  # and prompt blocks so they don't manifest as silent empty responses.
  defp log_if_blocked(content, tool_calls, finish_reason, prompt_feedback, model_version) do
    # consolidate/1 never returns nil — "" is the empty case (checked by dialyzer).
    empty? = content == "" and tool_calls == []
    block_reason = prompt_feedback && Map.get(prompt_feedback, "blockReason")
    interesting_finish? = finish_reason not in [nil, "STOP", "FINISH_REASON_UNSPECIFIED"]

    if empty? and (interesting_finish? or block_reason) do
      Logger.warning(
        "Gemini/Vertex returned empty content. " <>
          "model=#{model_version} finishReason=#{inspect(finish_reason)} " <>
          "promptFeedback=#{inspect(prompt_feedback)}"
      )
    end
  end
end
