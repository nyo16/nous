defmodule Nous.KnowledgeBaseTest do
  use ExUnit.Case, async: true

  alias Nous.KnowledgeBase
  alias Nous.KnowledgeBase.Entry
  alias Nous.KnowledgeBase.Store.ETS

  setup do
    {:ok, state} = ETS.init([])
    %{state: state}
  end

  # Renamed from a `get_` prefix in the arch F-10 sweep; see the CHANGELOG. The
  # semantics never changed — `{:ok, entry} | {:error, :not_found}`, never a
  # default — so the name was the thing that was wrong.
  describe "fetch_entry/3" do
    test "resolves by slug", %{state: state} do
      entry = Entry.new(%{title: "GenServer Patterns", content: "body"})
      {:ok, _} = ETS.store_entry(state, entry)

      assert {:ok, found} = KnowledgeBase.fetch_entry(ETS, state, entry.slug)
      assert found.id == entry.id
    end

    test "falls back to ID when the slug lookup misses", %{state: state} do
      entry = Entry.new(%{title: "GenServer Patterns", content: "body"})
      {:ok, _} = ETS.store_entry(state, entry)

      # The ID is not a slug, so the first lookup must miss and the second hit.
      refute entry.id == entry.slug
      assert {:error, :not_found} = ETS.fetch_entry_by_slug(state, entry.id)
      assert {:ok, found} = KnowledgeBase.fetch_entry(ETS, state, entry.id)
      assert found.id == entry.id
    end

    test "returns {:error, :not_found} rather than nil for a miss", %{state: state} do
      assert {:error, :not_found} = KnowledgeBase.fetch_entry(ETS, state, "no-such-entry")
    end
  end
end
