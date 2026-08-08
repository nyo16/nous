if Code.ensure_loaded?(LlamaCppEx) do
  defmodule Nous.StreamNormalizer.LlamaCpp do
    @moduledoc """
    Stream normalizer for LlamaCppEx `%ChatCompletionChunk{}` structs.

    Converts NIF-produced chunk structs into normalized Nous stream events.
    llama.cpp speaks OpenAI's chat.completion wire shape, so complete
    (non-delta) responses delegate to `Nous.StreamNormalizer.OpenAI` — this
    also keeps content and tool calls when a stream degenerates into a
    single complete response object.

    Requires optional dep: `{:llama_cpp_ex, "~> 0.8"}`
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
      case fetch_either(chunk, :choices, "choices") || [] do
        [choice | _] -> choice_events(choice, chunk)
        _ -> [{:unknown, chunk}]
      end
    end

    defp choice_events(choice, chunk) do
      delta = fetch_either(choice, :delta, "delta")
      finish_reason = fetch_either(choice, :finish_reason, "finish_reason")
      content = delta && fetch_either(delta, :content, "content")

      cond do
        content && content != "" -> [{:text_delta, content}]
        finish_reason -> [{:finish, finish_reason}]
        true -> [{:unknown, chunk}]
      end
    end

    # NIF chunks arrive as structs with atom keys; the same shape reaches us with
    # string keys when llama.cpp's HTTP server is in front. Atom key wins.
    defp fetch_either(data, atom_key, string_key) do
      Map.get(data, atom_key) || Map.get(data, string_key)
    end
  end
else
  defmodule Nous.StreamNormalizer.LlamaCpp do
    @moduledoc """
    Stream normalizer for LlamaCppEx `%ChatCompletionChunk{}` structs.

    **Not available** - add `{:llama_cpp_ex, "~> 0.8"}` to your mix.exs deps.
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
