if Code.ensure_loaded?(LlamaCppEx) do
  defmodule Nous.StreamNormalizer.LlamaCpp do
    @moduledoc """
    Stream normalizer for LlamaCppEx `%ChatCompletionChunk{}` structs.

    Converts NIF-produced chunk structs into normalized Nous stream events.
    llama.cpp speaks OpenAI's chat.completion wire shape, so complete
    (non-delta) responses delegate to `Nous.StreamNormalizer.OpenAI` — this
    also keeps content and tool calls when a stream degenerates into a
    single complete response object.

    Requires optional dep: `{:llama_cpp_ex, "~> 0.6.5"}`
    """

    @behaviour Nous.StreamNormalizer

    alias Nous.StreamNormalizer.OpenAI

    @impl true
    def normalize_chunk(chunk) when is_struct(chunk) or is_map(chunk) do
      if complete_response?(chunk) do
        convert_complete_response(chunk)
      else
        parse_delta_chunk(chunk)
      end
    end

    def normalize_chunk(chunk) do
      [{:unknown, chunk}]
    end

    @impl true
    defdelegate complete_response?(chunk), to: OpenAI

    @impl true
    defdelegate convert_complete_response(chunk), to: OpenAI

    defp parse_delta_chunk(chunk) do
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
  end
else
  defmodule Nous.StreamNormalizer.LlamaCpp do
    @moduledoc """
    Stream normalizer for LlamaCppEx `%ChatCompletionChunk{}` structs.

    **Not available** - add `{:llama_cpp_ex, "~> 0.6.5"}` to your mix.exs deps.
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
