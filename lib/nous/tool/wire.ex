defmodule Nous.Tool.Wire do
  @moduledoc """
  Serialise a `Nous.Tool` into the wire schema a given provider expects.

  This is the outbound half of the tool schema story, and the mirror of
  `Nous.Tool.Schema`: that module is the `use`-able DSL you write a tool
  *with*, this one turns the resulting `%Nous.Tool{}` into the JSON a
  provider's API accepts.

  Different LLM providers expect different tool schema formats:

  - **OpenAI format**: String keys, function wrapper
  - **Anthropic format**: Atom keys, input_schema field
  - **Gemini/Vertex format**: String keys, `functionDeclarations` entry

  ## Examples

      # Convert to OpenAI format (used by OpenAI, Groq, OpenRouter, local providers)
      openai_schema = Wire.to_openai(tool)
      # Returns: %{"type" => "function", "function" => %{"name" => "...", ...}}

      # Convert to Anthropic format (used by Claude)
      anthropic_schema = Wire.to_anthropic(tool)
      # Returns: %{name: "...", description: "...", input_schema: %{type: :object, ...}}

  The schema conversion preserves all tool metadata while adapting to provider requirements.
  """

  alias Nous.Tool

  @doc """
  Convert tool to OpenAI function calling schema (string keys).

  Deprecated alias — call `Nous.Tool.to_openai_schema/1` directly. This
  module's `to_anthropic/1` and `to_gemini/1` are the actively used
  conversions; `to_openai/1` is only kept for backward compatibility.
  """
  @deprecated "Use Nous.Tool.to_openai_schema/1 directly"
  @spec to_openai(Tool.t()) :: map()
  def to_openai(tool) do
    Tool.to_openai_schema(tool)
  end

  @doc """
  Convert tool to Gemini/Vertex `functionDeclarations` schema (string keys).

  Vertex/Gemini's function declaration is shaped like OpenAI's inner `function`
  object, minus the `strict` field which is OpenAI-specific.

  Returns:

      %{
        "name" => "...",
        "description" => "...",
        "parameters" => %{...}
      }
  """
  @spec to_gemini(Tool.t()) :: map()
  def to_gemini(tool) do
    %{"function" => function} = Tool.to_openai_schema(tool)

    function
    |> Map.delete("strict")
    |> Map.update("parameters", %{}, &strip_unsupported_schema_keys/1)
  end

  # Vertex's parameters schema rejects fields like `additionalProperties` /
  # `$schema`. Drop the well-known unsupported ones so callers don't have to
  # think about it.
  defp strip_unsupported_schema_keys(schema) when is_map(schema) do
    schema
    |> Map.drop(["additionalProperties", "$schema"])
    |> Map.new(fn {k, v} -> {k, strip_unsupported_schema_keys(v)} end)
  end

  defp strip_unsupported_schema_keys(list) when is_list(list),
    do: Enum.map(list, &strip_unsupported_schema_keys/1)

  defp strip_unsupported_schema_keys(value), do: value

  @doc """
  Convert tool to Anthropic tool schema (atom keys).

  Anthropic uses a different format with atom keys:
  %{
    name: "tool_name",
    description: "Tool description",
    input_schema: %{
      type: "object",
      properties: %{...},
      required: [...]
    }
  }
  """
  @spec to_anthropic(Tool.t()) :: map()
  def to_anthropic(tool) do
    # Convert from OpenAI format to Anthropic format
    openai_schema = Tool.to_openai_schema(tool)
    func = openai_schema["function"]

    %{
      name: func["name"],
      description: func["description"] || "No description provided",
      input_schema: convert_to_atom_keys(func["parameters"] || %{})
    }
  end

  # Convert string keys to atom keys recursively for Anthropic
  # Only converts well-known schema keys to atoms for safety
  defp convert_to_atom_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = safe_string_to_atom(k)
      value = convert_to_atom_keys(v)
      {key, value}
    end)
  end

  defp convert_to_atom_keys(list) when is_list(list) do
    Enum.map(list, &convert_to_atom_keys/1)
  end

  defp convert_to_atom_keys(value), do: value

  # Whitelist of JSON-schema keys that are safe to intern as atoms. A data
  # table rather than a `case` so extending it is a one-line change.
  @schema_atom_keys %{
    "type" => :type,
    "properties" => :properties,
    "required" => :required,
    "items" => :items,
    "description" => :description,
    "enum" => :enum,
    "default" => :default,
    "minimum" => :minimum,
    "maximum" => :maximum,
    "minLength" => :minLength,
    "maxLength" => :maxLength,
    "pattern" => :pattern,
    "format" => :format,
    "additionalProperties" => :additionalProperties
  }

  # Anything outside the whitelist stays a string: interning arbitrary
  # tool-supplied keys is an atom-exhaustion vector.
  defp safe_string_to_atom(string) when is_binary(string) do
    Map.get(@schema_atom_keys, string, string)
  end

  defp safe_string_to_atom(other), do: other
end
