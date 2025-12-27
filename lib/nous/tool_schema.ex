defmodule Nous.ToolSchema do
  @moduledoc """
  Convert tools to different schema formats for various providers.

  Different LLM providers expect different tool schema formats:

  - **OpenAI format**: String keys, function wrapper
  - **Anthropic format**: Atom keys, input_schema field
  - **Custom providers**: May require format-specific adaptations

  ## Examples

      # Convert to OpenAI format (used by OpenAI, Groq, OpenRouter, local providers)
      openai_schema = ToolSchema.to_openai(tool)
      # Returns: %{"type" => "function", "function" => %{"name" => "...", ...}}

      # Convert to Anthropic format (used by Claude)
      anthropic_schema = ToolSchema.to_anthropic(tool)
      # Returns: %{name: "...", description: "...", input_schema: %{type: :object, ...}}

  The schema conversion preserves all tool metadata while adapting to provider requirements.
  """

  alias Nous.Tool

  @doc """
  Convert tool to OpenAI function calling schema (string keys).
  """
  @spec to_openai(Tool.t()) :: map()
  def to_openai(tool) do
    Tool.to_openai_schema(tool)
  end

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

  # Safely convert string to atom - only converts known schema keys
  defp safe_string_to_atom(string) when is_binary(string) do
    # Whitelist of known JSON schema keys that are safe to convert to atoms
    case string do
      "type" -> :type
      "properties" -> :properties
      "required" -> :required
      "items" -> :items
      "description" -> :description
      "enum" -> :enum
      "default" -> :default
      "minimum" -> :minimum
      "maximum" -> :maximum
      "minLength" -> :minLength
      "maxLength" -> :maxLength
      "pattern" -> :pattern
      "format" -> :format
      "additionalProperties" -> :additionalProperties
      _ -> string  # Keep unknown keys as strings to prevent atom exhaustion
    end
  end

  defp safe_string_to_atom(other), do: other
end
