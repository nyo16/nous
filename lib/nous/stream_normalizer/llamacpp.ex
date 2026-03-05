if Code.ensure_loaded?(LlamaCppEx) do
  defmodule Nous.StreamNormalizer.LlamaCpp do
    @moduledoc """
    Stream normalizer for LlamaCppEx `%ChatCompletionChunk{}` structs.

    Converts NIF-produced chunk structs into normalized Nous stream events.

    Requires optional dep: `{:llama_cpp_ex, "~> 0.5.0"}`
    """

    @behaviour Nous.StreamNormalizer

    @impl true
    def normalize_chunk(chunk) when is_struct(chunk) do
      choices = chunk.choices || []

      case choices do
        [choice | _] ->
          delta = choice.delta
          finish_reason = choice.finish_reason

          cond do
            delta && delta.content && delta.content != "" ->
              [{:text_delta, delta.content}]

            finish_reason ->
              [{:finish, finish_reason}]

            true ->
              [{:unknown, chunk}]
          end

        _ ->
          [{:unknown, chunk}]
      end
    end

    # Fall back to OpenAI normalizer for plain map chunks
    def normalize_chunk(chunk) when is_map(chunk) do
      Nous.StreamNormalizer.OpenAI.normalize_chunk(chunk)
    end

    def normalize_chunk(chunk) do
      [{:unknown, chunk}]
    end

    @impl true
    def complete_response?(chunk) when is_struct(chunk) do
      choices = chunk.choices || []

      case choices do
        [choice | _] ->
          message = Map.get(choice, :message)
          message != nil

        _ ->
          false
      end
    end

    def complete_response?(chunk) when is_map(chunk) do
      Nous.StreamNormalizer.OpenAI.complete_response?(chunk)
    end

    def complete_response?(_), do: false

    @impl true
    def convert_complete_response(chunk) when is_struct(chunk) do
      choices = chunk.choices || []

      case choices do
        [choice | _] ->
          message = choice.message
          content = message && message.content
          finish_reason = choice.finish_reason || "stop"

          events = []

          events =
            if content && content != "", do: [{:text_delta, content} | events], else: events

          events = [{:finish, finish_reason} | events]
          Enum.reverse(events)

        _ ->
          [{:unknown, chunk}]
      end
    end

    def convert_complete_response(chunk) when is_map(chunk) do
      Nous.StreamNormalizer.OpenAI.convert_complete_response(chunk)
    end

    def convert_complete_response(chunk), do: [{:unknown, chunk}]
  end
else
  defmodule Nous.StreamNormalizer.LlamaCpp do
    @moduledoc """
    Stream normalizer for LlamaCppEx `%ChatCompletionChunk{}` structs.

    **Not available** - add `{:llama_cpp_ex, "~> 0.5.0"}` to your mix.exs deps.
    """

    @behaviour Nous.StreamNormalizer

    @impl true
    def normalize_chunk(chunk), do: [{:unknown, chunk}]

    @impl true
    def complete_response?(_chunk), do: false

    @impl true
    def convert_complete_response(chunk), do: [{:unknown, chunk}]
  end
end
