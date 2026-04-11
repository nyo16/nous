defmodule Nous.KnowledgeBase.DocumentTest do
  use ExUnit.Case, async: true

  alias Nous.KnowledgeBase.Document

  describe "new/1" do
    test "creates document with required title and content" do
      doc = Document.new(%{title: "GenServer Guide", content: "# GenServer\nHow to use..."})

      assert doc.title == "GenServer Guide"
      assert doc.content == "# GenServer\nHow to use..."
      assert is_binary(doc.id)
      assert byte_size(doc.id) == 32
    end

    test "defaults doc_type to :markdown" do
      doc = Document.new(%{title: "test", content: "test"})
      assert doc.doc_type == :markdown
    end

    test "defaults status to :pending" do
      doc = Document.new(%{title: "test", content: "test"})
      assert doc.status == :pending
    end

    test "defaults metadata to empty map" do
      doc = Document.new(%{title: "test", content: "test"})
      assert doc.metadata == %{}
    end

    test "defaults compiled_entry_ids to empty list" do
      doc = Document.new(%{title: "test", content: "test"})
      assert doc.compiled_entry_ids == []
    end

    test "auto-generates checksum from content" do
      doc = Document.new(%{title: "test", content: "hello"})
      assert is_binary(doc.checksum)
      assert byte_size(doc.checksum) == 64

      # Same content = same checksum
      doc2 = Document.new(%{title: "other title", content: "hello"})
      assert doc.checksum == doc2.checksum
    end

    test "different content produces different checksums" do
      doc1 = Document.new(%{title: "test", content: "hello"})
      doc2 = Document.new(%{title: "test", content: "world"})
      assert doc1.checksum != doc2.checksum
    end

    test "auto-generates id and timestamps" do
      doc = Document.new(%{title: "test", content: "test"})

      assert is_binary(doc.id)
      assert %DateTime{} = doc.created_at
      assert %DateTime{} = doc.updated_at
    end

    test "accepts all optional fields" do
      now = DateTime.utc_now()

      doc =
        Document.new(%{
          title: "My Article",
          content: "body text",
          doc_type: :url,
          source_url: "https://example.com",
          source_path: "/tmp/article.md",
          status: :compiled,
          metadata: %{author: "Alice"},
          compiled_entry_ids: ["entry-1"],
          kb_id: "my-kb",
          created_at: now,
          updated_at: now
        })

      assert doc.doc_type == :url
      assert doc.source_url == "https://example.com"
      assert doc.source_path == "/tmp/article.md"
      assert doc.status == :compiled
      assert doc.metadata == %{author: "Alice"}
      assert doc.compiled_entry_ids == ["entry-1"]
      assert doc.kb_id == "my-kb"
      assert doc.created_at == now
    end

    test "allows custom id" do
      doc = Document.new(%{title: "test", content: "test", id: "custom-id"})
      assert doc.id == "custom-id"
    end

    test "allows custom checksum" do
      doc = Document.new(%{title: "test", content: "test", checksum: "custom-checksum"})
      assert doc.checksum == "custom-checksum"
    end

    test "raises on missing title" do
      assert_raise KeyError, fn ->
        Document.new(%{content: "test"})
      end
    end

    test "raises on missing content" do
      assert_raise KeyError, fn ->
        Document.new(%{title: "test"})
      end
    end
  end

  describe "compute_checksum/1" do
    test "produces consistent SHA-256 hex string" do
      assert Document.compute_checksum("hello") == Document.compute_checksum("hello")
      assert byte_size(Document.compute_checksum("hello")) == 64
    end

    test "different inputs produce different checksums" do
      assert Document.compute_checksum("a") != Document.compute_checksum("b")
    end
  end
end
