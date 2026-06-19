# Memory search baseline (Finding #5 / Phase 4).
#
# Covers two costs:
#   1. ETS text search — `tab2list` full-table copy + per-entry jaro scoring,
#      measured scoped vs unscoped at 100/1k/10k entries.
#   2. Vector cosine — the SQLite store (Exqlite) is an optional dep and is the
#      stub in this build, so search_vector/3 can't run here. We instead micro-
#      bench the cosine math in isolation: the CURRENT impl recomputes the query
#      L2 norm for every candidate (sqlite.ex:512), vs the proposed impl that
#      hoists the query norm out of the loop and uses precomputed candidate norms.
#
#   Run: MIX_ENV=prod mix run bench/memory_search_bench.exs

alias Nous.Memory.Store.ETS, as: ETSStore
alias Nous.Memory.Entry

:rand.seed(:exsss, {17, 23, 42})

# --- 1. ETS text search ----------------------------------------------------
build_table = fn count ->
  {:ok, table} = ETSStore.init([])

  for i <- 1..count do
    entry =
      Entry.new(%{
        content: "memory entry #{i} about topic #{rem(i, 50)} " <> String.duplicate("word ", 20),
        agent_id: "agent_#{rem(i, 10)}"
      })

    ETSStore.store(table, entry)
  end

  table
end

tables = Map.new([100, 1_000, 10_000], fn n -> {n, build_table.(n)} end)

ets_jobs =
  Enum.flat_map([100, 1_000, 10_000], fn n ->
    [
      {"ets search unscoped n=#{n}",
       fn -> ETSStore.search_text(tables[n], "topic 7 word", limit: 10) end},
      {"ets search scoped n=#{n}",
       fn ->
         ETSStore.search_text(tables[n], "topic 7 word", limit: 10, scope: %{agent_id: "agent_3"})
       end}
    ]
  end)
  |> Map.new()

# --- 2. cosine micro-bench (current vs proposed) ---------------------------
dim = 768
n_candidates = 2_000
query = for _ <- 1..dim, do: :rand.uniform()
candidates = for _ <- 1..n_candidates, do: for(_ <- 1..dim, do: :rand.uniform())

# CURRENT (sqlite.ex:512): query magnitude recomputed inside every pair.
cosine_current = fn a, b ->
  dot = a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
  mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
  mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))
  if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
end

# PROPOSED: query norm hoisted out of the loop; candidate norms precomputed
# at insert time (here we precompute once to model the stored-norm column).
norm = fn v -> :math.sqrt(Enum.reduce(v, 0.0, fn x, acc -> acc + x * x end)) end
cand_norms = Enum.map(candidates, norm)
candidates_with_norms = Enum.zip(candidates, cand_norms)

cosine_with_norms = fn a, qnorm, b, bnorm ->
  dot = a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
  if qnorm == 0.0 or bnorm == 0.0, do: 0.0, else: dot / (qnorm * bnorm)
end

cosine_jobs = %{
  "cosine CURRENT (2k x 768, qnorm per-pair)" => fn ->
    Enum.map(candidates, fn c -> cosine_current.(query, c) end)
  end,
  "cosine PROPOSED (2k x 768, qnorm hoisted + stored norms)" => fn ->
    qn = norm.(query)
    Enum.map(candidates_with_norms, fn {c, bn} -> cosine_with_norms.(query, qn, c, bn) end)
  end
}

IO.puts("\n=== ETS text search ===")
Benchee.run(ets_jobs, warmup: 1, time: 3, memory_time: 1, print: [fast_warning: false])

IO.puts("\n=== Vector cosine (SQLite stub here; math benched in isolation) ===")
Benchee.run(cosine_jobs, warmup: 1, time: 3, memory_time: 1, print: [fast_warning: false])
