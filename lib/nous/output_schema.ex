defmodule Nous.OutputSchema do
  @moduledoc """
  Structured output support for Nous agents.

  Converts Ecto schemas and other type specifications into JSON Schema,
  generates provider-specific settings, and validates LLM responses against
  the declared output type.

  Inspired by [instructor_ex](https://github.com/thmsmlr/instructor_ex).

  ## Output Type Variants

  - `:string` — raw text (default, no processing)
  - `module()` — Ecto schema → JSON schema + changeset validation
  - `%{atom() => atom()}` — schemaless Ecto types (e.g. `%{name: :string}`)
  - `%{String.t() => map()}` — raw JSON schema (string keys, passed through)
  - `{:regex, pattern}` — regex-constrained output (vLLM/SGLang)
  - `{:grammar, ebnf}` — grammar-constrained output (vLLM)
  - `{:choice, choices}` — choice-constrained output (vLLM/SGLang)

  ## Modes

  | Mode | Mechanism | Providers |
  |------|-----------|-----------|
  | `:auto` | Pick best for provider | All |
  | `:tool_call` | Synthetic tool + tool_choice | All (native for Anthropic) |
  | `:json_schema` | `response_format: {type: "json_schema", ...}` | OpenAI, vLLM, SGLang |
  | `:json` | `response_format: {type: "json_object"}` | OpenAI-compatible |
  | `:md_json` | Prompt + markdown fence + stop token | All (fallback) |
  """

  alias Nous.Errors

  # Re-export the use macro so `use Nous.OutputSchema` works
  defmacro __using__(opts) do
    quote do
      use Nous.OutputSchema.UseMacro, unquote(opts)
    end
  end

  # -------------------------------------------------------------------
  # to_json_schema/1 — Convert output_type to JSON Schema map
  # -------------------------------------------------------------------

  @doc """
  Convert an output type specification to a JSON Schema map.

  Returns `nil` for types that don't produce JSON schema (`:string`, tuples).
  """
  @spec to_json_schema(Nous.Types.output_type()) :: map() | nil
  def to_json_schema(:string), do: nil
  def to_json_schema({:regex, _}), do: nil
  def to_json_schema({:grammar, _}), do: nil
  def to_json_schema({:choice, _}), do: nil

  def to_json_schema(output_type) when is_atom(output_type) do
    # Ecto schema module
    schema_to_json_schema(output_type)
  end

  def to_json_schema(output_type) when is_map(output_type) do
    case classify_map_type(output_type) do
      :schemaless -> schemaless_to_json_schema(output_type)
      :raw_json_schema -> output_type
    end
  end

  # -------------------------------------------------------------------
  # to_provider_settings/3 — Convert to provider-specific model settings
  # -------------------------------------------------------------------

  @doc """
  Generate provider-specific model settings for structured output.

  Returns a map of settings to merge into the model request. The map may
  contain special keys prefixed with `__structured_output` that the
  AgentRunner handles separately (e.g. synthetic tool injection).

  ## Options

  - `:mode` — output mode (`:auto`, `:tool_call`, `:json_schema`, `:json`, `:md_json`)
  - `:has_other_tools` — whether the agent has non-synthetic tools
  """
  @spec to_provider_settings(Nous.Types.output_type(), atom(), keyword()) :: map()
  def to_provider_settings(output_type, provider, opts \\ [])

  def to_provider_settings(:string, _provider, _opts), do: %{}

  def to_provider_settings(output_type, provider, opts) do
    mode = resolve_mode(Keyword.get(opts, :mode, :auto), provider)

    case output_type do
      {:regex, pattern} ->
        guided_settings(:regex, pattern, provider)

      {:grammar, grammar} ->
        guided_settings(:grammar, grammar, provider)

      {:choice, choices} ->
        guided_settings(:choice, choices, provider)

      _ ->
        json_schema = to_json_schema(output_type)
        schema_name = schema_name(output_type)
        mode_settings(mode, json_schema, schema_name, provider, opts)
    end
  end

  # -------------------------------------------------------------------
  # parse_and_validate/2 — Parse text → validate → typed output
  # -------------------------------------------------------------------

  @doc """
  Parse raw LLM response text and validate it against the output type.

  Returns `{:ok, result}` where result is a struct, map, or string,
  or `{:error, %ValidationError{}}` on failure.
  """
  @spec parse_and_validate(String.t(), Nous.Types.output_type()) ::
          {:ok, any()} | {:error, Errors.ValidationError.t()}
  def parse_and_validate(text, :string), do: {:ok, text}

  def parse_and_validate(text, {:choice, choices}) do
    trimmed = String.trim(text)

    if trimmed in choices do
      {:ok, trimmed}
    else
      {:error,
       Errors.ValidationError.exception(
         message: "Response #{inspect(trimmed)} is not one of: #{inspect(choices)}",
         errors: [choice: {"not in allowed choices", []}],
         output_type: {:choice, choices}
       )}
    end
  end

  def parse_and_validate(text, {:regex, pattern}) do
    trimmed = String.trim(text)

    case Regex.compile(pattern) do
      {:ok, regex} ->
        if Regex.match?(regex, trimmed) do
          {:ok, trimmed}
        else
          {:error,
           Errors.ValidationError.exception(
             message: "Response does not match pattern: #{pattern}",
             errors: [regex: {"does not match pattern", []}],
             output_type: {:regex, pattern}
           )}
        end

      {:error, reason} ->
        {:error,
         Errors.ValidationError.exception(
           message: "Invalid regex pattern: #{inspect(reason)}",
           errors: [regex: {"invalid pattern", []}],
           output_type: {:regex, pattern}
         )}
    end
  end

  def parse_and_validate(text, {:grammar, _grammar}) do
    # Grammar-constrained output is validated by the provider; we just return as-is
    {:ok, String.trim(text)}
  end

  def parse_and_validate(text, output_type) do
    # For md_json mode, extract JSON from markdown code fence
    text = extract_json_from_markdown(text)

    case Jason.decode(text) do
      {:ok, parsed} ->
        cast_and_validate(parsed, output_type)

      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         Errors.ValidationError.exception(
           message: "Failed to parse JSON: #{Exception.message(error)}",
           errors: [json: {"parse error", [detail: Exception.message(error)]}],
           output_type: output_type
         )}
    end
  end

  # -------------------------------------------------------------------
  # cast_and_validate/2 — Cast parsed JSON into typed struct/map
  # -------------------------------------------------------------------

  @doc """
  Cast parsed JSON data and validate it against the output type.

  For Ecto schemas, uses `Ecto.Changeset.cast/3` + `validate_changeset/1`.
  For schemaless types, uses `Ecto.Changeset.cast/4` with `{data, types}`.
  For raw JSON schema maps, returns the parsed data as-is.
  """
  @spec cast_and_validate(map(), Nous.Types.output_type()) ::
          {:ok, any()} | {:error, Errors.ValidationError.t()}
  def cast_and_validate(parsed, output_type) when is_atom(output_type) do
    # Ecto schema module
    cast_schema(parsed, output_type)
  end

  def cast_and_validate(parsed, output_type) when is_map(output_type) do
    case classify_map_type(output_type) do
      :schemaless -> cast_schemaless(parsed, output_type)
      :raw_json_schema -> {:ok, parsed}
    end
  end

  # -------------------------------------------------------------------
  # extract_response_text/2 — Extract text from provider response
  # -------------------------------------------------------------------

  @doc """
  Extract the response text from a provider response message.

  For `:tool_call` mode on Anthropic, extracts the `__structured_output__`
  tool call arguments. For all other modes, extracts the text content.
  """
  @spec extract_response_text(Nous.Message.t(), atom()) :: String.t()
  def extract_response_text(%Nous.Message{} = msg, _provider) do
    # Check for synthetic tool call first (tool_call mode)
    case find_synthetic_tool_call(msg) do
      nil ->
        Nous.Messages.extract_text(msg)

      tool_call ->
        args = tool_call[:arguments] || tool_call["arguments"] || %{}
        Jason.encode!(args)
    end
  end

  # -------------------------------------------------------------------
  # format_errors/1 — Format validation errors for LLM retry message
  # -------------------------------------------------------------------

  @doc """
  Format a validation error into a human-readable string for LLM retry.
  """
  @spec format_errors(Errors.ValidationError.t()) :: String.t()
  def format_errors(%Errors.ValidationError{errors: nil, message: message}), do: message

  def format_errors(%Errors.ValidationError{errors: errors}) when is_list(errors) do
    Enum.map_join(errors, "\n", fn
      {field, {msg, opts}} ->
        detail =
          Enum.map_join(opts, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)

        if detail == "" do
          "#{field}: #{msg}"
        else
          "#{field}: #{msg} (#{detail})"
        end

      {field, msg} when is_binary(msg) ->
        "#{field}: #{msg}"
    end)
  end

  def format_errors(%Errors.ValidationError{message: message}), do: message

  # -------------------------------------------------------------------
  # system_prompt_suffix/2 — Schema instructions for system prompt
  # -------------------------------------------------------------------

  @doc """
  Generate system prompt suffix describing the expected output schema.
  """
  @spec system_prompt_suffix(Nous.Types.output_type(), keyword()) :: String.t() | nil
  def system_prompt_suffix(:string, _opts), do: nil
  def system_prompt_suffix({:regex, _}, _opts), do: nil
  def system_prompt_suffix({:grammar, _}, _opts), do: nil

  def system_prompt_suffix({:choice, choices}, _opts) do
    "You must respond with exactly one of: #{Enum.join(choices, ", ")}"
  end

  def system_prompt_suffix(output_type, opts) do
    json_schema = to_json_schema(output_type)
    mode = Keyword.get(opts, :mode, :auto)

    schema_json = if json_schema, do: Jason.encode!(json_schema, pretty: true), else: nil

    cond do
      mode == :md_json && schema_json ->
        """
        You must respond with a JSON object matching this schema, wrapped in a markdown code fence:

        ```json
        #{schema_json}
        ```

        Your response must be ONLY a markdown JSON code block. Do not include any other text.
        """

      schema_json ->
        """
        You must respond with a JSON object matching this schema:

        #{schema_json}

        Respond with valid JSON only. Do not include any other text, markdown formatting, or code fences.
        """

      true ->
        nil
    end
  end

  # ===================================================================
  # Private Implementation
  # ===================================================================

  # --- Schema → JSON Schema conversion ---

  defp schema_to_json_schema(module) do
    fields = module.__schema__(:fields)
    embeds = try_schema_call(module, :embeds, [])
    field_types = Map.new(fields, fn f -> {f, module.__schema__(:type, f)} end)

    # Build properties, excluding :id if it's the default primary key
    {properties, required} =
      fields
      |> Enum.reject(&(&1 == :id))
      |> Enum.reduce({%{}, []}, fn field, {props, req} ->
        type = Map.get(field_types, field)
        json_type = ecto_type_to_json_schema(type, module, field)
        {Map.put(props, Atom.to_string(field), json_type), [Atom.to_string(field) | req]}
      end)

    # Handle embeds
    {properties, required, defs} =
      Enum.reduce(embeds, {properties, required, %{}}, fn embed_field, {props, req, defs_acc} ->
        embed_info = get_embed_info(module, embed_field)

        case embed_info do
          {:one, embed_module} ->
            embed_schema = schema_to_json_schema(embed_module)
            title = schema_title(embed_module)
            new_defs = Map.put(defs_acc, title, embed_schema)
            ref = %{"$ref" => "#/$defs/#{title}"}

            {Map.put(props, Atom.to_string(embed_field), ref),
             [Atom.to_string(embed_field) | req], new_defs}

          {:many, embed_module} ->
            embed_schema = schema_to_json_schema(embed_module)
            title = schema_title(embed_module)
            new_defs = Map.put(defs_acc, title, embed_schema)
            ref = %{"type" => "array", "items" => %{"$ref" => "#/$defs/#{title}"}}

            {Map.put(props, Atom.to_string(embed_field), ref),
             [Atom.to_string(embed_field) | req], new_defs}

          nil ->
            {props, req, defs_acc}
        end
      end)

    base = %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.reverse(required),
      "additionalProperties" => false
    }

    # Add $defs if any embeds
    base = if map_size(defs) > 0, do: Map.put(base, "$defs", defs), else: base

    # Add description from @llm_doc if available
    llm_doc = try_llm_doc(module)
    if llm_doc, do: Map.put(base, "description", llm_doc), else: base
  end

  defp get_embed_info(module, field) do
    case module.__schema__(:embed, field) do
      %{cardinality: :one, related: related} -> {:one, related}
      %{cardinality: :many, related: related} -> {:many, related}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp try_schema_call(module, fun, default) do
    if function_exported?(module, :__schema__, 1) do
      module.__schema__(fun)
    else
      default
    end
  rescue
    _ -> default
  end

  defp try_llm_doc(module) do
    if function_exported?(module, :__llm_doc__, 0) do
      try do
        module.__llm_doc__()
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  defp schema_title(module) do
    module
    |> Module.split()
    |> List.last()
  end

  defp ecto_type_to_json_schema(:string, _module, _field), do: %{"type" => "string"}
  defp ecto_type_to_json_schema(:integer, _module, _field), do: %{"type" => "integer"}

  defp ecto_type_to_json_schema(:float, _module, _field),
    do: %{"type" => "number", "format" => "float"}

  defp ecto_type_to_json_schema(:boolean, _module, _field), do: %{"type" => "boolean"}
  defp ecto_type_to_json_schema(:decimal, _module, _field), do: %{"type" => "number"}

  defp ecto_type_to_json_schema(:date, _module, _field),
    do: %{"type" => "string", "format" => "date"}

  defp ecto_type_to_json_schema(:utc_datetime, _module, _field),
    do: %{"type" => "string", "format" => "date-time"}

  defp ecto_type_to_json_schema(:utc_datetime_usec, _module, _field),
    do: %{"type" => "string", "format" => "date-time"}

  defp ecto_type_to_json_schema(:naive_datetime, _module, _field),
    do: %{"type" => "string", "format" => "date-time"}

  defp ecto_type_to_json_schema(:naive_datetime_usec, _module, _field),
    do: %{"type" => "string", "format" => "date-time"}

  defp ecto_type_to_json_schema(:map, _module, _field), do: %{"type" => "object"}
  defp ecto_type_to_json_schema(:binary, _module, _field), do: %{"type" => "string"}
  defp ecto_type_to_json_schema(:binary_id, _module, _field), do: %{"type" => "string"}

  defp ecto_type_to_json_schema(Ecto.UUID, _module, _field),
    do: %{"type" => "string", "format" => "uuid"}

  defp ecto_type_to_json_schema(
         {:parameterized, {Ecto.Enum, %{on_dump: on_dump}}},
         _module,
         _field
       ) do
    values = Map.values(on_dump) |> Enum.map(&to_string/1)
    %{"type" => "string", "enum" => values}
  end

  # Handle Ecto.Enum with mappings (Ecto 3.12+)
  defp ecto_type_to_json_schema({:parameterized, Ecto.Enum, %{on_dump: on_dump}}, _module, _field) do
    values = Map.values(on_dump) |> Enum.map(&to_string/1)
    %{"type" => "string", "enum" => values}
  end

  defp ecto_type_to_json_schema({:array, inner}, module, field) do
    %{"type" => "array", "items" => ecto_type_to_json_schema(inner, module, field)}
  end

  defp ecto_type_to_json_schema({:map, _inner}, _module, _field) do
    %{"type" => "object"}
  end

  defp ecto_type_to_json_schema(_type, _module, _field) do
    # Fallback for unknown types
    %{"type" => "string"}
  end

  # --- Schemaless types → JSON Schema ---

  defp schemaless_to_json_schema(types) do
    {properties, required} =
      Enum.reduce(types, {%{}, []}, fn {field, type}, {props, req} ->
        json_type = schemaless_type_to_json(type)
        {Map.put(props, Atom.to_string(field), json_type), [Atom.to_string(field) | req]}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.reverse(required),
      "additionalProperties" => false
    }
  end

  defp schemaless_type_to_json(:string), do: %{"type" => "string"}
  defp schemaless_type_to_json(:integer), do: %{"type" => "integer"}
  defp schemaless_type_to_json(:float), do: %{"type" => "number", "format" => "float"}
  defp schemaless_type_to_json(:boolean), do: %{"type" => "boolean"}
  defp schemaless_type_to_json(:decimal), do: %{"type" => "number"}
  defp schemaless_type_to_json(:date), do: %{"type" => "string", "format" => "date"}
  defp schemaless_type_to_json(:utc_datetime), do: %{"type" => "string", "format" => "date-time"}

  defp schemaless_type_to_json(:naive_datetime),
    do: %{"type" => "string", "format" => "date-time"}

  defp schemaless_type_to_json(:map), do: %{"type" => "object"}

  defp schemaless_type_to_json({:array, inner}),
    do: %{"type" => "array", "items" => schemaless_type_to_json(inner)}

  defp schemaless_type_to_json(_type), do: %{"type" => "string"}

  # --- Map type classification ---

  defp classify_map_type(map) when map_size(map) == 0, do: :raw_json_schema

  defp classify_map_type(map) do
    first_key = map |> Map.keys() |> List.first()

    if is_atom(first_key) do
      :schemaless
    else
      :raw_json_schema
    end
  end

  # --- Mode resolution ---

  defp resolve_mode(:auto, :openai), do: :json_schema
  defp resolve_mode(:auto, :anthropic), do: :tool_call
  defp resolve_mode(:auto, :vllm), do: :json_schema
  defp resolve_mode(:auto, :sglang), do: :json_schema
  defp resolve_mode(:auto, :gemini), do: :json_schema
  defp resolve_mode(:auto, _provider), do: :json_schema
  defp resolve_mode(explicit, _provider), do: explicit

  # --- Mode-specific settings ---

  defp mode_settings(:json_schema, json_schema, name, provider, _opts) do
    base = %{
      response_format: %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => name || "output",
          "schema" => json_schema,
          "strict" => true
        }
      }
    }

    # vLLM also uses guided_json
    case provider do
      :vllm -> Map.put(base, :guided_json, json_schema)
      :sglang -> Map.put(base, :json_schema, json_schema)
      _ -> base
    end
  end

  defp mode_settings(:json, _json_schema, _name, _provider, _opts) do
    %{response_format: %{"type" => "json_object"}}
  end

  defp mode_settings(:tool_call, json_schema, name, _provider, opts) do
    tool_name = "__structured_output__"
    has_other_tools = Keyword.get(opts, :has_other_tools, false)

    tool = %{
      "type" => "function",
      "function" => %{
        "name" => tool_name,
        "description" => "Return structured output matching the schema for: #{name || "output"}",
        "parameters" => json_schema
      }
    }

    tool_choice =
      if has_other_tools do
        # When there are other tools, use "auto" — the LLM picks which to call
        "auto"
      else
        %{"type" => "function", "function" => %{"name" => tool_name}}
      end

    %{
      __structured_output_tool__: tool,
      __structured_output_tool_choice__: tool_choice
    }
  end

  defp mode_settings(:md_json, _json_schema, _name, _provider, _opts) do
    # All enforcement via system prompt + stop token
    %{stop: ["```"]}
  end

  # --- Guided decoding settings (vLLM/SGLang) ---

  defp guided_settings(:regex, pattern, :vllm), do: %{guided_regex: pattern}
  defp guided_settings(:regex, pattern, :sglang), do: %{regex: pattern}
  defp guided_settings(:regex, _pattern, _provider), do: %{}

  defp guided_settings(:grammar, grammar, :vllm), do: %{guided_grammar: grammar}
  defp guided_settings(:grammar, _grammar, _provider), do: %{}

  defp guided_settings(:choice, choices, :vllm), do: %{guided_choice: choices}
  defp guided_settings(:choice, _choices, _provider), do: %{}

  # --- Schema name ---

  defp schema_name(module) when is_atom(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp schema_name(%{} = _map), do: "output"
  defp schema_name(_), do: "output"

  # --- Ecto schema casting ---

  defp cast_schema(parsed, module) do
    fields = module.__schema__(:fields) |> Enum.reject(&(&1 == :id))
    embeds = try_schema_call(module, :embeds, [])

    # Cast flat fields
    changeset =
      struct(module)
      |> Ecto.Changeset.cast(stringify_keys(parsed), fields -- embeds)

    # Cast embeds
    changeset =
      Enum.reduce(embeds, changeset, fn embed_field, cs ->
        Ecto.Changeset.cast_embed(cs, embed_field)
      end)

    # Apply custom validation if defined
    changeset =
      if function_exported?(module, :validate_changeset, 1) do
        module.validate_changeset(changeset)
      else
        changeset
      end

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, changeset_to_validation_error(changeset, module)}
    end
  end

  # --- Schemaless casting ---

  defp cast_schemaless(parsed, types) do
    fields = Map.keys(types)
    data = Map.new(fields, fn f -> {f, nil} end)

    changeset =
      {data, types}
      |> Ecto.Changeset.cast(stringify_keys(parsed), fields)
      |> Ecto.Changeset.validate_required(fields)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, changeset_to_validation_error(changeset, types)}
    end
  end

  # --- Helpers ---

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {k, stringify_keys(v)}
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp changeset_to_validation_error(changeset, output_type) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn
          {key, value}, acc when is_binary(acc) ->
            String.replace(acc, "%{#{key}}", inspect(value))

          _, acc ->
            acc
        end)
      end)
      |> Enum.flat_map(fn {field, msgs} ->
        Enum.map(msgs, fn msg -> {field, {msg, []}} end)
      end)

    Errors.ValidationError.exception(
      message: "Output validation failed: #{inspect(errors)}",
      errors: errors,
      output_type: output_type
    )
  end

  defp extract_json_from_markdown(text) do
    trimmed = String.trim(text)

    # Try to extract from ```json ... ``` or ``` ... ```
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)(?:\n?```|$)/s, trimmed) do
      [_, json] -> String.trim(json)
      nil -> trimmed
    end
  end

  defp find_synthetic_tool_call(%Nous.Message{tool_calls: tool_calls})
       when is_list(tool_calls) do
    Enum.find(tool_calls, fn call ->
      name = call[:name] || call["name"]
      name == "__structured_output__"
    end)
  end

  defp find_synthetic_tool_call(_), do: nil
end
