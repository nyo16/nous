defmodule Nous.KnowledgeBase.Store.ETSTest do
  use ExUnit.Case, async: true

  alias Nous.KnowledgeBase.{Document, Entry, Link}
  alias Nous.KnowledgeBase.Store.ETS

  setup do
    {:ok, state} = ETS.init([])
    %{state: state}
  end

  # ---------------------------------------------------------------------------
  # Init
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "creates state with three ETS tables" do
      {:ok, state} = ETS.init([])
      assert is_reference(state.documents)
      assert is_reference(state.entries)
      assert is_reference(state.links)
    end
  end

  # ---------------------------------------------------------------------------
  # Document CRUD
  # ---------------------------------------------------------------------------

  describe "store_document/2 and fetch_document/2" do
    test "roundtrip stores and fetches a document", %{state: state} do
      doc = Document.new(%{title: "Test Doc", content: "Hello"})
      {:ok, _} = ETS.store_document(state, doc)

      assert {:ok, fetched} = ETS.fetch_document(state, doc.id)
      assert fetched.id == doc.id
      assert fetched.title == "Test Doc"
    end

    test "fetch returns error for non-existent document", %{state: state} do
      assert {:error, :not_found} = ETS.fetch_document(state, "nonexistent")
    end
  end

  describe "update_document/3" do
    test "updates specific fields", %{state: state} do
      doc = Document.new(%{title: "Test", content: "body", status: :pending})
      {:ok, _} = ETS.store_document(state, doc)

      {:ok, _} = ETS.update_document(state, doc.id, %{status: :compiled})

      {:ok, updated} = ETS.fetch_document(state, doc.id)
      assert updated.status == :compiled
    end

    test "returns error when document not found", %{state: state} do
      assert {:error, :not_found} =
               ETS.update_document(state, "nonexistent", %{status: :compiled})
    end
  end

  describe "delete_document/2" do
    test "removes a document", %{state: state} do
      doc = Document.new(%{title: "Test", content: "body"})
      {:ok, _} = ETS.store_document(state, doc)
      {:ok, _} = ETS.delete_document(state, doc.id)

      assert {:error, :not_found} = ETS.fetch_document(state, doc.id)
    end
  end

  describe "list_documents/2" do
    test "lists all documents", %{state: state} do
      for i <- 1..3 do
        doc = Document.new(%{title: "Doc #{i}", content: "content #{i}"})
        ETS.store_document(state, doc)
      end

      {:ok, docs} = ETS.list_documents(state, [])
      assert length(docs) == 3
    end

    test "filters by kb_id", %{state: state} do
      d1 = Document.new(%{title: "A", content: "a", kb_id: "kb1"})
      d2 = Document.new(%{title: "B", content: "b", kb_id: "kb2"})
      ETS.store_document(state, d1)
      ETS.store_document(state, d2)

      {:ok, docs} = ETS.list_documents(state, kb_id: "kb1")
      assert length(docs) == 1
      assert hd(docs).kb_id == "kb1"
    end

    test "filters by status", %{state: state} do
      d1 = Document.new(%{title: "A", content: "a", status: :pending})
      d2 = Document.new(%{title: "B", content: "b", status: :compiled})
      ETS.store_document(state, d1)
      ETS.store_document(state, d2)

      {:ok, docs} = ETS.list_documents(state, status: :compiled)
      assert length(docs) == 1
      assert hd(docs).status == :compiled
    end
  end

  # ---------------------------------------------------------------------------
  # Entry CRUD + search
  # ---------------------------------------------------------------------------

  describe "store_entry/2 and fetch_entry/2" do
    test "roundtrip stores and fetches an entry", %{state: state} do
      entry = Entry.new(%{title: "GenServer", content: "# GenServer\n..."})
      {:ok, _} = ETS.store_entry(state, entry)

      assert {:ok, fetched} = ETS.fetch_entry(state, entry.id)
      assert fetched.id == entry.id
      assert fetched.title == "GenServer"
    end

    test "fetch returns error for non-existent entry", %{state: state} do
      assert {:error, :not_found} = ETS.fetch_entry(state, "nonexistent")
    end
  end

  describe "fetch_entry_by_slug/2" do
    test "finds entry by slug", %{state: state} do
      entry = Entry.new(%{title: "GenServer Patterns", content: "content"})
      {:ok, _} = ETS.store_entry(state, entry)

      assert {:ok, fetched} = ETS.fetch_entry_by_slug(state, "genserver-patterns")
      assert fetched.id == entry.id
    end

    test "returns error for non-existent slug", %{state: state} do
      assert {:error, :not_found} = ETS.fetch_entry_by_slug(state, "nonexistent")
    end
  end

  describe "update_entry/3" do
    test "updates specific fields", %{state: state} do
      entry = Entry.new(%{title: "Test", content: "old", confidence: 0.5})
      {:ok, _} = ETS.store_entry(state, entry)

      {:ok, _} = ETS.update_entry(state, entry.id, %{confidence: 0.9, content: "new"})

      {:ok, updated} = ETS.fetch_entry(state, entry.id)
      assert updated.confidence == 0.9
      assert updated.content == "new"
    end

    test "returns error when entry not found", %{state: state} do
      assert {:error, :not_found} = ETS.update_entry(state, "nonexistent", %{confidence: 1.0})
    end
  end

  describe "delete_entry/2" do
    test "removes an entry", %{state: state} do
      entry = Entry.new(%{title: "Test", content: "body"})
      {:ok, _} = ETS.store_entry(state, entry)
      {:ok, _} = ETS.delete_entry(state, entry.id)

      assert {:error, :not_found} = ETS.fetch_entry(state, entry.id)
    end
  end

  describe "list_entries/2" do
    test "lists all entries", %{state: state} do
      for i <- 1..3 do
        entry = Entry.new(%{title: "Entry #{i}", content: "content #{i}"})
        ETS.store_entry(state, entry)
      end

      {:ok, entries} = ETS.list_entries(state, [])
      assert length(entries) == 3
    end

    test "filters by kb_id", %{state: state} do
      e1 = Entry.new(%{title: "A", content: "a", kb_id: "kb1"})
      e2 = Entry.new(%{title: "B", content: "b", kb_id: "kb2"})
      ETS.store_entry(state, e1)
      ETS.store_entry(state, e2)

      {:ok, entries} = ETS.list_entries(state, kb_id: "kb1")
      assert length(entries) == 1
    end

    test "filters by entry_type", %{state: state} do
      e1 = Entry.new(%{title: "A", content: "a", entry_type: :article})
      e2 = Entry.new(%{title: "B", content: "b", entry_type: :concept})
      ETS.store_entry(state, e1)
      ETS.store_entry(state, e2)

      {:ok, entries} = ETS.list_entries(state, entry_type: :concept)
      assert length(entries) == 1
      assert hd(entries).entry_type == :concept
    end

    test "filters by tags", %{state: state} do
      e1 = Entry.new(%{title: "A", content: "a", tags: ["elixir", "otp"]})
      e2 = Entry.new(%{title: "B", content: "b", tags: ["python"]})
      ETS.store_entry(state, e1)
      ETS.store_entry(state, e2)

      {:ok, entries} = ETS.list_entries(state, tags: ["otp"])
      assert length(entries) == 1
      assert hd(entries).title == "A"
    end

    test "filters by concepts", %{state: state} do
      e1 = Entry.new(%{title: "A", content: "a", concepts: ["genserver", "supervision"]})
      e2 = Entry.new(%{title: "B", content: "b", concepts: ["ecto"]})
      ETS.store_entry(state, e1)
      ETS.store_entry(state, e2)

      {:ok, entries} = ETS.list_entries(state, concepts: ["supervision"])
      assert length(entries) == 1
      assert hd(entries).title == "A"
    end

    test "respects limit", %{state: state} do
      for i <- 1..5 do
        entry = Entry.new(%{title: "Entry #{i}", content: "content #{i}"})
        ETS.store_entry(state, entry)
      end

      {:ok, entries} = ETS.list_entries(state, limit: 2)
      assert length(entries) == 2
    end
  end

  describe "search_entries/3" do
    test "finds entries by fuzzy text match", %{state: state} do
      e1 = Entry.new(%{title: "GenServer Patterns", content: "How to use GenServer in Elixir"})
      e2 = Entry.new(%{title: "Ecto Schemas", content: "Database schemas with Ecto"})
      ETS.store_entry(state, e1)
      ETS.store_entry(state, e2)

      {:ok, results} = ETS.search_entries(state, "GenServer", [])

      assert length(results) > 0
      {top_entry, _score} = hd(results)
      assert top_entry.title == "GenServer Patterns"
    end

    test "respects limit", %{state: state} do
      for i <- 1..5 do
        entry = Entry.new(%{title: "Entry #{i}", content: "content #{i}"})
        ETS.store_entry(state, entry)
      end

      {:ok, results} = ETS.search_entries(state, "entry", limit: 2)
      assert length(results) == 2
    end

    test "respects min_score", %{state: state} do
      entry = Entry.new(%{title: "Completely Unrelated", content: "xyz abc 123"})
      ETS.store_entry(state, entry)

      {:ok, results} = ETS.search_entries(state, "GenServer patterns OTP", min_score: 0.9)
      assert results == []
    end

    test "filters by kb_id", %{state: state} do
      e1 = Entry.new(%{title: "GenServer", content: "content", kb_id: "kb1"})
      e2 = Entry.new(%{title: "GenServer", content: "content", kb_id: "kb2"})
      ETS.store_entry(state, e1)
      ETS.store_entry(state, e2)

      {:ok, results} = ETS.search_entries(state, "GenServer", kb_id: "kb1")
      assert length(results) == 1
      {found, _} = hd(results)
      assert found.kb_id == "kb1"
    end
  end

  # ---------------------------------------------------------------------------
  # Link CRUD + graph
  # ---------------------------------------------------------------------------

  describe "store_link/2 and backlinks/outlinks" do
    setup %{state: state} do
      e1 = Entry.new(%{title: "A", content: "a", id: "entry-a"})
      e2 = Entry.new(%{title: "B", content: "b", id: "entry-b"})
      e3 = Entry.new(%{title: "C", content: "c", id: "entry-c"})
      ETS.store_entry(state, e1)
      ETS.store_entry(state, e2)
      ETS.store_entry(state, e3)

      # A -> B, A -> C
      link1 = Link.new(%{from_entry_id: "entry-a", to_entry_id: "entry-b"})
      link2 = Link.new(%{from_entry_id: "entry-a", to_entry_id: "entry-c"})
      ETS.store_link(state, link1)
      ETS.store_link(state, link2)

      %{state: state}
    end

    test "backlinks returns links pointing to an entry", %{state: state} do
      {:ok, links} = ETS.backlinks(state, "entry-b")
      assert length(links) == 1
      assert hd(links).from_entry_id == "entry-a"
    end

    test "outlinks returns links from an entry", %{state: state} do
      {:ok, links} = ETS.outlinks(state, "entry-a")
      assert length(links) == 2
    end

    test "backlinks returns empty for no incoming links", %{state: state} do
      {:ok, links} = ETS.backlinks(state, "entry-a")
      assert links == []
    end
  end

  describe "delete_link/2" do
    test "removes a link", %{state: state} do
      link = Link.new(%{from_entry_id: "a", to_entry_id: "b"})
      {:ok, _} = ETS.store_link(state, link)
      {:ok, _} = ETS.delete_link(state, link.id)

      {:ok, links} = ETS.backlinks(state, "b")
      assert links == []
    end
  end

  describe "related_entries/3" do
    test "finds entries connected by links", %{state: state} do
      e1 = Entry.new(%{title: "A", content: "a", id: "e1"})
      e2 = Entry.new(%{title: "B", content: "b", id: "e2"})
      e3 = Entry.new(%{title: "C", content: "c", id: "e3"})
      ETS.store_entry(state, e1)
      ETS.store_entry(state, e2)
      ETS.store_entry(state, e3)

      # e1 -> e2, e3 -> e1
      ETS.store_link(state, Link.new(%{from_entry_id: "e1", to_entry_id: "e2"}))
      ETS.store_link(state, Link.new(%{from_entry_id: "e3", to_entry_id: "e1"}))

      {:ok, related} = ETS.related_entries(state, "e1", [])

      ids = Enum.map(related, & &1.id)
      assert "e2" in ids
      assert "e3" in ids
      assert "e1" not in ids
    end

    test "respects limit", %{state: state} do
      source = Entry.new(%{title: "Source", content: "s", id: "source"})
      ETS.store_entry(state, source)

      for i <- 1..5 do
        id = "target-#{i}"
        ETS.store_entry(state, Entry.new(%{title: "T#{i}", content: "t", id: id}))
        ETS.store_link(state, Link.new(%{from_entry_id: "source", to_entry_id: id}))
      end

      {:ok, related} = ETS.related_entries(state, "source", limit: 2)
      assert length(related) == 2
    end

    test "returns empty for isolated entry", %{state: state} do
      entry = Entry.new(%{title: "Isolated", content: "alone", id: "isolated"})
      ETS.store_entry(state, entry)

      {:ok, related} = ETS.related_entries(state, "isolated", [])
      assert related == []
    end
  end
end
