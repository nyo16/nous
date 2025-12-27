defmodule Nous.StreamNormalizer do
  @moduledoc """
  Behaviour for stream chunk normalization.

  Implementations transform provider-specific stream chunks into
  normalized Nous stream events:
  - `{:text_delta, text}` - Incremental text content
  - `{:thinking_delta, text}` - Incremental reasoning/thinking content
  - `{:tool_call_delta, tool_calls}` - Tool call information
  - `{:finish, reason}` - Stream completion signal
  - `{:unknown, chunk}` - Unrecognized chunk (filtered by default)

  ## Default Implementation

  Most OpenAI-compatible providers work with the default implementation:

      Nous.StreamNormalizer.OpenAI

  ## Custom Implementation

  For providers with unique formats, implement this behaviour:

      defmodule MyApp.CustomNormalizer do
        @behaviour Nous.StreamNormalizer

        @impl true
        def normalize_chunk(chunk) do
          # Your custom logic
          [{:text_delta, chunk["custom_field"]}]
        end

        @impl true
        def complete_response?(chunk), do: false

        @impl true
        def convert_complete_response(_chunk), do: []
      end

  Then configure it on the model:

      Nous.new("openai_compatible:custom-model",
        base_url: "http://custom-server/v1",
        stream_normalizer: MyApp.CustomNormalizer
      )
  """

  alias Nous.Types

  @doc """
  Normalize a single chunk into a list of stream events.

  Returns a list because some chunks (like complete responses)
  may need to emit multiple events.
  """
  @callback normalize_chunk(chunk :: map()) :: [Types.stream_event()]

  @doc """
  Check if the chunk is a complete (non-streaming) response.

  Some servers return full responses instead of deltas when
  streaming fails or is disabled.
  """
  @callback complete_response?(chunk :: map()) :: boolean()

  @doc """
  Convert a complete response into stream events.

  Called when `complete_response?/1` returns true.
  Should return events like:
  `[{:text_delta, content}, {:finish, "stop"}]`
  """
  @callback convert_complete_response(chunk :: map()) :: [Types.stream_event()]

  @doc """
  Normalize a stream using the specified normalizer module.

  Applies normalization and filters out `{:unknown, _}` events.
  """
  def normalize(stream, normalizer_mod \\ __MODULE__.OpenAI) do
    require Logger

    stream
    |> Stream.flat_map(&normalizer_mod.normalize_chunk/1)
    |> Stream.reject(fn
      {:unknown, chunk} ->
        Logger.debug("Stream normalizer filtered unknown chunk: #{inspect(chunk, limit: :infinity)}")
        true
      _ ->
        false
    end)
  end
end
