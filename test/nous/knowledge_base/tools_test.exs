defmodule Nous.KnowledgeBase.ToolsTest do
  use ExUnit.Case, async: true

  alias Nous.KnowledgeBase.{Entry, Link, Tools}
  alias Nous.KnowledgeBase.Store.ETS

  defp build_ctx(state, opts \\ []) do
    kb_config =
      %{
        store: ETS,
        store_state: state,
        kb_id: Keyword.get(opts, :kb_id)
      }

    %Nous.Agent.Context{
      messages: [],
      deps: %{kb_config: kb_config}
    }
  end

  setup do
    {:ok, state} = ETS.init([])
    %{state: state}
  end

  describe "kb_search/2" do
    test "searches entries and returns formatted results", %{state: state} do
      entry =
        Entry.new(%{
          title: "GenServer Patterns",
          content: "How to use GenServer",
          summary: "A guide to GenServer"
        })

      ETS.store_entry(state, entry)

      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_search(ctx, %{"query" => "GenServer"})

      assert result.status == "found"
      assert result.count == 1
      assert hd(result.entries).slug == "genserver-patterns"
    end

    test "returns empty when no matches", %{state: state} do
      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_search(ctx, %{"query" => "nothing", "limit" => 5})

      assert result.status == "found"
      assert result.count == 0
    end

    test "returns error when store not initialized" do
      ctx = %Nous.Agent.Context{messages: [], deps: %{}}
      {:ok, result, _update} = Tools.kb_search(ctx, %{"query" => "test"})
      assert result.status == "error"
    end
  end

  describe "kb_read/2" do
    test "reads entry by slug", %{state: state} do
      entry = Entry.new(%{title: "GenServer Patterns", content: "body text"})
      ETS.store_entry(state, entry)

      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_read(ctx, %{"slug_or_id" => "genserver-patterns"})

      assert result.title == "GenServer Patterns"
      assert result.content == "body text"
    end

    test "reads entry by ID", %{state: state} do
      entry = Entry.new(%{title: "Test", content: "body", id: "my-id"})
      ETS.store_entry(state, entry)

      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_read(ctx, %{"slug_or_id" => "my-id"})

      assert result.title == "Test"
    end

    test "returns not_found for missing entry", %{state: state} do
      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_read(ctx, %{"slug_or_id" => "nonexistent"})

      assert result.status == "not_found"
    end
  end

  describe "kb_list/2" do
    test "lists all entries", %{state: state} do
      for i <- 1..3 do
        ETS.store_entry(state, Entry.new(%{title: "Entry #{i}", content: "c"}))
      end

      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_list(ctx, %{})

      assert result.status == "ok"
      assert result.count == 3
    end

    test "filters by tags", %{state: state} do
      ETS.store_entry(state, Entry.new(%{title: "A", content: "a", tags: ["elixir"]}))
      ETS.store_entry(state, Entry.new(%{title: "B", content: "b", tags: ["python"]}))

      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_list(ctx, %{"tags" => ["elixir"]})

      assert result.count == 1
      assert hd(result.entries).title == "A"
    end
  end

  describe "kb_ingest/2" do
    test "ingests a raw document", %{state: state} do
      ctx = build_ctx(state)

      {:ok, result, update} =
        Tools.kb_ingest(ctx, %{
          "title" => "My Article",
          "content" => "Article body text"
        })

      assert result.status == "ingested"
      assert is_binary(result.id)
      assert is_binary(result.checksum)

      # Verify the context update contains the new store state
      assert update.operations != []
    end
  end

  describe "kb_add_entry/2" do
    test "creates a wiki entry", %{state: state} do
      ctx = build_ctx(state)

      {:ok, result, _update} =
        Tools.kb_add_entry(ctx, %{
          "title" => "GenServer Patterns",
          "content" => "# GenServer\nUse GenServer for...",
          "summary" => "How to use GenServer",
          "concepts" => ["genserver", "otp"],
          "tags" => ["elixir"]
        })

      assert result.status == "created"
      assert result.slug == "genserver-patterns"

      # Verify it's actually in the store
      {:ok, entry} = ETS.fetch_entry_by_slug(state, "genserver-patterns")
      assert entry.concepts == ["genserver", "otp"]
    end
  end

  describe "kb_link/2" do
    test "creates a link between entries", %{state: state} do
      e1 = Entry.new(%{title: "GenServer", content: "a", id: "e1"})
      e2 = Entry.new(%{title: "Supervisor", content: "b", id: "e2"})
      ETS.store_entry(state, e1)
      ETS.store_entry(state, e2)

      ctx = build_ctx(state)

      {:ok, result, _update} =
        Tools.kb_link(ctx, %{
          "from_slug" => "genserver",
          "to_slug" => "supervisor",
          "link_type" => "see_also"
        })

      assert result.status == "linked"
      assert result.from == "genserver"
      assert result.to == "supervisor"
    end

    test "returns error for missing entry", %{state: state} do
      ctx = build_ctx(state)

      {:ok, result, _update} =
        Tools.kb_link(ctx, %{
          "from_slug" => "nonexistent",
          "to_slug" => "also-nonexistent"
        })

      assert result.status == "error"
    end
  end

  describe "kb_backlinks/2" do
    test "finds entries linking to a given entry", %{state: state} do
      e1 = Entry.new(%{title: "GenServer", content: "a", id: "e1"})
      e2 = Entry.new(%{title: "Supervisor", content: "b", id: "e2"})
      ETS.store_entry(state, e1)
      ETS.store_entry(state, e2)

      link = Link.new(%{from_entry_id: "e1", to_entry_id: "e2"})
      ETS.store_link(state, link)

      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_backlinks(ctx, %{"slug_or_id" => "supervisor"})

      assert result.status == "ok"
      assert result.backlink_count == 1
      assert hd(result.backlinks).slug == "genserver"
    end
  end

  describe "kb_health_check/2" do
    test "returns health report for empty KB", %{state: state} do
      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_health_check(ctx, %{})

      assert result.status == "ok"
      assert result.total_entries == 0
      assert result.total_documents == 0
    end

    test "identifies orphan entries", %{state: state} do
      entry = Entry.new(%{title: "Orphan", content: "no links or sources"})
      ETS.store_entry(state, entry)

      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_health_check(ctx, %{})

      assert result.issue_count > 0
      assert Enum.any?(result.issues, fn i -> i.type == "orphan" end)
    end

    test "identifies low confidence entries", %{state: state} do
      entry = Entry.new(%{title: "Uncertain", content: "maybe", confidence: 0.1})
      ETS.store_entry(state, entry)

      ctx = build_ctx(state)
      {:ok, result, _update} = Tools.kb_health_check(ctx, %{})

      assert Enum.any?(result.issues, fn i -> i.type == "low_confidence" end)
    end
  end

  describe "kb_generate/2" do
    test "generates a summary from entries", %{state: state} do
      ETS.store_entry(
        state,
        Entry.new(%{
          title: "GenServer Guide",
          content: "GenServer is an OTP behaviour...",
          summary: "How to use GenServer"
        })
      )

      ctx = build_ctx(state)

      {:ok, result, _update} =
        Tools.kb_generate(ctx, %{"topic" => "GenServer", "output_type" => "summary"})

      assert result.status == "generated"
      assert result.output_type == "summary"
      assert String.contains?(result.content, "GenServer")
    end

    test "generates slides in Marp format", %{state: state} do
      ETS.store_entry(
        state,
        Entry.new(%{
          title: "OTP Patterns",
          content: "Supervision trees...",
          summary: "OTP overview"
        })
      )

      ctx = build_ctx(state)

      {:ok, result, _update} =
        Tools.kb_generate(ctx, %{"topic" => "OTP", "output_type" => "slides"})

      assert result.status == "generated"
      assert String.contains?(result.content, "marp: true")
    end
  end
end
