if Code.ensure_loaded?(LlamaCppEx) do
  defmodule Nous.StreamNormalizer.LlamaCpp do
    @moduledoc """
    Stream normalizer for LlamaCppEx `%ChatCompletionChunk{}` structs.

    Converts NIF-produced chunk structs into normalized Nous stream events.

    Requires optional dep: `{:llama_cpp_ex, "~> 0.5.0"}`
    """

    @behaviour Nous.StreamNormalizer

    @impl true
    def normalize_chunk(chunk) when is_struct(chunk) or is_map(chunk) do
      choices = Map.get(chunk, :choices) || Map.get(chunk, "choices") || []

      case choices do
        [choice | _] ->
          delta = Map.get(choice, :delta) || Map.get(choice, "delta")
          finish_reason = Map.get(choice, :finish_reason) || Map.get(choice, "finish_reason")
          content = delta && (Map.get(delta, :content) || Map.get(delta, "content"))

          cond do
            content && content != "" ->
              [{:text_delta, content}]

            finish_reason ->
              [{:finish, finish_reason}]

            true ->
              [{:unknown, chunk}]
          end

        _ ->
          [{:unknown, chunk}]
      end
    end

    def normalize_chunk(chunk) do
      [{:unknown, chunk}]
    end

    @impl true
    def complete_response?(chunk) when is_struct(chunk) or is_map(chunk) do
      choices = Map.get(chunk, :choices) || Map.get(chunk, "choices") || []

      case choices do
        [choice | _] ->
          message = Map.get(choice, :message) || Map.get(choice, "message")
          message != nil

        _ ->
          false
      end
    end

    def complete_response?(_), do: false

    @impl true
    def convert_complete_response(chunk) when is_struct(chunk) or is_map(chunk) do
      choices = Map.get(chunk, :choices) || Map.get(chunk, "choices") || []

      case choices do
        [choice | _] ->
          message = Map.get(choice, :message) || Map.get(choice, "message") || %{}
          content = Map.get(message, :content) || Map.get(message, "content")

          finish_reason =
            Map.get(choice, :finish_reason) || Map.get(choice, "finish_reason") || "stop"

          events = []

          events =
            if content && content != "", do: [{:text_delta, content} | events], else: events

          events = [{:finish, finish_reason} | events]
          Enum.reverse(events)

        _ ->
          [{:finish, "stop"}]
      end
    end

    def convert_complete_response(_chunk), do: [{:finish, "stop"}]
  end
else
  defmodule Nous.StreamNormalizer.LlamaCpp do
    @moduledoc """
    Stream normalizer for LlamaCppEx `%ChatCompletionChunk{}` structs.

    **Not available** - add `{:llama_cpp_ex, "~> 0.5.0"}` to your mix.exs deps.
    """

    @behaviour Nous.StreamNormalizer

    @impl true
    def normalize_chunk(_chunk), do: [{:finish, "not_available"}]

    @impl true
    def complete_response?(_chunk), do: false

    @impl true
    def convert_complete_response(_chunk), do: [{:finish, "not_available"}]
  end
end
