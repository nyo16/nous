defmodule Nous.KnowledgeBase.WorkflowsTest do
  use ExUnit.Case, async: true

  alias Nous.KnowledgeBase.{Document, Entry, Link, Workflows}
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

  defmodule EmbedEverything do
    @moduledoc false
    def embed(_text, _opts), do: {:ok, [1.0, 2.0]}
  end

  # Fails for exactly one body so the degrade-don't-discard path is observable
  # alongside a successful sibling in the same batch.
  defmodule EmbedUnlessBoom do
    @moduledoc false
    def embed("boom", _opts), do: {:error, :nope}
    def embed(_text, _opts), do: {:ok, [1.0, 2.0]}
  end

  # `store_state` is the test pid, so the search options can be asserted.
  defmodule RecordingSearchStore do
    @moduledoc false

    def search_entries(owner, query, opts) do
      send(owner, {:search_entries, query, opts})
      {:ok, [{Nous.KnowledgeBase.Entry.new(%{title: "Hit", content: "c"}), 0.9}]}
    end
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

  describe "health check :build_report node" do
    # The audit output is LLM-authored JSON, so `type` and `severity` are
    # whatever the model emitted. An unrecognised label used to crash the node.
    test "an unknown type and severity fall back instead of raising" do
      state =
        build_report("""
        [{"type": "no_such_issue_type_xyz",
          "entry_id": "a",
          "description": "d",
          "severity": "no_such_severity_xyz",
          "suggested_action": "s"}]
        """)

      assert [issue] = state.data.health_report.issues
      assert issue.type == :gap
      assert issue.severity == :low
      assert issue.entry_id == "a"
      assert issue.description == "d"
    end

    test "an omitted type and severity fall back to the documented defaults" do
      state = build_report(~s([{"entry_id": "a", "description": "d"}]))

      assert [issue] = state.data.health_report.issues
      assert issue.type == :gap
      assert issue.severity == :low
    end

    test "every declared type and severity still decodes to its atom" do
      pairs = [
        {"stale", :stale, "low", :low},
        {"inconsistent", :inconsistent, "medium", :medium},
        {"orphan", :orphan, "high", :high},
        {"gap", :gap, "low", :low},
        {"low_confidence", :low_confidence, "medium", :medium},
        {"duplicate", :duplicate, "high", :high}
      ]

      raw =
        Enum.map(pairs, fn {type, _, severity, _} ->
          %{"type" => type, "severity" => severity, "entry_id" => "a"}
        end)

      state = build_report(JSON.encode!(raw))

      assert Enum.map(state.data.health_report.issues, &{&1.type, &1.severity}) ==
               Enum.map(pairs, fn {_, type, _, severity} -> {type, severity} end)
    end
  end

  describe "pipeline shapes" do
    test "each builder wires the nodes its @doc advertises, with the right types" do
      # The node ids are the public surface: callers (and the helpers in this
      # file) address nodes by name, so a rename is a breaking change.
      shapes = [
        {Workflows.build_ingest_pipeline(),
         %{
           "ingest_docs" => :transform,
           "extract_concepts" => :agent_step,
           "compile_entries" => :agent_step,
           "generate_links" => :agent_step,
           "embed_entries" => :transform,
           "persist" => :transform
         }},
        {Workflows.build_incremental_pipeline(),
         %{
           "detect_changes" => :transform,
           "recompile" => :agent_step,
           "persist_changes" => :transform
         }},
        {Workflows.build_health_check_pipeline(),
         %{
           "gather_stats" => :transform,
           "audit_entries" => :agent_step,
           "build_report" => :transform
         }},
        {Workflows.build_output_pipeline(),
         %{"select_entries" => :transform, "generate_output" => :agent_step}}
      ]

      for {pipeline, expected} <- shapes do
        assert Map.new(pipeline.nodes, fn {id, node} -> {id, node.type} end) == expected
      end
    end

    test "the first node of each pipeline is its entry point" do
      assert Workflows.build_ingest_pipeline().entry_node == "ingest_docs"
      assert Workflows.build_incremental_pipeline().entry_node == "detect_changes"
      assert Workflows.build_health_check_pipeline().entry_node == "gather_stats"
      assert Workflows.build_output_pipeline().entry_node == "select_entries"
    end
  end

  describe "ingest :ingest_docs node" do
    test "accepts atom-keyed and string-keyed raw documents alike" do
      state =
        transform(Workflows.build_ingest_pipeline(), "ingest_docs", %{
          kb_config: %{kb_id: "kb1"},
          documents: [
            %{title: "Atoms", content: "atom body", doc_type: :html, source_url: "a://x"},
            %{"title" => "Strings", "content" => "string body"}
          ]
        })

      assert [atoms, strings] = state.data.documents_parsed

      assert %{title: "Atoms", content: "atom body", doc_type: :html, source_url: "a://x"} = atoms
      assert %{title: "Strings", content: "string body"} = strings
      # The default is what an LLM-supplied document without a type gets.
      assert strings.doc_type == :markdown
      assert Enum.map(state.data.documents_parsed, & &1.kb_id) == ["kb1", "kb1"]
    end
  end

  describe "incremental :detect_changes node" do
    test "skips documents already stored under the same checksum", %{kb: kb} do
      {:ok, _} =
        ETS.store_document(kb, Document.new(%{title: "Old", content: "seen", kb_id: "kb1"}))

      state =
        transform(Workflows.build_incremental_pipeline(), "detect_changes", %{
          kb_config: %{store: ETS, store_state: kb, kb_id: "kb1"},
          documents: [
            %{title: "Old", content: "seen"},
            %{title: "New", content: "never seen before"}
          ]
        })

      # Checksum, not title: the same body under a new title is still a repeat.
      assert Enum.map(state.data.changed_documents, & &1.title) == ["New"]
      assert Enum.map(state.data.changed_documents, & &1.kb_id) == ["kb1"]
    end

    test "an empty store treats every document as changed", %{kb: kb} do
      state =
        transform(Workflows.build_incremental_pipeline(), "detect_changes", %{
          kb_config: %{store: ETS, store_state: kb, kb_id: "kb1"},
          documents: [%{title: "One", content: "1"}, %{title: "Two", content: "2"}]
        })

      assert length(state.data.changed_documents) == 2
    end
  end

  describe "ingest :embed_entries node parses the model's JSON" do
    test "unwraps a fenced code block the way models emit it" do
      state = embed_entries([], ~s(```json\n[{"title":"A","content":"body"}]\n```))

      assert [%Entry{title: "A", content: "body"}] = state.data.compiled_entries
    end

    test "unparseable or non-list output yields no entries rather than raising" do
      for output <- [~s({"title":"A"}), "not json at all", "", nil, 42] do
        assert embed_entries([], output).data.compiled_entries == [],
               "#{inspect(output)} produced entries"
      end
    end

    test "entry_type is drawn from a closed set" do
      known = ~w(article concept summary index glossary)

      json =
        JSON.encode!(
          Enum.map(known ++ ["wharrgarbl"], fn type ->
            %{"title" => type, "content" => "c", "entry_type" => type}
          end)
        )

      types = embed_entries([], json).data.compiled_entries |> Enum.map(& &1.entry_type)

      # The unknown 12th type must land on :article, not become a new atom.
      assert types == [:article, :concept, :summary, :index, :glossary, :article]
    end

    test "missing fields fall back to the documented defaults" do
      assert [entry] = embed_entries([], ~s([{"content":"only content"}])).data.compiled_entries

      assert entry.title == "Untitled"
      assert entry.concepts == []
      assert entry.tags == []
      assert entry.confidence == 0.5
      assert entry.embedding == nil
    end

    test "with an embedding provider each entry is embedded" do
      state =
        embed_entries([embedding: EmbedEverything], ~s([{"title":"A","content":"a"}]))

      assert [%Entry{embedding: [1.0, 2.0]}] = state.data.compiled_entries
    end

    test "an entry whose embedding fails is kept, unembedded" do
      json = ~s([{"title":"A","content":"ok"},{"title":"B","content":"boom"}])

      state = embed_entries([embedding: EmbedUnlessBoom], json)

      # Dropping the failed entry would silently lose knowledge on a flaky
      # embedding endpoint; the contract is degrade, not discard.
      assert Enum.map(state.data.compiled_entries, &{&1.title, &1.embedding}) ==
               [{"A", [1.0, 2.0]}, {"B", nil}]
    end
  end

  describe "ingest :persist node" do
    setup do
      {:ok, store} = ETS.init([])
      %{store: store}
    end

    test "writes entries, links and documents, and threads the store state back", %{
      store: store
    } do
      entries = [
        Entry.new(%{title: "Alpha", slug: "alpha", content: "a"}),
        Entry.new(%{title: "Beta", slug: "beta", content: "b"})
      ]

      links = ~s([{"from_slug":"alpha","to_slug":"beta","link_type":"see_also"}])
      docs = [Document.new(%{title: "Doc", content: "d", kb_id: "kb2"})]

      state = persist(store, entries, links, docs)

      {:ok, stored_entries} = ETS.list_entries(store, kb_id: "kb2")
      assert Enum.map(stored_entries, & &1.slug) |> Enum.sort() == ["alpha", "beta"]

      # Entries arriving without a kb_id inherit the pipeline's.
      assert Enum.all?(stored_entries, &(&1.kb_id == "kb2"))

      alpha = Enum.find(stored_entries, &(&1.slug == "alpha"))
      {:ok, outlinks} = ETS.outlinks(store, alpha.id)
      assert [%Link{link_type: :see_also}] = outlinks

      {:ok, [stored_doc]} = ETS.list_documents(store, kb_id: "kb2")
      # The whole point of the document write is the status flip.
      assert stored_doc.status == :compiled

      assert state.data.kb_config.store_state == store
    end

    test "links naming an unknown slug are dropped, not stored dangling", %{store: store} do
      entries = [Entry.new(%{title: "Alpha", slug: "alpha", content: "a"})]

      links =
        ~s([{"from_slug":"alpha","to_slug":"ghost"},{"from_slug":"ghost","to_slug":"alpha"}])

      persist(store, entries, links, [])

      {:ok, stored} = ETS.list_entries(store, kb_id: "kb2")
      assert [alpha] = stored
      assert {:ok, []} = ETS.outlinks(store, alpha.id)
    end

    test "an unknown link_type falls back to :cross_reference", %{store: store} do
      entries = [
        Entry.new(%{title: "Alpha", slug: "alpha", content: "a"}),
        Entry.new(%{title: "Beta", slug: "beta", content: "b"})
      ]

      links = ~s([{"from_slug":"alpha","to_slug":"beta","link_type":"telepathy"}])
      persist(store, entries, links, [])

      {:ok, stored} = ETS.list_entries(store, kb_id: "kb2")
      alpha = Enum.find(stored, &(&1.slug == "alpha"))

      assert {:ok, [%Link{link_type: :cross_reference}]} = ETS.outlinks(store, alpha.id)
    end

    test "an entry that already carries a kb_id keeps it", %{store: store} do
      entries = [Entry.new(%{title: "Alpha", slug: "alpha", content: "a", kb_id: "other"})]

      persist(store, entries, nil, [])

      {:ok, [entry]} = ETS.list_entries(store, kb_id: "other")
      assert entry.kb_id == "other"
    end
  end

  describe "output :select_entries node" do
    test "unwraps the store's scored results and defaults the limit to ten" do
      state =
        transform(Workflows.build_output_pipeline(), "select_entries", %{
          kb_config: %{store: RecordingSearchStore, store_state: self(), kb_id: "kb1"},
          topic: "graphs"
        })

      assert_received {:search_entries, "graphs", opts}
      assert opts[:limit] == 10
      assert opts[:kb_id] == "kb1"

      # Scores are stripped: downstream prompts take entries, not tuples.
      assert Enum.map(state.data.selected_entries, & &1.title) == ["Hit"]
    end

    test "an explicit limit is passed through to the store" do
      transform(Workflows.build_output_pipeline(), "select_entries", %{
        kb_config: %{store: RecordingSearchStore, store_state: self(), kb_id: "kb1"},
        topic: "graphs",
        limit: 3
      })

      assert_received {:search_entries, "graphs", opts}
      assert opts[:limit] == 3
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

  # Same node-capture trick as gather_stats/2: the report builder is private
  # and sits behind the LLM audit step in the pipeline.
  defp build_report(audit_output) do
    transform_fn =
      Workflows.build_health_check_pipeline()
      |> Map.fetch!(:nodes)
      |> Map.fetch!("build_report")
      |> Map.fetch!(:config)
      |> Map.fetch!(:transform_fn)

    transform_fn.(
      State.new(%{
        audit_entries: audit_output,
        stats: %{total_entries: 0, total_links: 0, total_documents: 0},
        kb_config: %{kb_id: "kb1"}
      })
    )
  end

  defp summaries(state) do
    state.data.entry_summaries
    |> Enum.map(&{&1.slug, &1.link_count})
    |> Enum.sort()
  end

  # Generalisation of the two node captures above: every transform node in
  # these pipelines sits behind an :agent_step, so running the graph is not an
  # option without a live model.
  defp transform(pipeline, node_id, data) do
    pipeline
    |> Map.fetch!(:nodes)
    |> Map.fetch!(node_id)
    |> Map.fetch!(:config)
    |> Map.fetch!(:transform_fn)
    |> then(fn fun -> fun.(State.new(data)) end)
  end

  defp embed_entries(opts, compile_output) do
    transform(Workflows.build_ingest_pipeline(opts), "embed_entries", %{
      compile_entries: compile_output
    })
  end

  defp persist(store, entries, links_output, documents) do
    transform(Workflows.build_ingest_pipeline(), "persist", %{
      kb_config: %{store: ETS, store_state: store, kb_id: "kb2"},
      compiled_entries: entries,
      generate_links: links_output,
      documents_parsed: documents
    })
  end
end
