defmodule Yggdrasil.ToolSchema do
  @moduledoc """
  Convert tools to different schema formats for various providers.
  """

  alias Yggdrasil.Tool

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
  defp convert_to_atom_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      value = convert_to_atom_keys(v)
      {key, value}
    end)
  end

  defp convert_to_atom_keys(list) when is_list(list) do
    Enum.map(list, &convert_to_atom_keys/1)
  end

  defp convert_to_atom_keys(value), do: value
end
