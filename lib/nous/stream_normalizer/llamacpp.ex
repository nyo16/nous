if Code.ensure_loaded?(LlamaCppEx) do
  defmodule Nous.StreamNormalizer.LlamaCpp do
    @moduledoc """
    Stream normalizer for LlamaCppEx `%ChatCompletionChunk{}` structs.

    Converts NIF-produced chunk structs into normalized Nous stream events.
    llama.cpp speaks OpenAI's chat.completion wire shape, so both complete
    responses and deltas go through `Nous.StreamNormalizer.OpenAI`: text,
    `reasoning_content` (as `{:thinking_delta, _}`), OpenAI-shaped `tool_calls`
    deltas (as `{:tool_call_delta, _}`, which
    `Nous.StreamNormalizer.ToolCallAccumulator` assembles) and the finish
    reason.

    LlamaCppEx ends a failed stream with a bare `{:error, reason}` element
    (an unsupported chat template, a chunk timeout); it becomes an
    `{:error, %Nous.Errors.ProviderError{provider: :llamacpp}}` event, the same
    error type the non-streaming path returns, rather than being dropped as
    unknown.

    Requires optional dep: `{:llama_cpp_ex, "~> 0.8.63"}`
    """

    @behaviour Nous.StreamNormalizer

    alias Nous.StreamNormalizer.OpenAI

    @impl true
    def normalize_chunk({:error, %Nous.Errors.ProviderError{} = error}), do: [{:error, error}]

    def normalize_chunk({:error, reason}) do
      [
        {:error,
         Nous.Errors.ProviderError.exception(
           provider: :llamacpp,
           message: "Stream failed: #{inspect(reason)}",
           details: reason
         )}
      ]
    end

    def normalize_chunk(chunk) when is_struct(chunk) or is_map(chunk),
      do: OpenAI.normalize_chunk(chunk)

    def normalize_chunk(chunk) do
      [{:unknown, chunk}]
    end

    @impl true
    defdelegate complete_response?(chunk), to: OpenAI

    @impl true
    defdelegate convert_complete_response(chunk), to: OpenAI
  end
else
  defmodule Nous.StreamNormalizer.LlamaCpp do
    @moduledoc """
    Stream normalizer for LlamaCppEx `%ChatCompletionChunk{}` structs.

    **Not available** - add `{:llama_cpp_ex, "~> 0.8.63"}` to your mix.exs deps.
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
