defmodule Nous.Memory do
  @moduledoc """
  Top-level module for the Nous Memory System.

  Provides persistent memory for agents with hybrid text + vector search,
  temporal decay, importance weighting, and flexible scoping.

  ## Quick Start

      # Minimal setup (ETS store, keyword-only search)
      agent = Agent.new("openai:gpt-4",
        plugins: [Nous.Plugins.Memory],
        deps: %{memory_config: %{store: Nous.Memory.Store.ETS}}
      )

  ## Architecture

  Three layers, all plain modules and structs (no GenServer):

  - **Data Layer** — `Entry` (struct), `Store` (behaviour + backends)
  - **Search Layer** — `Search` (orchestrator), `Scoring` (RRF, decay)
  - **Integration** — `Plugins.Memory` (plugin), `Memory.Tools` (agent tools)

  ## Store Backends

  | Backend | Text search | Vector search | Deps |
  |---------|-------------|---------------|------|
  | `Store.ETS` | Jaro distance | None | None |
  | `Store.SQLite` | FTS5 (BM25) | Cosine similarity, computed in Elixir over every stored embedding | `exqlite` |
  | `Store.DuckDB` | ILIKE (the `fts` extension is loaded best-effort) | `list_cosine_similarity` in SQL | `duckdbex` |

  **No shipped backend does indexed (ANN) vector search** — both vector paths above
  are full scans over the entries that have an embedding. That is usually the right
  trade at the corpus sizes agent memory reaches, but it is a scan, and it is worth
  knowing before you point one at a million rows.

  Need something else — Tantivy, HNSW, a vector database, your own search cluster?
  `Nous.Memory.Store` is a documented extension point: implement the behaviour in
  your own application, pass the module as `:store`, and every consumer treats it
  like a built-in. See that module for the contract, `Nous.Memory.Store.Results`
  for the shared retrieval tail, and `Nous.Memory.Store.Conformance` for the
  contract suite Nous runs against its own backends.

  ## Embedding Providers

  | Provider | Description | Deps |
  |----------|-------------|------|
  | `Embedding.Bumblebee` | Local on-device (Qwen 0.6B) | `bumblebee`, `exla` |
  | `Embedding.OpenAI` | OpenAI text-embedding-3-small | None (uses Req) |
  | `Embedding.Local` | Ollama / vLLM / LMStudio | None (uses Req) |

  No embedding configured = keyword-only search. The system never fails
  if no embedding provider is set.
  """

  alias Nous.Memory.{Entry, Search}

  @doc """
  Validate a memory configuration map.

  Returns `{:ok, config}` with defaults applied, or `{:error, reason}`.
  """
  @spec validate_config(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_config(config) when is_map(config) do
    cond do
      !config[:store] ->
        {:error, ":store is required in memory_config"}

      true ->
        {:ok,
         config
         |> Map.put_new(:auto_inject, true)
         |> Map.put_new(:inject_strategy, :first_only)
         |> Map.put_new(:inject_limit, 5)
         |> Map.put_new(:inject_min_score, 0.3)
         |> Map.put_new(:decay_lambda, 0.001)
         |> Map.put_new(:default_search_scope, :agent)
         |> Map.put_new(:scoring_weights, relevance: 0.5, importance: 0.3, recency: 0.2)
         |> Map.put_new(:auto_update_memory, false)
         |> Map.put_new(:auto_update_every, 1)}
    end
  end

  @doc """
  Store a memory entry directly (bypassing agent tools).

  ## Examples

      {:ok, store_state} = Nous.Memory.Store.ETS.init([])
      entry = Nous.Memory.Entry.new(%{content: "User likes dark mode"})
      {:ok, store_state} = Nous.Memory.store(Nous.Memory.Store.ETS, store_state, entry)

  """
  @spec store(module(), term(), Entry.t()) :: {:ok, term()} | {:error, term()}
  def store(store_mod, store_state, entry) do
    store_mod.store(store_state, entry)
  end

  @doc """
  Search memories directly (bypassing agent tools).

  ## Examples

      {:ok, results} = Nous.Memory.search(Nous.Memory.Store.ETS, store_state, "dark mode")

  """
  @spec search(module(), term(), String.t(), module() | nil, keyword()) ::
          {:ok, [{Entry.t(), float()}]}
  def search(store_mod, store_state, query, embedding_provider \\ nil, opts \\ []) do
    Search.search(store_mod, store_state, query, embedding_provider, opts)
  end
end
