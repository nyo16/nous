defmodule Nous.MemoryStoreConformance do
  @moduledoc """
  Shared behaviour-conformance tests for `Nous.Memory.Store` implementations.

  Each backend gets the same battery of contract tests by `use`-ing this module
  with its store module and init opts:

      defmodule Nous.Memory.Store.ETSConformanceTest do
        use Nous.MemoryStoreConformance, store: Nous.Memory.Store.ETS
      end

  Native-dep backends (SQLite/DuckDB/Zvec/Muninn) adopt the same suite behind a
  tag so they only run where the dep is installed:

      defmodule Nous.Memory.Store.SQLiteConformanceTest do
        use Nous.MemoryStoreConformance,
          store: Nous.Memory.Store.SQLite,
          init_opts: [path: ":memory:"],
          tag: :sqlite
      end

  Only the `Nous.Memory.Store` contract is exercised here — `search_vector/3` is
  optional (ETS does not implement it) and is covered separately.
  """

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)
    init_opts = Keyword.get(opts, :init_opts, [])
    tag = Keyword.get(opts, :tag)

    quote bind_quoted: [store: store, init_opts: init_opts, tag: tag] do
      use ExUnit.Case, async: true

      alias Nous.Memory.Entry

      @store store
      @init_opts init_opts

      if tag, do: @moduletag(tag)

      setup do
        {:ok, state} = @store.init(@init_opts)
        %{state: state}
      end

      defp put(state, attrs) do
        entry = Entry.new(attrs)
        {:ok, state} = @store.store(state, entry)
        {state, entry}
      end

      test "store/2 then fetch/2 round-trips an entry", %{state: state} do
        {state, entry} = put(state, %{content: "the quick brown fox"})

        assert {:ok, fetched} = @store.fetch(state, entry.id)
        assert fetched.id == entry.id
        assert fetched.content == "the quick brown fox"
      end

      test "fetch/2 returns {:error, :not_found} for a missing id", %{state: state} do
        assert {:error, :not_found} = @store.fetch(state, "does-not-exist")
      end

      test "delete/2 removes an entry", %{state: state} do
        {state, entry} = put(state, %{content: "ephemeral"})
        assert {:ok, state} = @store.delete(state, entry.id)
        assert {:error, :not_found} = @store.fetch(state, entry.id)
      end

      test "update/3 modifies fields and bumps updated_at", %{state: state} do
        {state, entry} = put(state, %{content: "before", importance: 0.5})
        # Ensure a measurable time delta for updated_at.
        Process.sleep(2)

        assert {:ok, state} = @store.update(state, entry.id, %{content: "after", importance: 0.9})
        assert {:ok, updated} = @store.fetch(state, entry.id)
        assert updated.content == "after"
        assert updated.importance == 0.9
        assert DateTime.compare(updated.updated_at, entry.updated_at) in [:gt, :eq]
      end

      test "update/3 on a missing id returns {:error, :not_found}", %{state: state} do
        assert {:error, :not_found} = @store.update(state, "nope", %{content: "x"})
      end

      test "list/2 returns all stored entries", %{state: state} do
        {state, a} = put(state, %{content: "alpha"})
        {state, b} = put(state, %{content: "beta"})

        assert {:ok, entries} = @store.list(state, [])
        ids = Enum.map(entries, & &1.id)
        assert a.id in ids
        assert b.id in ids
      end

      test "list/2 filters by scope", %{state: state} do
        {state, mine} = put(state, %{content: "mine", agent_id: "a1"})
        {state, _theirs} = put(state, %{content: "theirs", agent_id: "a2"})

        assert {:ok, entries} = @store.list(state, scope: %{agent_id: "a1"})
        assert Enum.map(entries, & &1.id) == [mine.id]
      end

      test "search_text/3 returns {entry, score} tuples ranked by relevance", %{state: state} do
        {state, _} = put(state, %{content: "elixir concurrency with otp"})
        {state, _} = put(state, %{content: "completely unrelated cooking recipe"})

        assert {:ok, results} = @store.search_text(state, "elixir otp", limit: 10)
        assert is_list(results)
        assert [{%Entry{} = top, score} | _] = results
        assert is_float(score)
        assert top.content =~ "elixir"
      end

      test "search_text/3 respects the :limit option", %{state: state} do
        state =
          Enum.reduce(1..5, state, fn i, acc ->
            {acc, _} = put(acc, %{content: "match number #{i}"})
            acc
          end)

        assert {:ok, results} = @store.search_text(state, "match number", limit: 2)
        assert length(results) <= 2
      end

      test "search_text/3 filters by scope", %{state: state} do
        {state, _} = put(state, %{content: "scoped hit", user_id: "u1"})
        {state, _} = put(state, %{content: "scoped hit", user_id: "u2"})

        assert {:ok, results} = @store.search_text(state, "scoped hit", scope: %{user_id: "u1"})
        assert Enum.all?(results, fn {entry, _score} -> entry.user_id == "u1" end)
      end
    end
  end
end
