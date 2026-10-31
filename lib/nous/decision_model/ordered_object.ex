defmodule Nous.DecisionModel.OrderedObject do
  @moduledoc false

  # A JSON object that keeps its key order on the wire.
  #
  # Decision requests are sent through `Nous.Providers.HTTP.post/4`, which takes
  # a map body. Clef reads questions and choice options in the order given, and
  # an Elixir map does not keep insertion order (sorted keys up to 32 entries).
  # This struct is a map (so it passes `post/4`'s guard and keeps the
  # `Nous.HTTP.Backend` contract unchanged) and implements both encoders the
  # shipped HTTP backends use: Req encodes `json:` bodies with Jason, the Hackney
  # backend with Elixir's `JSON`.

  @enforce_keys [:fields]
  defstruct [:fields]

  @type t :: %__MODULE__{fields: [{String.t(), term()}]}

  @spec new([{String.t(), term()}]) :: t()
  def new(fields) when is_list(fields), do: %__MODULE__{fields: fields}

  defimpl Jason.Encoder do
    def encode(%{fields: fields}, opts), do: Jason.Encode.keyword(fields, opts)
  end

  defimpl JSON.Encoder do
    def encode(%{fields: []}, _encoder), do: "{}"

    def encode(%{fields: fields}, encoder) do
      [
        ?{,
        Enum.map_intersperse(fields, ?,, fn {key, value} when is_binary(key) ->
          [encoder.(key, encoder), ?:, encoder.(value, encoder)]
        end),
        ?}
      ]
    end
  end
end
