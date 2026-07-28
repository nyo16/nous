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
end
