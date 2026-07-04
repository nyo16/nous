defmodule Nous.ToolCall do
  @moduledoc """
  Field access for tool-call maps whose keys may be atoms or strings.

  Providers return tool calls with string keys (`%{"name" => ...}`) while the
  internal format uses atom keys (`%{name: ...}`). These helpers resolve a
  field across both key styles in one place.

  Unlike the `call[:name] || call["name"]` idiom, `field/3` preserves
  legitimately-falsy values: `arguments: false` / `0` / `""` are returned
  as-is instead of being coalesced into the fallback. Only a missing key or
  an explicit `nil` falls through to the next key style and then the default.
  """

  @doc """
  Get `key` from a tool-call map, checking the atom key then its string form.

  Returns `default` when the field is absent or `nil` under both key styles.

  ## Examples

      iex> Nous.ToolCall.field(%{"name" => "search"}, :name)
      "search"

      iex> Nous.ToolCall.field(%{arguments: false}, :arguments)
      false

      iex> Nous.ToolCall.field(%{}, :arguments, %{})
      %{}

  """
  @spec field(map(), atom(), term()) :: term()
  def field(call, key, default \\ nil) when is_map(call) and is_atom(key) do
    case Map.fetch(call, key) do
      {:ok, value} when not is_nil(value) ->
        value

      _ ->
        case Map.fetch(call, Atom.to_string(key)) do
          {:ok, value} when not is_nil(value) -> value
          _ -> default
        end
    end
  end

  @doc """
  Put `value` under `key`, preserving the map's existing key style.

  Writes to the atom key when present, otherwise to the existing string key,
  and defaults to the string form when the field is new (matching the wire
  format providers use).
  """
  @spec put_field(map(), atom(), term()) :: map()
  def put_field(call, key, value) when is_map(call) and is_atom(key) do
    if Map.has_key?(call, key) do
      Map.put(call, key, value)
    else
      Map.put(call, Atom.to_string(key), value)
    end
  end
end
