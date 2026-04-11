defmodule Nous.KnowledgeBase.Workflows do
  @moduledoc """
  Pre-built workflow DAG pipelines for knowledge base operations.

  Provides ready-made workflows for:
  - **Ingest pipeline** — raw documents → compiled wiki entries
  - **Incremental update** — detect changes and recompile affected entries
  - **Health check** — audit the knowledge base for issues
  - **Output generation** — produce reports, summaries, or slides
  """

  alias Nous.Workflow
  alias Nous.KnowledgeBase.{Document, Entry, Link, HealthReport, Prompts}

  # ---------------------------------------------------------------------------
  # Ingest Pipeline
  # ---------------------------------------------------------------------------

  @doc """
  Builds an ingest pipeline workflow.

  Nodes: ingest_docs → extract_concepts → compile_entries → generate_links → embed_entries → persist

  ## Required input data

      %{
        documents: [%{title: "...", content: "...", doc_type: :markdown}],
        kb_config: %{store: ..., store_state: ..., kb_id: ...}
      }

  ## Options

    * `:compiler_model` - Model string for LLM steps (default: "openai:gpt-4o-mini")
    * `:embedding` - Embedding provider module
    * `:embedding_opts` - Embedding options
  """
  def build_ingest_pipeline(opts \\ []) do
    Workflow.new("kb_ingest", name: "Knowledge Base Ingest Pipeline")
    |> Workflow.add_node(:ingest_docs, :transform, %{
      transform_fn: &ingest_raw_documents/1
    })
    |> Workflow.add_node(:extract_concepts, :agent_step, %{
      agent: compiler_agent(opts),
      prompt: fn state ->
        Prompts.extraction_prompt(state.data.documents_parsed)
      end
    })
    |> Workflow.add_node(:compile_entries, :agent_step, %{
      agent: compiler_agent(opts),
      prompt: fn state ->
        concepts = parse_json_output(state.data.extract_concepts)
        Prompts.compilation_prompt(state.data.documents_parsed, concepts)
      end
    })
    |> Workflow.add_node(:generate_links, :agent_step, %{
      agent: compiler_agent(opts),
      prompt: fn state ->
        entries = parse_entries_from_output(state.data.compile_entries)
        Prompts.linking_prompt(entries)
      end
    })
    |> Workflow.add_node(:embed_entries, :transform, %{
      transform_fn: embed_entries_fn(opts)
    })
    |> Workflow.add_node(:persist, :transform, %{
      transform_fn: &persist_to_store/1
    })
    |> Workflow.chain([
      :ingest_docs,
      :extract_concepts,
      :compile_entries,
      :generate_links,
      :embed_entries,
      :persist
    ])
  end

  # ---------------------------------------------------------------------------
  # Incremental Update Pipeline
  # ---------------------------------------------------------------------------

  @doc """
  Builds an incremental update pipeline.

  Detects changed documents and recompiles only affected entries.

  ## Required input data

      %{
        documents: [%{title: "...", content: "..."}],
        kb_config: %{store: ..., store_state: ..., kb_id: ...}
      }
  """
  def build_incremental_pipeline(opts \\ []) do
    Workflow.new("kb_incremental", name: "KB Incremental Update")
    |> Workflow.add_node(:detect_changes, :transform, %{
      transform_fn: &detect_changed_documents/1
    })
    |> Workflow.add_node(:recompile, :agent_step, %{
      agent: compiler_agent(opts),
      prompt: fn state ->
        changed = state.data.changed_documents
        Prompts.compilation_prompt(changed, [])
      end
    })
    |> Workflow.add_node(:persist_changes, :transform, %{
      transform_fn: &persist_to_store/1
    })
    |> Workflow.chain([:detect_changes, :recompile, :persist_changes])
  end

  # ---------------------------------------------------------------------------
  # Health Check Pipeline
  # ---------------------------------------------------------------------------

  @doc """
  Builds a health check pipeline.

  ## Required input data

      %{kb_config: %{store: ..., store_state: ..., kb_id: ...}}
  """
  def build_health_check_pipeline(opts \\ []) do
    Workflow.new("kb_health_check", name: "KB Health Check")
    |> Workflow.add_node(:gather_stats, :transform, %{
      transform_fn: &gather_kb_statistics/1
    })
    |> Workflow.add_node(:audit_entries, :agent_step, %{
      agent: compiler_agent(opts),
      prompt: fn state ->
        Prompts.audit_prompt(state.data.stats, state.data.entry_summaries)
      end
    })
    |> Workflow.add_node(:build_report, :transform, %{
      transform_fn: &build_health_report/1
    })
    |> Workflow.chain([:gather_stats, :audit_entries, :build_report])
  end

  # ---------------------------------------------------------------------------
  # Output Generation Pipeline
  # ---------------------------------------------------------------------------

  @doc """
  Builds an output generation pipeline.

  ## Required input data

      %{
        topic: "...",
        output_type: :report | :summary | :slides,
        kb_config: %{store: ..., store_state: ..., kb_id: ...}
      }
  """
  def build_output_pipeline(opts \\ []) do
    Workflow.new("kb_output", name: "KB Output Generation")
    |> Workflow.add_node(:select_entries, :transform, %{
      transform_fn: &select_relevant_entries/1
    })
    |> Workflow.add_node(:generate_output, :agent_step, %{
      agent: compiler_agent(opts),
      prompt: fn state ->
        Prompts.output_prompt(
          state.data.topic,
          state.data.selected_entries,
          state.data.output_type
        )
      end
    })
    |> Workflow.chain([:select_entries, :generate_output])
  end

  # ---------------------------------------------------------------------------
  # Transform functions
  # ---------------------------------------------------------------------------

  defp ingest_raw_documents(state) do
    documents =
      state.data.documents
      |> Enum.map(fn raw ->
        Document.new(%{
          title: raw[:title] || raw["title"],
          content: raw[:content] || raw["content"],
          doc_type: raw[:doc_type] || raw["doc_type"] || :markdown,
          source_url: raw[:source_url] || raw["source_url"],
          kb_id: get_in(state.data, [:kb_config, :kb_id])
        })
      end)

    %{state | data: Map.put(state.data, :documents_parsed, documents)}
  end

  defp detect_changed_documents(state) do
    config = state.data.kb_config
    store_mod = config[:store]
    store_state = config[:store_state]

    {:ok, existing_docs} = store_mod.list_documents(store_state, kb_id: config[:kb_id])
    existing_checksums = Map.new(existing_docs, fn doc -> {doc.checksum, doc} end)

    new_documents =
      state.data.documents
      |> Enum.map(fn raw ->
        content = raw[:content] || raw["content"]
        checksum = Document.compute_checksum(content)

        unless Map.has_key?(existing_checksums, checksum) do
          Document.new(%{
            title: raw[:title] || raw["title"],
            content: content,
            kb_id: config[:kb_id]
          })
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{state | data: Map.put(state.data, :changed_documents, new_documents)}
  end

  defp gather_kb_statistics(state) do
    config = state.data.kb_config
    store_mod = config[:store]
    store_state = config[:store_state]
    kb_id = config[:kb_id]
    opts = if kb_id, do: [kb_id: kb_id], else: []

    {:ok, entries} = store_mod.list_entries(store_state, opts)
    {:ok, docs} = store_mod.list_documents(store_state, opts)

    link_count =
      Enum.reduce(entries, 0, fn entry, acc ->
        case store_mod.outlinks(store_state, entry.id) do
          {:ok, links} -> acc + length(links)
          _ -> acc
        end
      end)

    stats = %{
      total_entries: length(entries),
      total_links: link_count,
      total_documents: length(docs)
    }

    entry_summaries =
      Enum.map(entries, fn entry ->
        {:ok, outlinks} = store_mod.outlinks(store_state, entry.id)

        %{
          slug: entry.slug,
          title: entry.title,
          entry_type: entry.entry_type,
          confidence: entry.confidence,
          link_count: length(outlinks)
        }
      end)

    state
    |> put_in([Access.key(:data), :stats], stats)
    |> put_in([Access.key(:data), :entry_summaries], entry_summaries)
  end

  defp build_health_report(state) do
    audit_output = state.data.audit_entries
    issues = parse_json_output(audit_output)
    stats = state.data.stats

    report =
      HealthReport.new(%{
        kb_id: get_in(state.data, [:kb_config, :kb_id]),
        total_entries: stats.total_entries,
        total_links: stats.total_links,
        total_documents: stats.total_documents,
        issues:
          Enum.map(issues, fn issue ->
            %{
              type: String.to_existing_atom(issue["type"] || "gap"),
              entry_id: issue["entry_id"],
              description: issue["description"] || "",
              severity: String.to_existing_atom(issue["severity"] || "low"),
              suggested_action: issue["suggested_action"] || ""
            }
          end)
      })

    %{state | data: Map.put(state.data, :health_report, report)}
  end

  defp select_relevant_entries(state) do
    config = state.data.kb_config
    store_mod = config[:store]
    store_state = config[:store_state]
    topic = state.data.topic
    limit = state.data[:limit] || 10

    {:ok, results} =
      store_mod.search_entries(store_state, topic, limit: limit, kb_id: config[:kb_id])

    entries = Enum.map(results, fn {entry, _score} -> entry end)
    %{state | data: Map.put(state.data, :selected_entries, entries)}
  end

  defp embed_entries_fn(opts) do
    embedding = opts[:embedding]
    embedding_opts = opts[:embedding_opts] || []

    fn state ->
      if embedding do
        entries = parse_entries_from_output(state.data.compile_entries)

        embedded =
          Enum.map(entries, fn entry ->
            case Nous.Memory.Embedding.embed(embedding, entry.content, embedding_opts) do
              {:ok, emb} -> %{entry | embedding: emb}
              {:error, _} -> entry
            end
          end)

        %{state | data: Map.put(state.data, :compiled_entries, embedded)}
      else
        entries = parse_entries_from_output(state.data.compile_entries)
        %{state | data: Map.put(state.data, :compiled_entries, entries)}
      end
    end
  end

  defp persist_to_store(state) do
    config = state.data.kb_config
    store_mod = config[:store]
    store_state = config[:store_state]
    kb_id = config[:kb_id]

    # Persist compiled entries
    entries = state.data[:compiled_entries] || []

    store_state =
      Enum.reduce(entries, store_state, fn entry, acc ->
        entry = if entry.kb_id, do: entry, else: %{entry | kb_id: kb_id}

        case store_mod.store_entry(acc, entry) do
          {:ok, new_state} -> new_state
          {:error, _} -> acc
        end
      end)

    # Persist links
    links_output = state.data[:generate_links]
    links = parse_links_from_output(links_output, entries, kb_id)

    store_state =
      Enum.reduce(links, store_state, fn link, acc ->
        case store_mod.store_link(acc, link) do
          {:ok, new_state} -> new_state
          {:error, _} -> acc
        end
      end)

    # Persist documents
    docs = state.data[:documents_parsed] || []

    store_state =
      Enum.reduce(docs, store_state, fn doc, acc ->
        compiled_doc = %{doc | status: :compiled}

        case store_mod.store_document(acc, compiled_doc) do
          {:ok, new_state} -> new_state
          {:error, _} -> acc
        end
      end)

    updated_config = Map.put(config, :store_state, store_state)
    %{state | data: Map.put(state.data, :kb_config, updated_config)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp compiler_agent(opts) do
    model = opts[:compiler_model] || "openai:gpt-4o-mini"

    Nous.Agent.new(model,
      instructions: "You are a knowledge base curator. Output valid JSON only."
    )
  end

  defp parse_json_output(text) when is_binary(text) do
    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/m, "")
      |> String.replace(~r/\s*```$/m, "")
      |> String.trim()

    case JSON.decode(cleaned) do
      {:ok, parsed} when is_list(parsed) -> parsed
      _ -> []
    end
  end

  defp parse_json_output(_), do: []

  defp parse_entries_from_output(text) when is_binary(text) do
    parse_json_output(text)
    |> Enum.map(fn raw ->
      Entry.new(%{
        title: raw["title"] || "Untitled",
        slug: raw["slug"],
        content: raw["content"] || "",
        summary: raw["summary"],
        concepts: raw["concepts"] || [],
        tags: raw["tags"] || [],
        entry_type: parse_entry_type(raw["entry_type"]),
        confidence: raw["confidence"] || 0.5
      })
    end)
  end

  defp parse_entries_from_output(_), do: []

  defp parse_links_from_output(text, entries, kb_id) when is_binary(text) do
    slug_to_id = Map.new(entries, fn e -> {e.slug, e.id} end)

    parse_json_output(text)
    |> Enum.map(fn raw ->
      from_id = slug_to_id[raw["from_slug"]]
      to_id = slug_to_id[raw["to_slug"]]

      if from_id && to_id do
        Link.new(%{
          from_entry_id: from_id,
          to_entry_id: to_id,
          link_type: parse_link_type(raw["link_type"]),
          label: raw["label"],
          kb_id: kb_id
        })
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_links_from_output(_, _, _), do: []

  defp parse_entry_type("article"), do: :article
  defp parse_entry_type("concept"), do: :concept
  defp parse_entry_type("summary"), do: :summary
  defp parse_entry_type("index"), do: :index
  defp parse_entry_type("glossary"), do: :glossary
  defp parse_entry_type(_), do: :article

  defp parse_link_type("backlink"), do: :backlink
  defp parse_link_type("cross_reference"), do: :cross_reference
  defp parse_link_type("concept"), do: :concept
  defp parse_link_type("see_also"), do: :see_also
  defp parse_link_type("parent_child"), do: :parent_child
  defp parse_link_type(_), do: :cross_reference
end
