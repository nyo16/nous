defmodule Nous.Memory.Search do
  @moduledoc """
  Behaviour for pluggable memory search backends.

  Implement this behaviour to create custom search backends for the memory system.
  Built-in implementations include:

  - `Nous.Memory.Search.Simple` - Text matching search (substring, regex)
  - `Nous.Memory.Search.Tantivy` - Full-text search via Muninn (future)
  - `Nous.Memory.Search.Vector` - Semantic search via HNSWLib (future)
  - `Nous.Memory.Search.Hybrid` - Combined keyword + semantic search (future)

  ## Example Implementation

      defmodule MyApp.Memory.ElasticsearchSearch do
        @behaviour Nous.Memory.Search

        @impl true
        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts)
        end

        @impl true
        def index(pid, memory) do
          GenServer.call(pid, {:index, memory})
        end

        @impl true
        def search(pid, query, opts) do
          GenServer.call(pid, {:search, query, opts})
        end

        # ... implement other callbacks
      end

  ## Search Strategies

  Different backends support different search strategies:

  - **Text matching**: Simple substring or regex matching on content
  - **Full-text**: Tokenized, stemmed search with relevance scoring
  - **Semantic**: Vector similarity using embeddings
  - **Hybrid**: Weighted combination of text and semantic search

  """

  alias Nous.Memory

  @type search_ref :: pid() | atom() | GenServer.server()

  @type search_result :: %{
          memory: Memory.t(),
          score: float(),
          highlights: [String.t()] | nil
        }

  @doc """
  Start the search backend process.

  Returns `{:ok, pid}` on success.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Index a memory for searching.

  This adds the memory to the search index. For vector search backends,
  this may involve computing embeddings.

  Returns `:ok` on success.
  """
  @callback index(search_ref(), Memory.t()) :: :ok | {:error, term()}

  @doc """
  Search for memories matching the query.

  ## Options

  - `:limit` - Maximum number of results (default: 10)
  - `:min_score` - Minimum relevance score (0.0 - 1.0)
  - `:tags` - Filter by tags before searching
  - `:importance` - Filter by minimum importance
  - `:include_highlights` - Include text snippets showing matches

  Returns `{:ok, [search_result]}` with results sorted by relevance score.
  """
  @callback search(search_ref(), query :: String.t(), opts :: keyword()) ::
              {:ok, [search_result()]} | {:error, term()}

  @doc """
  Remove a memory from the search index.

  Returns `:ok` on success (including if the memory wasn't indexed).
  """
  @callback delete(search_ref(), id :: term()) :: :ok | {:error, term()}

  @doc """
  Update a memory in the search index.

  This re-indexes the memory with updated content.
  Returns `:ok` on success.
  """
  @callback update(search_ref(), Memory.t()) :: :ok | {:error, term()}

  @doc """
  Clear all entries from the search index.

  Returns `{:ok, count}` with the number of entries removed.
  """
  @callback clear(search_ref()) :: {:ok, non_neg_integer()} | {:error, term()}

  # Optional callbacks

  @doc """
  Check if the search backend supports a specific feature.

  Features include:
  - `:full_text` - Full-text search with stemming/tokenization
  - `:semantic` - Vector similarity search
  - `:hybrid` - Combined text + semantic search
  - `:highlights` - Search result highlighting

  Default implementation returns false for all features.
  """
  @callback supports?(search_ref(), feature :: atom()) :: boolean()

  @optional_callbacks [supports?: 2]

  @doc """
  Default implementation of supports?/2 that returns false.
  """
  def supports?(_search_ref, _feature), do: false
end
