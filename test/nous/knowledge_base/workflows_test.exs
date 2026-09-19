defmodule Nous.KnowledgeBase.WorkflowsTest do
  use ExUnit.Case, async: true

  alias Nous.KnowledgeBase.{Entry, Link, Workflows}
  alias Nous.KnowledgeBase.Store.ETS
  alias Nous.Workflow.State

  # A store double that deliberately does NOT export link_counts_by_source/1,
  # so gather_kb_statistics/1 takes the per-entry outlinks/2 compatibility path
  # kept for backends written before that optional callback existed.
  defmodule LegacyStore do
    defdelegate list_entries(state, opts), to: ETS
    defdelegate list_documents(state, opts), to: ETS
    defdelegate outlinks(state, entry_id), to: ETS
  end

  # A deliberately buggy embedding provider: embed_batch/2 returns a single
  # vector regardless of input size. embed/2 is deterministic per text, so the
  # per-entry fallback path is observable in the result.
  defmodule MismatchEmbedding do
    @behaviour Nous.Memory.Embedding

    @impl true
    def embed(text, _opts), do: {:ok, [String.length(text) * 1.0]}

    @impl true
    def embed_batch(_texts, _opts), do: {:ok, [[0.0]]}

    @impl true
    def dimension, do: 1
  end

  # A well-behaved batch provider whose embed/2 answers differ from
  # embed_batch/2, so the test can tell which path produced the vectors.
  defmodule BatchEmbedding do
    @behaviour Nous.Memory.Embedding

    @impl true
    def embed(_text, _opts), do: {:ok, [-1.0]}

    @impl true
    def embed_batch(texts, _opts), do: {:ok, Enum.map(texts, &[String.length(&1) * 1.0])}

    @impl true
    def dimension, do: 1
  end

  setup do
    {:ok, kb} = ETS.init([])

    for id <- ~w(a b c) do
      ETS.store_entry(
        kb,
        Entry.new(%{title: String.upcase(id), content: id, id: id, kb_id: "kb1"})
      )
    end

    # a -> b, a -> c, b -> c
    ETS.store_link(kb, Link.new(%{from_entry_id: "a", to_entry_id: "b", kb_id: "kb1"}))
    ETS.store_link(kb, Link.new(%{from_entry_id: "a", to_entry_id: "c", kb_id: "kb1"}))
    ETS.store_link(kb, Link.new(%{from_entry_id: "b", to_entry_id: "c", kb_id: "kb1"}))

    %{kb: kb}
  end

  describe "health check :gather_stats node" do
    test "counts entries and links by source", %{kb: kb} do
      state = gather_stats(ETS, kb)

      assert state.data.stats == %{total_entries: 3, total_links: 3, total_documents: 0}
      assert summaries(state) == [{"a", 2}, {"b", 1}, {"c", 0}]
    end

    test "the per-entry fallback produces identical statistics", %{kb: kb} do
      bulk = gather_stats(ETS, kb)
      legacy = gather_stats(LegacyStore, kb)

      assert legacy.data.stats == bulk.data.stats
      assert summaries(legacy) == summaries(bulk)
    end

    test "handles an empty knowledge base on both paths" do
      {:ok, empty} = ETS.init([])

      for store <- [ETS, LegacyStore] do
        state = gather_stats(store, empty)

        assert state.data.stats == %{total_entries: 0, total_links: 0, total_documents: 0}
        assert state.data.entry_summaries == []
      end
    end
  end

  describe "ingest pipeline :embed_entries node" do
    test "a batch result with the wrong number of vectors falls back per entry, dropping none" do
      state = embed_entries(MismatchEmbedding)

      # "alpha" -> [5.0], "beta" -> [4.0]: both entries kept, embedded via
      # the per-entry fallback rather than zipped against the short batch.
      assert Enum.map(state.data.compiled_entries, & &1.embedding) == [[5.0], [4.0]]
    end

    test "a batch result with matching length is zipped in order" do
      state = embed_entries(BatchEmbedding)

      assert Enum.map(state.data.compiled_entries, & &1.embedding) == [[5.0], [4.0]]
    end
  end

  # The :gather_stats node holds a capture of the private transform, which is
  # the only way to exercise it without running the LLM audit step behind it.
  defp gather_stats(store_mod, kb_state) do
    transform_fn =
      Workflows.build_health_check_pipeline()
      |> Map.fetch!(:nodes)
      |> Map.fetch!("gather_stats")
      |> Map.fetch!(:config)
      |> Map.fetch!(:transform_fn)

    transform_fn.(
      State.new(%{kb_config: %{store: store_mod, store_state: kb_state, kb_id: "kb1"}})
    )
  end

  defp summaries(state) do
    state.data.entry_summaries
    |> Enum.map(&{&1.slug, &1.link_count})
    |> Enum.sort()
  end

  @embed_entries_json ~s([{"title":"A","slug":"a","content":"alpha"},{"title":"B","slug":"b","content":"beta"}])

  defp embed_entries(provider) do
    transform_fn =
      Workflows.build_ingest_pipeline(embedding: provider)
      |> Map.fetch!(:nodes)
      |> Map.fetch!("embed_entries")
      |> Map.fetch!(:config)
      |> Map.fetch!(:transform_fn)

    transform_fn.(State.new(%{compile_entries: @embed_entries_json}))
  end
end
