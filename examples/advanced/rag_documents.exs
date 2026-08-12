#!/usr/bin/env elixir

# RAG over Documents — Retrieval-Augmented Generation with Citations
#
# `examples/knowledge_base.exs` shows the Knowledge Base *API*. This example
# shows the *pattern*: a complete, offline retrieval-augmented pipeline built
# over this repository's own `docs/` directory.
#
#   Part 1 — Discover:  Nous.Tools.FileGlob finds the source markdown files,
#                       constrained to the workspace root by PathGuard.
#   Part 2 — Chunk:     fence-aware heading segmentation with a size cap and
#                       overlap. This is the step readers get wrong; the long
#                       comment on RagChunker explains every choice.
#   Part 3 — Ingest:    one Nous.KnowledgeBase.Document per file, one
#                       Nous.KnowledgeBase.Entry per chunk, into an ETS store.
#   Part 4 — Retrieve:  BM25 over the chunks, with citations back to the source
#                       file and heading. Compared against the store's built-in
#                       KnowledgeBase.search/4 so you can see what each is for.
#   Part 5 — Augment:   assemble the grounded prompt with numbered citations.
#   Part 6 — Generate:  hand the prompt to an agent, wiring the *already
#                       populated* store into Nous.Plugins.KnowledgeBase via
#                       `store_state:` so the agent's kb_* tools search the
#                       same chunks instead of an empty KB.
#
# Parts 1-5 are pure local computation: no API key, no network, no optional
# deps. Only Part 6 needs a provider, and it is guarded.
#
# Run: mix run examples/advanced/rag_documents.exs
#
# For Part 6, set OPENAI_API_KEY or ANTHROPIC_API_KEY. Any provider works —
# edit the `model` binding in Part 6 for "lmstudio:qwen3", "ollama:...", etc.

alias Nous.KnowledgeBase
alias Nous.KnowledgeBase.{Document, Entry}
alias Nous.KnowledgeBase.Store.ETS

# Ingest bound: the first 6 files of docs/guides/*.md in alphabetical order.
# Bounded on purpose — the full docs/ tree includes 50-80 KB review documents
# that make the example slow to read and slow to run. Six guides is a few
# hundred chunks, which is enough for BM25 to have real competition.
doc_glob = "guides/*.md"
doc_limit = 6

# Chunking parameters (see RagChunker below for why).
max_chunk_chars = 1_200
chunk_overlap_chars = 200

# =============================================================================
# Chunker
# =============================================================================

defmodule RagChunker do
  @moduledoc """
  Markdown chunker for retrieval.

  ## Why heading-scoped chunks, capped, with overlap

  Three strategies are common, and only the third survives contact with real
  documentation:

    1. **Whole file per chunk.** Trivial, and useless: a 20 KB guide matches
       every query a little and answers none of them precisely. You also blow
       the context budget retrieving a single hit.

    2. **Fixed-size windows.** Cheap and uniform, but the cut lands mid
       sentence and mid table, and — fatally for this example — the chunk
       carries no heading, so there is nothing to cite except a byte offset.

    3. **Heading-scoped, capped, overlapped** (what we do). The author already
       grouped the prose under headings, so a heading section is a coherent
       retrieval unit *and* its heading is a free, human-meaningful citation
       anchor. Two corrections are still needed:

       * **Cap the size.** Heading sections are wildly uneven — a "Configuration"
         section can be 6 KB. Sections over `max_chars` are split into windows.
       * **Overlap the splits.** A fact that straddles a cap-split would
         otherwise be in neither window intact; replaying the last
         `overlap_chars` of the previous window into the next one keeps it
         retrievable. Overlap is only needed at cap-splits, never at heading
         boundaries, so it costs almost nothing.

  ## The fence trap

  Detecting headings with `String.starts_with?(line, "#")` is wrong for any
  document that contains code. In an Elixir fence, `# Configure the client` is
  a comment, not an H1 — and a naive splitter happily emits a chunk titled
  "Configure the client". This chunker tracks ``` fences and only treats `#`
  as a heading outside of them.
  """

  @heading ~r/^(\#{1,3})\s+(.+?)\s*$/

  @doc """
  Chunk a markdown string into `{heading, body}` sections.

  Returns `{doc_title, chunks}` where `chunks` is a list of
  `%{heading: String.t(), body: String.t()}` in document order.
  """
  def chunk(markdown, fallback_title, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chars, 1_200)
    overlap = Keyword.get(opts, :overlap, 200)

    sections =
      markdown
      |> String.split("\n")
      |> outside_fences()
      |> segment()

    doc_title =
      Enum.find_value(sections, fallback_title, fn
        {1, title, _lines} -> title
        _ -> nil
      end)

    chunks =
      sections
      |> Enum.flat_map(fn {_level, heading, lines} ->
        body = lines |> Enum.join("\n") |> String.trim()
        heading = if heading == "", do: doc_title, else: heading

        # Drop navigational stubs: a heading whose section holds a link list or
        # nothing at all is noise that outranks real prose on short queries.
        if String.length(body) < 80 do
          []
        else
          body
          |> windows(max_chars, overlap)
          |> Enum.map(&%{heading: heading, body: &1})
        end
      end)

    {doc_title, chunks}
  end

  # Tag each line with whether it sits inside a ``` fence.
  defp outside_fences(lines) do
    {tagged, _} =
      Enum.map_reduce(lines, false, fn line, in_fence? ->
        fence? = String.match?(line, ~r/^\s*(```|~~~)/)
        # The fence delimiter itself is never a heading, so tag it as "inside"
        # regardless of which side of the toggle it is on.
        {{line, in_fence? or fence?}, if(fence?, do: not in_fence?, else: in_fence?)}
      end)

    tagged
  end

  # Fold tagged lines into {level, heading, lines} sections.
  defp segment(tagged) do
    tagged
    |> Enum.reduce([{0, "", []}], fn
      {line, false}, [{level, heading, lines} | rest] = acc ->
        case Regex.run(@heading, line) do
          [_, hashes, title] ->
            [{String.length(hashes), title, []}, {level, heading, Enum.reverse(lines)} | rest]

          nil ->
            [{level, heading, [line | lines]} | tl(acc)]
        end

      {line, true}, [{level, heading, lines} | rest] ->
        [{level, heading, [line | lines]} | rest]
    end)
    |> then(fn [{level, heading, lines} | rest] ->
      Enum.reverse([{level, heading, Enum.reverse(lines)} | rest])
    end)
  end

  # Split an oversized section into overlapping windows.
  defp windows(body, max_chars, overlap) do
    if String.length(body) <= max_chars do
      [body]
    else
      head = cut(body, max_chars)
      taken = String.length(head)
      rest = String.slice(body, taken, String.length(body) - taken)
      # Trim the partial word the fixed-size slice inevitably starts on, so a
      # window never opens mid-token ("...valuation](evaluation.md)").
      carry = head |> String.slice(max(taken - overlap, 0), overlap) |> drop_partial_word()

      [String.trim(head) | windows(carry <> rest, max_chars, overlap)]
    end
  end

  # Cut at the last line break inside the budget so windows stay line-aligned.
  # Fall back to a hard cut when a single line is longer than half the budget —
  # that also guarantees each cut consumes more than `overlap`, so `windows/3`
  # always makes progress.
  defp cut(body, max_chars) do
    candidate = String.slice(body, 0, max_chars)
    head = candidate |> String.split("\n") |> Enum.drop(-1) |> Enum.join("\n")

    if String.length(head) >= div(max_chars, 2), do: head <> "\n", else: candidate
  end

  defp drop_partial_word(carry) do
    case String.split(carry, ~r/\s/, parts: 2) do
      [_partial, rest] -> rest
      [_only] -> carry
    end
  end
end

# =============================================================================
# Retriever
# =============================================================================

defmodule Bm25 do
  @moduledoc """
  A ~40-line BM25 ranker over the chunk corpus.

  The ETS knowledge-base store scores with `String.jaro_distance/2`, which is
  whole-string edit similarity: excellent for "find the entry whose *title* is
  roughly this", useless for "find the chunk that *contains these terms*". A
  short question against a 1 KB chunk is nearly all edit distance, so ranking
  degenerates to noise (Part 4 prints both so you can see it).

  Production retrievers usually add embeddings. Note where they live: the KB
  `Entry` struct has an `:embedding` field and the plugin accepts an
  `:embedding` provider, but `Nous.KnowledgeBase.Store` declares no vector
  callback, so the ETS store *keeps* vectors without ranking by them. Hybrid
  text-plus-vector search today is `Nous.Memory.Search.search/5` over a
  vector-capable memory store. BM25 is what you use in the meantime: no model,
  no key, no network, and a strong enough baseline to keep in the hybrid.
  """

  # Deliberately tiny: query words that carry no retrieval signal.
  @stopwords MapSet.new(
               ~w(a an and any are as at be by can do does for from get has have how i if in
                  into is it its me my of on or should that the their there these this to use
                  using was what when where which who why will with you your)
             )

  # Standard BM25 constants: k1 dampens term-frequency saturation, b controls
  # how hard long documents are penalised.
  @k1 1.2
  @b 0.75

  def index(chunks) do
    docs =
      Enum.map(chunks, fn chunk ->
        # Headings are short and high-signal, so count their terms three times
        # (once from the body, twice from this prefix) before tokenising.
        tokens = tokenize(chunk.heading <> "\n" <> chunk.heading <> "\n" <> chunk.body)
        %{chunk: chunk, freqs: Enum.frequencies(tokens), len: length(tokens)}
      end)

    df =
      docs
      |> Enum.flat_map(fn doc -> Map.keys(doc.freqs) end)
      |> Enum.frequencies()

    total_len = Enum.reduce(docs, 0, fn doc, acc -> acc + doc.len end)

    %{
      docs: docs,
      df: df,
      count: length(docs),
      avg_len: if(docs == [], do: 1.0, else: total_len / length(docs))
    }
  end

  def search(index, query, limit \\ 3) do
    terms = tokenize(query)

    index.docs
    |> Enum.map(fn doc -> {doc.chunk, score(index, doc, terms)} end)
    |> Enum.filter(fn {_chunk, score} -> score > 0.0 end)
    |> Enum.sort_by(fn {_chunk, score} -> score end, :desc)
    |> Enum.take(limit)
  end

  defp score(index, doc, terms) do
    Enum.reduce(terms, 0.0, fn term, acc ->
      case Map.get(doc.freqs, term, 0) do
        0 ->
          acc

        freq ->
          df = Map.get(index.df, term, 0)
          idf = :math.log(1 + (index.count - df + 0.5) / (df + 0.5))
          norm = @k1 * (1 - @b + @b * doc.len / index.avg_len)
          acc + idf * freq * (@k1 + 1) / (freq + norm)
      end
    end)
  end

  def tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 2 or &1 in @stopwords))
  end
end

# =============================================================================
# Part 1: Discover source documents with Nous.Tools.FileGlob
# =============================================================================

IO.puts("=== Part 1: Discover documents (Nous.Tools.FileGlob) ===\n")

# PathGuard resolves every tool path against `deps[:workspace_root]`, falling
# back to File.cwd!/0. Anything that escapes the root — via "..", an absolute
# path or a symlink — is rejected before the glob runs, so the repository root
# is the legal root here and "docs" is a relative path inside it.
ctx = Nous.RunContext.new(%{workspace_root: File.cwd!()})

files =
  case Nous.Tools.FileGlob.execute(ctx, %{"pattern" => doc_glob, "path" => "docs"}) do
    {:ok, "No files matched" <> _ = message} ->
      IO.puts(message)
      IO.puts("Run this from the repository root: mix run examples/advanced/rag_documents.exs")
      System.halt(0)

    {:ok, listing} ->
      # FileGlob returns newest-first. Sort by name instead so the corpus (and
      # therefore this example's output) is stable across runs.
      listing |> String.split("\n", trim: true) |> Enum.sort() |> Enum.take(doc_limit)

    {:error, reason} ->
      IO.puts("Glob rejected by PathGuard: #{reason}")
      System.halt(0)
  end

root = File.cwd!()
relative = fn path -> Path.relative_to(path, root) end

IO.puts("Workspace root: #{root}")
IO.puts("Pattern:        docs/#{doc_glob} (bounded to #{doc_limit} files)\n")
Enum.each(files, fn file -> IO.puts("  #{relative.(file)}") end)

# =============================================================================
# Part 2: Chunk
# =============================================================================

IO.puts("\n=== Part 2: Chunk (heading-scoped, #{max_chunk_chars} char cap) ===\n")

chunks =
  Enum.flat_map(files, fn path ->
    source = relative.(path)
    markdown = File.read!(path)

    {doc_title, sections} =
      RagChunker.chunk(markdown, Path.basename(path, ".md"),
        max_chars: max_chunk_chars,
        overlap: chunk_overlap_chars
      )

    sections
    |> Enum.with_index(1)
    |> Enum.map(fn {section, position} ->
      Map.merge(section, %{
        source: source,
        doc_title: doc_title,
        position: position,
        total: length(sections)
      })
    end)
  end)

sizes = chunks |> Enum.map(&String.length(&1.body)) |> Enum.sort()

IO.puts("Files chunked:  #{length(files)}")
IO.puts("Chunks:         #{length(chunks)}")

IO.puts(
  "Chunk chars:    min #{List.first(sizes)} / median #{Enum.at(sizes, div(length(sizes), 2))} / max #{List.last(sizes)}"
)

IO.puts("Per file:")

chunks
|> Enum.group_by(& &1.source)
|> Enum.sort()
|> Enum.each(fn {source, group} -> IO.puts("  #{length(group)}\t#{source}") end)

sample = Enum.max_by(chunks, &String.length(&1.body))

IO.puts("""

Largest chunk (capped at #{max_chunk_chars}):
  source:  #{sample.source}
  heading: #{sample.heading}
  chars:   #{String.length(sample.body)}
""")

# =============================================================================
# Part 3: Ingest into the Knowledge Base
# =============================================================================

IO.puts("=== Part 3: Ingest into Nous.KnowledgeBase (ETS store) ===\n")

# Note on Nous.KnowledgeBase.ingest/2: that entry point runs the *compilation*
# pipeline (extract concepts -> compile wiki entries -> generate links) and
# every one of those nodes is an LLM step, so it needs a provider:
#
#     {:ok, state} = Nous.KnowledgeBase.ingest(
#       [%{title: "...", content: "...", doc_type: :markdown}],
#       kb_config: %{store: ETS, store_state: store, kb_id: kb_id},
#       compiler_model: "openai:gpt-4o-mini"
#     )
#
# RAG does not want compilation: it wants the source text stored verbatim so
# retrieval quotes what the docs actually say. So we write to the store
# directly — Document per file (provenance), Entry per chunk (retrieval unit).

kb_id = "nous-docs"
{:ok, store} = ETS.init([])

{store, doc_ids} =
  Enum.reduce(files, {store, %{}}, fn path, {acc, ids} ->
    source = relative.(path)
    content = File.read!(path)

    doc =
      Document.new(%{
        title: source,
        content: content,
        doc_type: :markdown,
        source_path: source,
        # :compiled, not :pending — nothing downstream should try to compile
        # these into wiki entries; the chunks below already stand in for that.
        status: :compiled,
        kb_id: kb_id
      })

    {:ok, acc} = ETS.store_document(acc, doc)
    {acc, Map.put(ids, source, doc.id)}
  end)

store =
  chunks
  |> Enum.with_index(1)
  |> Enum.reduce(store, fn {chunk, n}, acc ->
    entry =
      Entry.new(%{
        title: "#{chunk.doc_title} — #{chunk.heading}",
        # Slugs are the store's secondary index, so they must be unique:
        # two chunks of one section share a heading and would collide.
        slug: "#{Path.basename(chunk.source, ".md")}-#{n}",
        content: chunk.body,
        entry_type: :article,
        # Verbatim source text, not an LLM inference — full confidence.
        confidence: 1.0,
        tags: [Path.basename(chunk.source, ".md")],
        source_doc_ids: [Map.fetch!(doc_ids, chunk.source)],
        # Metadata carries the citation. String keys: entries are handed to the
        # model by the kb_* tools, so keep them JSON-shaped.
        metadata: %{
          "source_path" => chunk.source,
          "heading" => chunk.heading,
          "chunk" => "#{chunk.position}/#{chunk.total}"
        },
        kb_id: kb_id
      })

    {:ok, acc} = ETS.store_entry(acc, entry)
    acc
  end)

{:ok, stored_docs} = KnowledgeBase.list_documents(ETS, store, kb_id: kb_id)
{:ok, stored_entries} = KnowledgeBase.list_entries(ETS, store, kb_id: kb_id)

IO.puts("Documents stored: #{length(stored_docs)}")
IO.puts("Entries stored:   #{length(stored_entries)}\n")

# =============================================================================
# Part 4: Retrieve, with citations
# =============================================================================

IO.puts("=== Part 4: Retrieve (BM25 over chunks) ===\n")

index = Bm25.index(chunks)

cite = fn chunk -> "#{chunk.source} § \"#{chunk.heading}\" (chunk #{chunk.position}/#{chunk.total})" end

snippet = fn chunk ->
  chunk.body
  |> String.replace(~r/\s+/, " ")
  |> String.slice(0, 160)
  |> Kernel.<>("...")
end

queries = [
  "how do I write a custom provider adapter?",
  "how should I handle retries and rate limits in production?",
  "how are evaluation datasets scored?"
]

for query <- queries do
  IO.puts("Q: #{query}")

  case Bm25.search(index, query, 3) do
    [] ->
      IO.puts("  (no chunk contained any query term)\n")

    hits ->
      for {chunk, score} <- hits do
        IO.puts("  [#{Float.round(score, 2)}] #{cite.(chunk)}")
        IO.puts("        #{snippet.(chunk)}")
      end

      IO.puts("")
  end
end

# The store's own search for contrast. KnowledgeBase.search/4 delegates to
# search_entries/3, which on the ETS backend is Jaro distance against the whole
# entry — so it ranks by how much the query *looks like* the text, not by which
# terms it contains. Use it to find an entry by approximate title; use BM25 or
# an :embedding provider to find a chunk by content.
IO.puts("Same query through KnowledgeBase.search/4 (Jaro distance, for contrast):")
[contrast_query | _] = queries
{:ok, jaro_hits} = KnowledgeBase.search(ETS, store, contrast_query, kb_id: kb_id, limit: 3)

for {entry, score} <- jaro_hits do
  IO.puts(
    "  [#{Float.round(score, 2)}] #{entry.metadata["source_path"]} § \"#{entry.metadata["heading"]}\""
  )
end

# =============================================================================
# Part 5: Augment — build the grounded prompt
# =============================================================================

IO.puts("\n=== Part 5: Augment (grounded prompt with numbered citations) ===\n")

question = "How do I connect Nous to a custom OpenAI-compatible provider endpoint?"
retrieved = Bm25.search(index, question, 4)

context_block =
  retrieved
  |> Enum.with_index(1)
  |> Enum.map(fn {{chunk, _score}, n} -> "[#{n}] #{cite.(chunk)}\n#{chunk.body}" end)
  |> Enum.join("\n\n---\n\n")

prompt = """
Answer the question using ONLY the context below. Every claim must carry the
citation marker of the chunk it came from, e.g. [1]. If the context does not
contain the answer, say so — do not fall back on prior knowledge.

# Context

#{context_block}

# Question

#{question}
"""

IO.puts("Question:        #{question}")
IO.puts("Chunks retrieved: #{length(retrieved)}")
IO.puts("Prompt chars:     #{String.length(prompt)}")
IO.puts("Citations:")

retrieved
|> Enum.with_index(1)
|> Enum.each(fn {{chunk, score}, n} ->
  IO.puts("  [#{n}] #{cite.(chunk)}  (bm25 #{Float.round(score, 2)})")
end)

# =============================================================================
# Part 6: Generate — wire the populated store into the agent
# =============================================================================

IO.puts("\n=== Part 6: Generate (needs a provider) ===\n")

# THE key detail. Nous.Plugins.KnowledgeBase reads deps[:kb_config], and
# Plugin.init/2 runs on *every* agent run. Without :store_state the plugin
# calls ETS.init/1 each time, handing the agent a brand-new empty store — its
# kb_search tool would find nothing and the retrieval above would be wasted.
# Passing :store_state makes the plugin reuse this populated store verbatim.
kb_config = %{
  store: ETS,
  store_state: store,
  kb_id: kb_id,
  # Top up the prompt with anything the plugin's own search turns up, once.
  auto_inject: true,
  inject_strategy: :first_only,
  inject_limit: 3
}

IO.puts("kb_config keys: #{kb_config |> Map.keys() |> Enum.sort() |> inspect()}")

IO.puts(
  "store_state reused: #{Map.has_key?(kb_config, :store_state) and kb_config.store_state == store}"
)

model =
  cond do
    System.get_env("OPENAI_API_KEY") -> "openai:gpt-4o-mini"
    System.get_env("ANTHROPIC_API_KEY") -> "anthropic:claude-sonnet-4-5-20250929"
    true -> nil
  end

if model do
  IO.puts("Model: #{model}\n")

  agent =
    Nous.new(model,
      plugins: [Nous.Plugins.KnowledgeBase],
      instructions: """
      You answer questions about the Nous library from its own documentation.
      Ground every statement in the provided context and cite it as [n]. You
      also have kb_search / kb_read tools over the same chunks — use them if
      the provided context is not enough.
      """
    )

  case Nous.run(agent, prompt, deps: %{kb_config: kb_config}) do
    {:ok, result} ->
      IO.puts("Answer:\n#{result.output}")
      IO.puts("\nIterations: #{result.iterations}")

    {:error, reason} ->
      # Provider errors are structs with a :message field; keep the print short.
      detail = if is_map(reason), do: Map.get(reason, :message) || inspect(reason), else: inspect(reason)
      IO.puts("Generation failed: #{String.slice(detail, 0, 240)}")
  end
else
  IO.puts("""

  Skipping generation: no provider configured.

  Parts 1-5 above are the whole retrieval pipeline and ran for real. To see the
  final generated answer, set one of:

      export OPENAI_API_KEY=sk-...
      export ANTHROPIC_API_KEY=sk-ant-...

  then re-run:

      mix run examples/advanced/rag_documents.exs

  Any provider works — for a local server, replace the `model` binding above
  with "lmstudio:qwen3" or "ollama:llama3.1".
  """)
end
