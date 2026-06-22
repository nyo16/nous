# Knowledge Base — ETS Store
#
# The Knowledge Base is an LLM-compiled wiki: raw documents get compiled into
# structured entries with summaries, tags, concepts, and [[wiki-links]]. This
# example sticks to the parts that need no LLM and no external deps:
#
#   * initialize an ETS-backed store
#   * add a couple of entries directly
#   * search them with Jaro-distance fuzzy matching
#
# It then *optionally* wires the KB plugin into an agent. That part only does
# real work when an LLM provider is configured, so it degrades gracefully.
#
# Run: mix run examples/knowledge_base.exs

alias Nous.KnowledgeBase
alias Nous.KnowledgeBase.Entry
alias Nous.KnowledgeBase.Store.ETS

# ---------------------------------------------------------------------------
# 1. Initialize an ETS-backed KB store
# ---------------------------------------------------------------------------
#
# The store is ephemeral and run-scoped: init/1 returns table references inside
# `state`, which you thread through subsequent calls. When this process exits,
# ETS reclaims the tables.

{:ok, store} = ETS.init([])

kb_id = "elixir-otp"

# ---------------------------------------------------------------------------
# 2. Add a couple of entries directly
# ---------------------------------------------------------------------------
#
# Entry.new/1 requires :title and :content; it auto-generates id, slug, and
# timestamps. Normally an LLM compiles these from raw documents, but you can
# also create them by hand.

entries = [
  Entry.new(%{
    title: "GenServer",
    content: """
    GenServer is the core OTP abstraction for stateful server processes. It
    provides a client-server model where the server runs in its own process
    and handles synchronous calls and asynchronous casts. See [[supervisor]].
    """,
    summary: "Client-server abstraction for stateful processes.",
    entry_type: :concept,
    concepts: ["genserver", "otp", "processes"],
    tags: ["elixir", "otp"],
    confidence: 0.95,
    kb_id: kb_id
  }),
  Entry.new(%{
    title: "Supervisor",
    content: """
    A Supervisor is a process that monitors child processes and restarts them
    according to a strategy (:one_for_one, :one_for_all, :rest_for_one) when
    they crash. Supervisors are the backbone of OTP fault tolerance.
    """,
    summary: "Process that monitors and restarts children for fault tolerance.",
    entry_type: :concept,
    concepts: ["supervisor", "otp", "fault-tolerance"],
    tags: ["elixir", "otp"],
    confidence: 0.9,
    kb_id: kb_id
  })
]

store =
  Enum.reduce(entries, store, fn entry, s ->
    {:ok, s} = ETS.store_entry(s, entry)
    s
  end)

IO.puts("Stored #{length(entries)} entries in KB \"#{kb_id}\"\n")

# ---------------------------------------------------------------------------
# 3. Search entries with KnowledgeBase.search/4
# ---------------------------------------------------------------------------
#
# search/4 delegates to the store's search_entries/3. It returns
# {:ok, [{entry, score}]} sorted by descending score. We scope by :kb_id so
# only this knowledge base's rows are considered.

queries = [
  "how do processes hold state",
  "restart crashed children",
  "fault tolerance strategy"
]

for query <- queries do
  {:ok, results} =
    KnowledgeBase.search(ETS, store, query, kb_id: kb_id, limit: 3, min_score: 0.0)

  IO.puts("Query: \"#{query}\"")

  for {entry, score} <- results do
    IO.puts("  [#{Float.round(score, 3)}] #{entry.title} — #{entry.summary}")
  end

  IO.puts("")
end

# List every entry in this KB namespace.
{:ok, all} = KnowledgeBase.list_entries(ETS, store, kb_id: kb_id)
IO.puts("Total entries in KB: #{length(all)}")
IO.puts("Slugs: #{all |> Enum.map(& &1.slug) |> Enum.join(", ")}\n")

# ---------------------------------------------------------------------------
# 4. (Optional) Wire the KB plugin into an agent
# ---------------------------------------------------------------------------
#
# The plugin gives an agent 9 KB tools (kb_search, kb_ingest, kb_add_entry,
# kb_read, ...). The store config goes in `deps[:kb_config]`. Note that `deps`
# belongs on Nous.run/3 (the run-time call), NOT on Nous.new/2.
#
# This step needs a running LLM provider. We guard it with a `case` so the
# script still exits cleanly when none is configured.

agent =
  Nous.new("lmstudio:qwen3",
    plugins: [Nous.Plugins.KnowledgeBase],
    instructions: "Answer using the knowledge base. Cite the entries you used."
  )

run_opts = [
  deps: %{
    kb_config: %{
      store: ETS,
      kb_id: kb_id
    }
  }
]

IO.puts("Attempting an LLM-backed KB query (skipped if no provider)...\n")

case Nous.run(agent, "What is a GenServer and how does it relate to supervisors?", run_opts) do
  {:ok, result} ->
    IO.puts("Agent answer:\n#{result.output}")

  {:error, reason} ->
    IO.puts("Skipped LLM step (no provider configured): #{inspect(reason)}")
    IO.puts("Set up a provider (e.g. OPENAI_API_KEY) to see the agent answer.")
end
