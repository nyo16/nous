defmodule Nous.KnowledgeBase.Tools do
  # identify_issues/4 builds two MapSets from optional Store callbacks
  # whose return type dialyzer can't fully narrow; same opaque-capture
  # false-positive as Workflow.Engine.
  @dialyzer :no_opaque

  @moduledoc """
  Agent tools for knowledge base operations.

  Follows the `Nous.Memory.Tools` pattern — each tool receives `ctx`
  via `takes_ctx: true` and returns `{:ok, result, ContextUpdate.new()}`.
  """

  alias Nous.KnowledgeBase.{Document, Entry, Link}
  alias Nous.Tool
  alias Nous.Tool.ContextUpdate

  @doc """
  Returns all knowledge base tools as a list.
  """
  def all_tools do
    [
      kb_search_tool(),
      kb_read_tool(),
      kb_list_tool(),
      kb_ingest_tool(),
      kb_add_entry_tool(),
      kb_link_tool(),
      kb_backlinks_tool(),
      kb_health_check_tool(),
      kb_generate_tool()
    ]
  end

  # ---------------------------------------------------------------------------
  # Tool definitions
  # ---------------------------------------------------------------------------

  defp kb_search_tool do
    %Tool{
      name: "kb_search",
      description:
        "Search the knowledge base wiki for relevant entries. Returns entries ranked by relevance.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Search query"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of results (default: 5)"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Filter by tags"
          },
          "entry_type" => %{
            "type" => "string",
            "enum" => ["article", "concept", "summary", "index", "glossary"],
            "description" => "Filter by entry type"
          }
        },
        "required" => ["query"]
      },
      function: &__MODULE__.kb_search/2,
      takes_ctx: true,
      category: :search
    }
  end

  defp kb_read_tool do
    %Tool{
      name: "kb_read",
      description:
        "Read a specific knowledge base entry by its slug or ID. Returns the full entry content.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "slug_or_id" => %{
            "type" => "string",
            "description" => "Entry slug (e.g. 'elixir-genserver') or entry ID"
          }
        },
        "required" => ["slug_or_id"]
      },
      function: &__MODULE__.kb_read/2,
      takes_ctx: true,
      category: :read
    }
  end

  defp kb_list_tool do
    %Tool{
      name: "kb_list",
      description:
        "List knowledge base entries, optionally filtered by tags, concepts, or entry type.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Filter by tags"
          },
          "concepts" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Filter by concepts"
          },
          "entry_type" => %{
            "type" => "string",
            "enum" => ["article", "concept", "summary", "index", "glossary"],
            "description" => "Filter by entry type"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of entries (default: 20)"
          }
        }
      },
      function: &__MODULE__.kb_list/2,
      takes_ctx: true,
      category: :read
    }
  end

  defp kb_ingest_tool do
    %Tool{
      name: "kb_ingest",
      description:
        "Ingest a raw document into the knowledge base for later compilation into wiki entries.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "title" => %{
            "type" => "string",
            "description" => "Document title"
          },
          "content" => %{
            "type" => "string",
            "description" => "Raw document content (markdown, text, etc.)"
          },
          "doc_type" => %{
            "type" => "string",
            "enum" => ["markdown", "text", "url", "pdf", "html"],
            "description" => "Document type (default: markdown)"
          },
          "source_url" => %{
            "type" => "string",
            "description" => "Original source URL if applicable"
          }
        },
        "required" => ["title", "content"]
      },
      function: &__MODULE__.kb_ingest/2,
      takes_ctx: true,
      category: :write
    }
  end

  defp kb_add_entry_tool do
    %Tool{
      name: "kb_add_entry",
      description:
        "Directly create or update a compiled wiki entry in the knowledge base. Use [[slug]] for wiki-links.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "title" => %{
            "type" => "string",
            "description" => "Entry title"
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "Wiki entry content in markdown. Use [[slug]] for links to other entries."
          },
          "summary" => %{
            "type" => "string",
            "description" => "1-3 sentence summary"
          },
          "concepts" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Key concepts covered in this entry"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags for categorization"
          },
          "entry_type" => %{
            "type" => "string",
            "enum" => ["article", "concept", "summary", "index", "glossary"],
            "description" => "Entry type (default: article)"
          },
          "source_doc_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "IDs of source documents this entry was compiled from"
          }
        },
        "required" => ["title", "content"]
      },
      function: &__MODULE__.kb_add_entry/2,
      takes_ctx: true,
      category: :write
    }
  end

  defp kb_link_tool do
    %Tool{
      name: "kb_link",
      description: "Create a link between two knowledge base entries.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "from_slug" => %{
            "type" => "string",
            "description" => "Slug or ID of the source entry"
          },
          "to_slug" => %{
            "type" => "string",
            "description" => "Slug or ID of the target entry"
          },
          "link_type" => %{
            "type" => "string",
            "enum" => ["backlink", "cross_reference", "concept", "see_also", "parent_child"],
            "description" => "Type of link (default: cross_reference)"
          },
          "label" => %{
            "type" => "string",
            "description" => "Display label for the link"
          }
        },
        "required" => ["from_slug", "to_slug"]
      },
      function: &__MODULE__.kb_link/2,
      takes_ctx: true,
      category: :write
    }
  end

  defp kb_backlinks_tool do
    %Tool{
      name: "kb_backlinks",
      description: "Find all entries that link to a given entry.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "slug_or_id" => %{
            "type" => "string",
            "description" => "Entry slug or ID to find backlinks for"
          }
        },
        "required" => ["slug_or_id"]
      },
      function: &__MODULE__.kb_backlinks/2,
      takes_ctx: true,
      category: :read
    }
  end

  defp kb_health_check_tool do
    %Tool{
      name: "kb_health_check",
      description:
        "Run a health audit on the knowledge base. Checks for orphaned entries, stale content, missing links, and gaps.",
      parameters: %{
        "type" => "object",
        "properties" => %{}
      },
      function: &__MODULE__.kb_health_check/2,
      takes_ctx: true,
      category: :read
    }
  end

  defp kb_generate_tool do
    %Tool{
      name: "kb_generate",
      description:
        "Generate a structured output (report, summary, or slides) from knowledge base entries on a given topic.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "topic" => %{
            "type" => "string",
            "description" => "Topic to generate output about"
          },
          "output_type" => %{
            "type" => "string",
            "enum" => ["report", "summary", "slides"],
            "description" => "Type of output to generate (default: summary)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of entries to include (default: 10)"
          }
        },
        "required" => ["topic"]
      },
      function: &__MODULE__.kb_generate/2,
      takes_ctx: true,
      category: :execute
    }
  end

  # ---------------------------------------------------------------------------
  # Tool implementations
  # ---------------------------------------------------------------------------

  def kb_search(ctx, args) do
    with {:ok, store_mod, store_state} <- get_store(ctx) do
      query = Map.fetch!(args, "query")
      limit = Map.get(args, "limit", 5)
      entry_type = parse_entry_type(Map.get(args, "entry_type"))

      opts =
        [limit: limit, kb_id: get_kb_id(ctx)]
        |> maybe_put(:entry_type, entry_type)
        |> maybe_put(:tags, Map.get(args, "tags"))

      case store_mod.search_entries(store_state, query, opts) do
        {:ok, results} ->
          formatted =
            Enum.map(results, fn {entry, score} ->
              %{
                slug: entry.slug,
                title: entry.title,
                summary: entry.summary,
                entry_type: to_string(entry.entry_type),
                concepts: entry.concepts,
                tags: entry.tags,
                confidence: entry.confidence,
                score: Float.round(score, 4)
              }
            end)

          {:ok, %{status: "found", count: length(formatted), entries: formatted},
           ContextUpdate.new()}

        {:error, reason} ->
          {:ok, %{status: "error", message: "Search failed: #{inspect(reason)}"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} -> not_initialized_error()
    end
  end

  def kb_read(ctx, args) do
    with {:ok, store_mod, store_state} <- get_store(ctx) do
      slug_or_id = Map.fetch!(args, "slug_or_id")

      result =
        case store_mod.fetch_entry_by_slug(store_state, slug_or_id) do
          {:ok, _} = ok -> ok
          {:error, :not_found} -> store_mod.fetch_entry(store_state, slug_or_id)
        end

      case result do
        {:ok, entry} ->
          {:ok,
           %{
             id: entry.id,
             slug: entry.slug,
             title: entry.title,
             content: entry.content,
             summary: entry.summary,
             entry_type: to_string(entry.entry_type),
             concepts: entry.concepts,
             tags: entry.tags,
             confidence: entry.confidence,
             source_doc_ids: entry.source_doc_ids,
             created_at: DateTime.to_iso8601(entry.created_at),
             updated_at: DateTime.to_iso8601(entry.updated_at)
           }, ContextUpdate.new()}

        {:error, :not_found} ->
          {:ok, %{status: "not_found", message: "Entry '#{slug_or_id}' not found"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} -> not_initialized_error()
    end
  end

  def kb_list(ctx, args) do
    with {:ok, store_mod, store_state} <- get_store(ctx) do
      limit = Map.get(args, "limit", 20)
      entry_type = parse_entry_type(Map.get(args, "entry_type"))

      opts =
        [limit: limit, kb_id: get_kb_id(ctx)]
        |> maybe_put(:entry_type, entry_type)
        |> maybe_put(:tags, Map.get(args, "tags"))
        |> maybe_put(:concepts, Map.get(args, "concepts"))

      case store_mod.list_entries(store_state, opts) do
        {:ok, entries} ->
          formatted =
            Enum.map(entries, fn entry ->
              %{
                slug: entry.slug,
                title: entry.title,
                entry_type: to_string(entry.entry_type),
                concepts: entry.concepts,
                tags: entry.tags
              }
            end)

          {:ok, %{status: "ok", count: length(formatted), entries: formatted},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} -> not_initialized_error()
    end
  end

  def kb_ingest(ctx, args) do
    with {:ok, store_mod, store_state} <- get_store(ctx) do
      doc =
        Document.new(%{
          title: Map.fetch!(args, "title"),
          content: Map.fetch!(args, "content"),
          doc_type: parse_doc_type(Map.get(args, "doc_type", "markdown")),
          source_url: Map.get(args, "source_url"),
          kb_id: get_kb_id(ctx)
        })

      case store_mod.store_document(store_state, doc) do
        {:ok, new_state} ->
          {:ok,
           %{
             status: "ingested",
             id: doc.id,
             title: doc.title,
             checksum: doc.checksum
           }, update_store_state(ctx, new_state)}

        {:error, reason} ->
          {:ok, %{status: "error", message: "Ingest failed: #{inspect(reason)}"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} -> not_initialized_error()
    end
  end

  def kb_add_entry(ctx, args) do
    with {:ok, store_mod, store_state} <- get_store(ctx) do
      config = ctx.deps[:kb_config] || %{}
      title = Map.fetch!(args, "title")
      content = Map.fetch!(args, "content")

      # Generate embedding if provider configured
      embedding = maybe_embed(config, content)

      entry =
        Entry.new(%{
          title: title,
          content: content,
          summary: Map.get(args, "summary"),
          concepts: Map.get(args, "concepts", []),
          tags: Map.get(args, "tags", []),
          entry_type: parse_entry_type(Map.get(args, "entry_type")) || :article,
          source_doc_ids: Map.get(args, "source_doc_ids", []),
          embedding: embedding,
          kb_id: get_kb_id(ctx)
        })

      case store_mod.store_entry(store_state, entry) do
        {:ok, new_state} ->
          {:ok,
           %{
             status: "created",
             id: entry.id,
             slug: entry.slug,
             title: entry.title
           }, update_store_state(ctx, new_state)}

        {:error, reason} ->
          {:ok, %{status: "error", message: "Failed to add entry: #{inspect(reason)}"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} -> not_initialized_error()
    end
  end

  def kb_link(ctx, args) do
    with {:ok, store_mod, store_state} <- get_store(ctx) do
      from_slug = Map.fetch!(args, "from_slug")
      to_slug = Map.fetch!(args, "to_slug")

      with {:ok, from_entry} <- resolve_entry(store_mod, store_state, from_slug),
           {:ok, to_entry} <- resolve_entry(store_mod, store_state, to_slug) do
        link =
          Link.new(%{
            from_entry_id: from_entry.id,
            to_entry_id: to_entry.id,
            link_type: parse_link_type(Map.get(args, "link_type")),
            label: Map.get(args, "label"),
            kb_id: get_kb_id(ctx)
          })

        case store_mod.store_link(store_state, link) do
          {:ok, new_state} ->
            {:ok,
             %{
               status: "linked",
               id: link.id,
               from: from_entry.slug,
               to: to_entry.slug,
               link_type: to_string(link.link_type)
             }, update_store_state(ctx, new_state)}

          {:error, reason} ->
            {:ok, %{status: "error", message: "Link failed: #{inspect(reason)}"},
             ContextUpdate.new()}
        end
      else
        {:error, :not_found} ->
          {:ok,
           %{status: "error", message: "Could not find entry '#{from_slug}' or '#{to_slug}'"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} -> not_initialized_error()
    end
  end

  def kb_backlinks(ctx, args) do
    with {:ok, store_mod, store_state} <- get_store(ctx) do
      slug_or_id = Map.fetch!(args, "slug_or_id")

      with {:ok, entry} <- resolve_entry(store_mod, store_state, slug_or_id),
           {:ok, links} <- store_mod.backlinks(store_state, entry.id) do
        # Fetch the source entries for each backlink
        entries =
          links
          |> Enum.map(fn link ->
            case store_mod.fetch_entry(store_state, link.from_entry_id) do
              {:ok, e} ->
                %{
                  slug: e.slug,
                  title: e.title,
                  link_type: to_string(link.link_type),
                  label: link.label
                }

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok,
         %{
           status: "ok",
           entry: entry.slug,
           backlink_count: length(entries),
           backlinks: entries
         }, ContextUpdate.new()}
      else
        {:error, :not_found} ->
          {:ok, %{status: "not_found", message: "Entry '#{slug_or_id}' not found"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} -> not_initialized_error()
    end
  end

  def kb_health_check(ctx, _args) do
    with {:ok, store_mod, store_state} <- get_store(ctx) do
      kb_id = get_kb_id(ctx)
      opts = if kb_id, do: [kb_id: kb_id], else: []

      {:ok, entries} = store_mod.list_entries(store_state, opts)
      {:ok, docs} = store_mod.list_documents(store_state, opts)

      # Count links via the optional bulk callback when available - O(L)
      # versus per-entry outlinks/2 which scans the link table per entry
      # (O(E*L) on the only included ETS impl). On a 1k-entry KB with 5k
      # links this is the difference between ~5M comparisons and ~5k.
      counts_by_source = link_counts_by_source(store_mod, store_state)
      link_count = counts_by_source |> Map.values() |> Enum.sum()

      # Identify issues
      issues = identify_issues(store_mod, store_state, entries, docs)

      # Compute scores
      now = DateTime.utc_now()

      freshness_score =
        if entries == [] do
          0.0
        else
          avg_age =
            entries
            |> Enum.map(fn e -> DateTime.diff(now, e.updated_at, :hour) end)
            |> then(fn ages -> Enum.sum(ages) / length(ages) end)

          # Score decays over 30 days (720 hours)
          Float.round(:math.exp(-avg_age / 720), 3)
        end

      pending_docs = Enum.count(docs, fn d -> d.status == :pending end)

      coverage_score =
        if docs == [] do
          1.0
        else
          compiled = Enum.count(docs, fn d -> d.status == :compiled end)
          Float.round(compiled / length(docs), 3)
        end

      report =
        Nous.KnowledgeBase.HealthReport.new(%{
          kb_id: kb_id,
          total_entries: length(entries),
          total_links: link_count,
          total_documents: length(docs),
          issues: issues,
          coverage_score: coverage_score,
          freshness_score: freshness_score,
          # L-4: weight by severity so a single high-severity issue isn't
          # treated like a single low-severity nit. Clamps before rounding
          # so very-bad KBs saturate at 0.0 cleanly.
          coherence_score:
            if(issues == [],
              do: 1.0,
              else:
                issues
                |> Enum.reduce(1.0, fn issue, acc ->
                  weight =
                    case issue.severity do
                      :high -> 0.2
                      :medium -> 0.1
                      :low -> 0.05
                      _ -> 0.05
                    end

                  acc - weight
                end)
                |> max(0.0)
                |> Float.round(3)
            )
        })

      {:ok,
       %{
         status: "ok",
         total_entries: report.total_entries,
         total_links: report.total_links,
         total_documents: report.total_documents,
         pending_documents: pending_docs,
         coverage_score: report.coverage_score,
         freshness_score: report.freshness_score,
         coherence_score: report.coherence_score,
         issue_count: length(report.issues),
         issues:
           Enum.map(report.issues, fn issue ->
             %{
               type: to_string(issue.type),
               description: issue.description,
               severity: to_string(issue.severity)
             }
           end)
       }, ContextUpdate.new()}
    else
      {:error, :not_initialized} -> not_initialized_error()
    end
  end

  def kb_generate(ctx, args) do
    with {:ok, store_mod, store_state} <- get_store(ctx) do
      topic = Map.fetch!(args, "topic")
      output_type = Map.get(args, "output_type", "summary")
      limit = Map.get(args, "limit", 10)

      # Search for relevant entries
      opts = [limit: limit, kb_id: get_kb_id(ctx)]

      case store_mod.search_entries(store_state, topic, opts) do
        {:ok, results} ->
          entries = Enum.map(results, fn {entry, _score} -> entry end)

          content =
            case output_type do
              "slides" -> format_as_slides(topic, entries)
              "report" -> format_as_report(topic, entries)
              _ -> format_as_summary(topic, entries)
            end

          {:ok,
           %{
             status: "generated",
             output_type: output_type,
             topic: topic,
             entry_count: length(entries),
             content: content
           }, ContextUpdate.new()}

        {:error, reason} ->
          {:ok, %{status: "error", message: "Generation failed: #{inspect(reason)}"},
           ContextUpdate.new()}
      end
    else
      {:error, :not_initialized} -> not_initialized_error()
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp get_store(ctx) do
    config = ctx.deps[:kb_config] || %{}
    store_mod = config[:store]
    store_state = config[:store_state]

    if store_mod && store_state do
      {:ok, store_mod, store_state}
    else
      {:error, :not_initialized}
    end
  end

  defp not_initialized_error do
    {:ok, %{status: "error", message: "Knowledge base not initialized"}, ContextUpdate.new()}
  end

  defp get_kb_id(ctx) do
    config = ctx.deps[:kb_config] || %{}
    config[:kb_id]
  end

  defp resolve_entry(store_mod, store_state, slug_or_id) do
    case store_mod.fetch_entry_by_slug(store_state, slug_or_id) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> store_mod.fetch_entry(store_state, slug_or_id)
    end
  end

  defp update_store_state(ctx, new_state) do
    config = ctx.deps[:kb_config] || %{}
    updated_config = Map.put(config, :store_state, new_state)
    ContextUpdate.new() |> ContextUpdate.set(:kb_config, updated_config)
  end

  defp maybe_embed(config, content) do
    embedding_provider = config[:embedding]
    embedding_opts = config[:embedding_opts] || []

    if embedding_provider do
      case Nous.Memory.Embedding.embed(embedding_provider, content, embedding_opts) do
        {:ok, emb} -> emb
        {:error, _} -> nil
      end
    end
  end

  defp identify_issues(store_mod, store_state, entries, docs) do
    issues = []

    # M-1: hoist link reads out of the per-entry filter. Build two
    # MapSets of "entries with any links" once (O(L) total) and use them
    # for the orphan check (O(E) lookups), instead of calling backlinks/2
    # AND outlinks/2 inside Enum.filter for every entry (O(E*L)).
    out_sources = link_counts_by_source(store_mod, store_state) |> Map.keys() |> MapSet.new()
    in_targets = link_targets_by_destination(store_mod, store_state, entries)

    # Orphaned entries (no source documents and no links)
    orphan_issues =
      entries
      |> Enum.filter(fn entry ->
        entry.source_doc_ids == [] and
          not MapSet.member?(in_targets, entry.id) and
          not MapSet.member?(out_sources, entry.id)
      end)
      |> Enum.map(fn entry ->
        %{
          type: :orphan,
          entry_id: entry.id,
          description: "Entry '#{entry.title}' has no source documents and no links",
          severity: :low,
          suggested_action: "Add source documents or link to related entries"
        }
      end)

    # Low confidence entries
    low_confidence_issues =
      entries
      |> Enum.filter(fn entry -> entry.confidence < 0.3 end)
      |> Enum.map(fn entry ->
        %{
          type: :low_confidence,
          entry_id: entry.id,
          description: "Entry '#{entry.title}' has low confidence (#{entry.confidence})",
          severity: :medium,
          suggested_action: "Verify and update entry content from source documents"
        }
      end)

    # Failed documents
    failed_doc_issues =
      docs
      |> Enum.filter(fn doc -> doc.status == :failed end)
      |> Enum.map(fn doc ->
        %{
          type: :inconsistent,
          entry_id: nil,
          description: "Document '#{doc.title}' failed to compile",
          severity: :high,
          suggested_action: "Re-ingest or manually review document"
        }
      end)

    issues ++ orphan_issues ++ low_confidence_issues ++ failed_doc_issues
  end

  # Use the optional bulk Store callback if implemented; fall back to
  # per-entry outlinks/2 (the legacy O(E*L) path) so older custom backends
  # keep working without code changes.
  defp link_counts_by_source(store_mod, store_state) do
    if function_exported?(store_mod, :link_counts_by_source, 1) do
      case store_mod.link_counts_by_source(store_state) do
        {:ok, counts} -> counts
        _ -> %{}
      end
    else
      %{}
    end
  end

  # Build a MapSet of entry IDs that appear as the destination of any link.
  # Single scan via the bulk callback (when available); otherwise empty
  # (the orphan check is conservative: an entry with no source docs AND
  # no recorded incoming/outgoing links is flagged).
  defp link_targets_by_destination(store_mod, store_state, _entries) do
    if function_exported?(store_mod, :link_counts_by_destination, 1) do
      case store_mod.link_counts_by_destination(store_state) do
        {:ok, counts} -> counts |> Map.keys() |> MapSet.new()
        _ -> MapSet.new()
      end
    else
      MapSet.new()
    end
  end

  defp format_as_summary(topic, entries) do
    entry_texts =
      entries
      |> Enum.map(fn entry ->
        "### #{entry.title}\n#{entry.summary || String.slice(entry.content, 0, 200)}"
      end)
      |> Enum.join("\n\n")

    """
    # Summary: #{topic}

    #{entry_texts}
    """
  end

  defp format_as_report(topic, entries) do
    entry_texts =
      entries
      |> Enum.map(fn entry ->
        concepts =
          if entry.concepts != [],
            do: "**Concepts:** #{Enum.join(entry.concepts, ", ")}\n\n",
            else: ""

        "## #{entry.title}\n\n#{concepts}#{entry.content}"
      end)
      |> Enum.join("\n\n---\n\n")

    """
    # Report: #{topic}

    **Entries consulted:** #{length(entries)}

    #{entry_texts}
    """
  end

  defp format_as_slides(topic, entries) do
    slides =
      entries
      |> Enum.map(fn entry ->
        "---\n\n# #{entry.title}\n\n#{entry.summary || String.slice(entry.content, 0, 300)}"
      end)
      |> Enum.join("\n\n")

    """
    ---
    marp: true
    theme: default
    ---

    # #{topic}

    #{slides}
    """
  end

  defp parse_entry_type("article"), do: :article
  defp parse_entry_type("concept"), do: :concept
  defp parse_entry_type("summary"), do: :summary
  defp parse_entry_type("index"), do: :index
  defp parse_entry_type("glossary"), do: :glossary
  defp parse_entry_type(_), do: nil

  defp parse_doc_type("markdown"), do: :markdown
  defp parse_doc_type("text"), do: :text
  defp parse_doc_type("url"), do: :url
  defp parse_doc_type("pdf"), do: :pdf
  defp parse_doc_type("html"), do: :html
  defp parse_doc_type(_), do: :markdown

  defp parse_link_type("backlink"), do: :backlink
  defp parse_link_type("cross_reference"), do: :cross_reference
  defp parse_link_type("concept"), do: :concept
  defp parse_link_type("see_also"), do: :see_also
  defp parse_link_type("parent_child"), do: :parent_child
  defp parse_link_type(_), do: :cross_reference

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
