defmodule Nous.StreamNormalizer.ToolCallAccumulator do
  @moduledoc """
  Reassembles partial tool-call fragments emitted by `Nous.StreamNormalizer`
  into the final list shape that `Nous.Messages.from_provider_response/2`
  produces for the non-streaming path.

  Used by the `stream: true` branch of `Nous.AgentRunner.run/3` to convert a
  sequence of `{:tool_call_delta, fragment}` events into the
  `tool_calls` field of an assembled `%Nous.Message{}`.

  Polymorphic across the three provider chunk shapes that
  `Nous.StreamNormalizer` emits:

  ## OpenAI-compatible

  Fragments arrive as a list of partial calls, each with an `"index"` plus
  potentially split `"function"."arguments"` JSON:

      [%{"index" => 0, "id" => "call_a", "function" => %{"name" => "search", "arguments" => "{\\"q"}}]
      [%{"index" => 0, "function" => %{"arguments" => "uery\\":\\"hi\\"}"}}]

  ## Anthropic

  Fragments are tagged with `_phase` and `_index` (see
  `Nous.StreamNormalizer.Anthropic`):

      %{"id" => "tu_a", "name" => "search", "_index" => 0, "_phase" => :start}
      %{"_index" => 0, "_phase" => :partial, "partial_json" => "{\\"q"}
      %{"_index" => 0, "_phase" => :partial, "partial_json" => "uery\\":\\"hi\\"}"}
      %{"_index" => 0, "_phase" => :stop}

  ## Gemini

  Fragments arrive already-complete (Gemini does not split tool-call
  arguments across chunks):

      %{"name" => "search", "arguments" => %{"query" => "hi"}}

  ## API

      acc = ToolCallAccumulator.new()
      acc = ToolCallAccumulator.feed(acc, fragment)
      tool_calls = ToolCallAccumulator.finalize(acc)
      # => [%{"id" => "call_a", "name" => "search", "arguments" => %{"query" => "hi"}}]
  """

  alias Nous.Messages.OpenAI, as: OpenAIMessages

  @type partial_call :: %{
          required(:id) => String.t() | nil,
          required(:name) => String.t() | nil,
          required(:args_io) => iodata()
        }

  @type t :: %{
          openai: %{integer() => partial_call()},
          anthropic: %{integer() => partial_call()},
          gemini: [%{required(String.t()) => term()}]
        }

  @doc "Build an empty accumulator."
  @spec new() :: t()
  def new do
    %{openai: %{}, anthropic: %{}, gemini: []}
  end

  @doc """
  Feed a single `{:tool_call_delta, fragment}` payload into the accumulator.

  The `fragment` shape is detected automatically — see the module doc for the
  three supported shapes. Unrecognized fragments are silently dropped (the
  caller has already filtered `{:unknown, _}` events upstream).
  """
  @spec feed(t(), term()) :: t()
  def feed(acc, fragment)

  # OpenAI: list of partial tool-call objects
  def feed(acc, fragments) when is_list(fragments) do
    Enum.reduce(fragments, acc, &feed_openai_one/2)
  end

  # Anthropic: tagged fragments with _phase and _index
  def feed(acc, %{"_phase" => :start, "_index" => index} = fragment) do
    id = Map.get(fragment, "id")
    name = Map.get(fragment, "name")

    update_in(acc, [:anthropic, index], fn
      nil -> %{id: id, name: name, args_io: []}
      existing -> %{existing | id: existing.id || id, name: existing.name || name}
    end)
  end

  def feed(acc, %{"_phase" => :partial, "_index" => index, "partial_json" => json}) do
    update_in(acc, [:anthropic, index], fn
      nil -> %{id: nil, name: nil, args_io: [json]}
      existing -> %{existing | args_io: [existing.args_io, json]}
    end)
  end

  def feed(acc, %{"_phase" => :stop, "_index" => _index}), do: acc

  # Gemini: already-complete tool call
  def feed(acc, %{"name" => name, "arguments" => arguments}) when is_map(arguments) do
    call = %{
      "id" => Map.get(acc, "id"),
      "name" => name,
      "arguments" => arguments
    }

    %{acc | gemini: [call | acc.gemini]}
  end

  # Anthropic non-streaming complete-response fallback emits
  # `%{"id" => id, "name" => name, "input" => input}` when the response degenerates.
  def feed(acc, %{"id" => id, "name" => name, "input" => input}) when is_map(input) do
    call = %{"id" => id, "name" => name, "arguments" => input}
    %{acc | gemini: [call | acc.gemini]}
  end

  def feed(acc, _other), do: acc

  defp feed_openai_one(fragment, acc) when is_map(fragment) do
    index = Map.get(fragment, "index") || Map.get(fragment, :index) || 0
    id = Map.get(fragment, "id") || Map.get(fragment, :id)
    func = Map.get(fragment, "function") || Map.get(fragment, :function) || %{}
    name = Map.get(func, "name") || Map.get(func, :name)
    args_chunk = Map.get(func, "arguments") || Map.get(func, :arguments) || ""

    update_in(acc, [:openai, index], fn
      nil ->
        %{id: id, name: name, args_io: [args_chunk]}

      existing ->
        %{
          existing
          | id: existing.id || id,
            name: existing.name || name,
            args_io: [existing.args_io, args_chunk]
        }
    end)
  end

  defp feed_openai_one(_, acc), do: acc

  @doc """
  Finalize the accumulator into a list of tool calls in the unified shape:

      [%{"id" => id_or_nil, "name" => name, "arguments" => decoded_map}, ...]

  OpenAI and Anthropic argument buffers are JSON-decoded via
  `Nous.Messages.OpenAI.decode_arguments/1` (which logs a warning and falls
  back to `%{"error" => "Invalid JSON arguments", "raw" => raw}` on
  malformed JSON). Gemini calls already carry decoded `arguments`.

  Order: OpenAI calls sorted by index, then Anthropic calls sorted by
  `_index`, then Gemini calls in arrival order. In practice only one of the
  three is non-empty per response.
  """
  @spec finalize(t()) :: [%{required(String.t()) => term()}]
  def finalize(%{openai: openai, anthropic: anthropic, gemini: gemini}) do
    finalize_indexed(openai) ++ finalize_indexed(anthropic) ++ Enum.reverse(gemini)
  end

  defp finalize_indexed(map) when map_size(map) == 0, do: []

  defp finalize_indexed(map) do
    map
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {_index, %{id: id, name: name, args_io: args_io}} ->
      %{
        "id" => id,
        "name" => name,
        "arguments" => OpenAIMessages.decode_arguments(IO.iodata_to_binary(args_io))
      }
    end)
  end
end
