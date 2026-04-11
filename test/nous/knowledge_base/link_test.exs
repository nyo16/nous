defmodule Nous.KnowledgeBase.LinkTest do
  use ExUnit.Case, async: true

  alias Nous.KnowledgeBase.Link

  describe "new/1" do
    test "creates link with required from and to entry IDs" do
      link = Link.new(%{from_entry_id: "entry-1", to_entry_id: "entry-2"})

      assert link.from_entry_id == "entry-1"
      assert link.to_entry_id == "entry-2"
      assert is_binary(link.id)
      assert byte_size(link.id) == 32
    end

    test "defaults link_type to :cross_reference" do
      link = Link.new(%{from_entry_id: "a", to_entry_id: "b"})
      assert link.link_type == :cross_reference
    end

    test "defaults weight to 1.0" do
      link = Link.new(%{from_entry_id: "a", to_entry_id: "b"})
      assert link.weight == 1.0
    end

    test "auto-generates id and timestamp" do
      link = Link.new(%{from_entry_id: "a", to_entry_id: "b"})

      assert is_binary(link.id)
      assert %DateTime{} = link.created_at
    end

    test "accepts all optional fields" do
      now = DateTime.utc_now()

      link =
        Link.new(%{
          from_entry_id: "entry-1",
          to_entry_id: "entry-2",
          link_type: :backlink,
          label: "See also",
          weight: 0.8,
          kb_id: "my-kb",
          created_at: now
        })

      assert link.link_type == :backlink
      assert link.label == "See also"
      assert link.weight == 0.8
      assert link.kb_id == "my-kb"
      assert link.created_at == now
    end

    test "allows custom id" do
      link = Link.new(%{from_entry_id: "a", to_entry_id: "b", id: "custom-id"})
      assert link.id == "custom-id"
    end

    test "raises on missing from_entry_id" do
      assert_raise KeyError, fn ->
        Link.new(%{to_entry_id: "b"})
      end
    end

    test "raises on missing to_entry_id" do
      assert_raise KeyError, fn ->
        Link.new(%{from_entry_id: "a"})
      end
    end
  end
end
