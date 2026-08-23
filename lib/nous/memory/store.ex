defmodule Nous.Memory.Store do
  @moduledoc """
  Storage behaviour for memory backends — including ones that live outside Nous.

  Nous ships three implementations (`Nous.Memory.Store.ETS`,
  `Nous.Memory.Store.SQLite`, `Nous.Memory.Store.DuckDB`), but nothing in the
  memory system knows those names. Every consumer dispatches on the module it was
  handed:

      Agent.new("openai:gpt-4o",
        plugins: [Nous.Plugins.Memory],
        deps: %{memory_config: %{store: MyApp.Memory.Store.Tantivy, store_state: state}}
      )

  So a backend you implement in your own application is a first-class citizen: put
  `@behaviour Nous.Memory.Store` on a module, pass it as `:store`, and the plugin,
  the tools and `Nous.Memory.Search` treat it exactly like a built-in. This is the
  supported way to add an exotic backend — a Tantivy index, an HNSW library, a
  vector database, your company's search cluster — without waiting on Nous to
  vendor a dependency for it.

  ## The state contract

  `init/1` returns an opaque `state` term. Nous never inspects it; it threads the
  value back into every other callback and stores whatever the *last* callback
  returned. Callbacks that mutate therefore return `{:ok, new_state}`, even when
  the underlying store is a mutable handle and the term never changes (both
  `Nous.Memory.Store.ETS` and the SQL stores hand back the same term).

  A run-scoped state — ETS tables owned by the calling process, a connection
  opened in `init/1` — is a valid and intentional design; see
  `Nous.Memory.Store.ETS`. There is no supervised owner and no cross-run sharing
  unless your backend arranges it.

  ## Callbacks

  Required: `init/1`, `store/2`, `fetch/2`, `delete/2`, `update/3`,
  `search_text/3`, `list/2`.

  Optional: `search_vector/3`. Its absence is **feature-detected**, not rescued —
  `Nous.Memory.Search` calls `function_exported?(store, :search_vector, 3)` and
  degrades to text-only search, so a text-only backend simply does not define it.
  Do not define it and return an error; that turns "this backend has no vector
  search" into a runtime failure the search path will surface to the model.

  Both search callbacks return `{:ok, [{Entry.t(), score}]}` — highest score
  first, already filtered by `:scope` and `:min_score` and already truncated to
  `:limit`. All search and list callbacks accept a `:scope` option (a map of
  `Nous.Memory.Entry` fields to filter on).

  ## What Nous gives you to build on

    * `Nous.Memory.Store.Results` — the tail every retrieval shares: hydrate hit
      ids from an entry table, drop out-of-scope entries, cut below `min_score`,
      sort, truncate. If your backend is an index plus an entry table, `rank/5` is
      the whole back half of `search_text/3`.
    * `Nous.Memory.Store.Conformance` — the contract suite Nous runs against its
      own backends. `use` it in your test file and your implementation is held to
      the same battery:

          defmodule MyApp.Memory.Store.TantivyConformanceTest do
            use Nous.Memory.Store.Conformance,
              store: MyApp.Memory.Store.Tantivy,
              init_opts: [index_path: "/tmp/test_index"]
          end

    * `Nous.Memory.Store.ETS` is the reference implementation — dependency-free
      and short enough to read in one sitting.
    * `examples/memory/postgresql_full.exs` is a complete worked example of a
      backend that lives *outside* Nous: PostgreSQL with `tsvector` full-text
      search and `pgvector` similarity, implementing this behaviour against
      Postgrex. It predates this documentation — the extension point already
      worked, it was simply never written down.

  ## Scores are compared across backends

  `Nous.Memory.Search` merges text and vector results and applies `:min_score` and
  the scoring weights to whatever numbers a backend returns, so **a similarity and
  a distance are not interchangeable**: hand back a distance and results rank
  backwards while every callback still looks correct. Normalise to a similarity
  where larger is better (ETS uses Jaro 0..1; the SQL stores use cosine
  similarity) before returning.
  """

  alias Nous.Memory.Entry

  @doc """
  Open or create the backend and return its opaque state.

  `opts` are the backend's own — Nous passes through whatever the host put in
  `memory_config`. Return `{:error, reason}` rather than raising when the store is
  unreachable or misconfigured.
  """
  @callback init(opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Persist `entry`, returning the state to use for subsequent calls.

  When a backend keeps an index and an entry table separately, order the writes so
  a failure leaves the entry absent from BOTH rather than indexed but unreadable
  (or the reverse) — a torn write should degrade to a miss, never to a wrong
  result.
  """
  @callback store(state :: term(), entry :: Entry.t()) :: {:ok, term()} | {:error, term()}

  @callback fetch(state :: term(), id :: String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  @callback delete(state :: term(), id :: String.t()) :: {:ok, term()} | {:error, term()}

  @doc """
  Applies `updates` to the entry identified by `id`.

  Returns `{:error, :not_found}` when no entry has that id.

  ## Unknown fields raise

  A key of `updates` that is not a `Nous.Memory.Entry` field is a **caller
  bug**, not a missing row, and backends that map fields onto SQL identifiers
  (`Nous.Memory.Store.SQLite`, `Nous.Memory.Store.DuckDB`) MUST raise
  `ArgumentError` for one rather than return an error tuple. The allowlist
  those backends check is an injection control, and it is validated *before*
  the row lookup, so an update carrying both an unknown field and an unknown
  id raises — it does not return `{:error, :not_found}`. Validating ahead of
  the lookup is also what keeps the control reachable without a live driver.

  Backends that do not build SQL (`Nous.Memory.Store.ETS`, and any backend that
  applies updates through `struct/2`) are not required to raise.
  """
  @callback update(state :: term(), id :: String.t(), updates :: map()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Full-text search. Highest score first; see the note on score direction above.

  Options: `:limit`, `:min_score`, `:scope`.
  """
  @callback search_text(state :: term(), query :: String.t(), opts :: keyword()) ::
              {:ok, [{Entry.t(), float()}]}

  @doc """
  Vector similarity search. **Optional** — omit the function entirely for a
  text-only backend rather than defining it and returning an error.

  Options: `:limit`, `:min_score`, `:scope`.
  """
  @callback search_vector(state :: term(), embedding :: [float()], opts :: keyword()) ::
              {:ok, [{Entry.t(), float()}]}

  @callback list(state :: term(), opts :: keyword()) :: {:ok, [Entry.t()]}

  @optional_callbacks [search_vector: 3]
end
