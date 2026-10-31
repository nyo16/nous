defmodule Nous.KnowledgeBase.ToolsTest do
  use ExUnit.Case, async: true

  alias Nous.KnowledgeBase.{Entry, Link, Tools}
  alias Nous.KnowledgeBase.Store.ETS

  # A store without the optional link_endpoints/1 callback: the health check
  # falls back to outlinks/2 per entry, which must give the same report.
  defmodule NoEndpointsStore do
    defdelegate list_entries(state, opts), to: ETS
    defdelegate list_documents(state, opts), to: ETS
    defdelegate outlinks(state, entry_id), to: ETS
    defdelegate backlinks(state, entry_id), to: ETS
  end

  defp build_ctx(state, opts \\ []) do
    kb_config =
      %{
        store: Keyword.get(opts, :store, ETS),
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

  describe "kb_health_check/2 in a store shared by several kb_ids (#97)" do
    # kb1: a -> b (internal), and `lonely`, linked only from kb2 by a link
    # created before kb_link refused cross-KB links. kb2: x -> y.
    setup %{state: state} do
      for {id, kb} <- [{"a", "kb1"}, {"b", "kb1"}, {"lonely", "kb1"}, {"x", "kb2"}, {"y", "kb2"}] do
        ETS.store_entry(state, Entry.new(%{id: id, title: id, content: id, kb_id: kb}))
      end

      for {from, to} <- [{"a", "b"}, {"x", "y"}, {"x", "lonely"}] do
        ETS.store_link(state, Link.new(%{from_entry_id: from, to_entry_id: to}))
      end

      :ok
    end

    defp orphan_titles(result) do
      for %{type: "orphan", description: d} <- result.issues,
          [_, title] = Regex.run(~r/Entry '([^']+)'/, d),
          do: title
    end

    test "counts and judges only links with both ends in the configured kb", %{state: state} do
      for store <- [ETS, NoEndpointsStore] do
        {:ok, result, _} =
          Tools.kb_health_check(build_ctx(state, kb_id: "kb1", store: store), %{})

        assert result.total_entries == 3, inspect(store)
        # a -> b only; x -> y and x -> lonely belong to kb2.
        assert result.total_links == 1, inspect(store)

        # b has an incoming kb1 link, so it is not an orphan; lonely is only
        # linked from kb2, so for kb1 it is.
        assert Enum.sort(orphan_titles(result)) == ["lonely"], inspect(store)
      end
    end
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

  # Issue #88: two namespaces sharing one store. Driven through
  # Nous.ToolExecutor with a RunContext, the way the agent loop calls the tools.
  describe "kb_id isolation (#88)" do
    # A third-party store that predates fetch_entry_by_slug/3: only the
    # unscoped /2 lookups exist, so isolation rests on the post-fetch check.
    defmodule LegacySlugStore do
      alias Nous.KnowledgeBase.Store.ETS

      defdelegate fetch_entry_by_slug(state, slug), to: ETS
      defdelegate fetch_entry(state, id), to: ETS
      defdelegate store_link(state, link), to: ETS
      defdelegate backlinks(state, entry_id), to: ETS
    end

    setup %{state: state} do
      # Same title -> same slug in both namespaces. "b" writes last, so the
      # store-wide slug index points at b's entry.
      a_notes = Entry.new(%{title: "Shared Notes", content: "a's notes", kb_id: "a"})
      a_other = Entry.new(%{title: "Roadmap", content: "a's roadmap", kb_id: "a"})
      b_notes = Entry.new(%{title: "Shared Notes", content: "b's notes", kb_id: "b"})
      b_secret = Entry.new(%{title: "Q3 Board Minutes", content: "b secret", kb_id: "b"})

      for entry <- [a_notes, a_other, b_notes, b_secret], do: ETS.store_entry(state, entry)

      %{a_notes: a_notes, a_other: a_other, b_notes: b_notes, b_secret: b_secret}
    end

    defp run_tool(state, kb_id, name, args, store \\ ETS) do
      tool = Enum.find(Tools.all_tools(), &(&1.name == name))
      ctx = Nous.RunContext.new(%{kb_config: %{store: store, store_state: state, kb_id: kb_id}})
      {:ok, result, _update} = Nous.ToolExecutor.execute(tool, args, ctx)
      result
    end

    test "kb_read can't see another namespace's entry by slug or id",
         %{state: state, b_secret: b_secret} do
      for key <- [b_secret.slug, b_secret.id] do
        result = run_tool(state, "a", "kb_read", %{"slug_or_id" => key})
        assert result.status == "not_found"
        refute Map.has_key?(result, :content)
      end
    end

    test "kb_read resolves a shared slug to the caller's own namespace",
         %{state: state, a_notes: a_notes, b_notes: b_notes} do
      result = run_tool(state, "a", "kb_read", %{"slug_or_id" => "shared-notes"})
      assert result.id == a_notes.id
      assert result.content == "a's notes"

      result = run_tool(state, "b", "kb_read", %{"slug_or_id" => "shared-notes"})
      assert result.id == b_notes.id

      assert run_tool(state, "a", "kb_read", %{"slug_or_id" => a_notes.id}).id == a_notes.id
    end

    test "kb_link can't attach a link to another namespace's entry",
         %{state: state, a_notes: a_notes, b_secret: b_secret} do
      for {from, to} <- [{"shared-notes", b_secret.slug}, {b_secret.id, a_notes.id}] do
        result = run_tool(state, "a", "kb_link", %{"from_slug" => from, "to_slug" => to})
        assert result.status == "error"
      end

      assert {:ok, []} = ETS.backlinks(state, b_secret.id)
      assert {:ok, []} = ETS.outlinks(state, b_secret.id)
    end

    test "kb_link within the namespace still links",
         %{state: state, a_notes: a_notes, a_other: a_other} do
      result =
        run_tool(state, "a", "kb_link", %{"from_slug" => "roadmap", "to_slug" => "shared-notes"})

      assert result.status == "linked"
      assert {:ok, [link]} = ETS.backlinks(state, a_notes.id)
      assert link.from_entry_id == a_other.id
      assert link.kb_id == "a"
    end

    test "kb_backlinks can't see another namespace's entry or its links",
         %{state: state, a_notes: a_notes, a_other: a_other, b_secret: b_secret} do
      ETS.store_link(state, Link.new(%{from_entry_id: a_notes.id, to_entry_id: b_secret.id}))
      # A cross-namespace link written straight into the store (e.g. before
      # kb_link was scoped): its foreign source must not be listed.
      ETS.store_link(state, Link.new(%{from_entry_id: b_secret.id, to_entry_id: a_notes.id}))
      ETS.store_link(state, Link.new(%{from_entry_id: a_other.id, to_entry_id: a_notes.id}))

      result = run_tool(state, "a", "kb_backlinks", %{"slug_or_id" => b_secret.slug})
      assert result.status == "not_found"

      result = run_tool(state, "a", "kb_backlinks", %{"slug_or_id" => "shared-notes"})
      assert result.entry == "shared-notes"
      assert Enum.map(result.backlinks, & &1.slug) == ["roadmap"]
    end

    test "a store without fetch_entry_by_slug/3 still never returns a foreign entry",
         %{state: state, b_secret: b_secret} do
      result =
        run_tool(state, "a", "kb_read", %{"slug_or_id" => b_secret.slug}, LegacySlugStore)

      assert result.status == "not_found"

      result =
        run_tool(
          state,
          "a",
          "kb_link",
          %{"from_slug" => "roadmap", "to_slug" => b_secret.id},
          LegacySlugStore
        )

      assert result.status == "error"
      assert {:ok, []} = ETS.backlinks(state, b_secret.id)

      result = run_tool(state, "a", "kb_read", %{"slug_or_id" => "roadmap"}, LegacySlugStore)
      assert result.content == "a's roadmap"
    end
  end
end
