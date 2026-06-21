# Deep Research Guide

The `Nous.Research` subsystem is an autonomous, multi-step research agent. Given a question, it iteratively plans sub-questions, runs parallel search agents, synthesizes findings (deduplicating claims and detecting contradictions), evaluates what's still unknown, and produces a structured, cited markdown report.

Unlike simple retrieval-augmented generation (RAG), the research loop *re-plans* based on remaining knowledge gaps — it keeps digging until the gaps close or it hits an iteration ceiling.

> #### Not the same as `research_pipeline.exs` {: .warning}
>
> This subsystem is **different** from the hand-built `examples/workflow/research_pipeline.exs`. That example is a fixed three-node `Nous.Workflow` graph (plan → parallel answer → synthesize) that you wire and run yourself — it always does exactly those steps once. `Nous.Research`, by contrast, is a *self-driving loop*: it decides how many sub-questions to spawn, whether to iterate again based on gap analysis, and when to stop. Use the Workflow example when you want explicit, deterministic control over the graph; use `Nous.Research` when you want the system to drive the investigation autonomously. See the [Workflow Engine Guide](workflows.md) for the graph-based approach.

## Quick Start

The only required option is `:search_tool` — without a search tool the searcher has nothing to call and returns an error.

```elixir
{:ok, report} =
  Nous.Research.run(
    "What are the best practices for Elixir deployment in 2026?",
    model: "anthropic:claude-sonnet-4-5-20250929",
    search_tool: &Nous.Tools.BraveSearch.web_search/2,
    max_iterations: 3
  )

IO.puts(report.content)
```

`Nous.Research.run/2` delegates straight to `Nous.Research.Coordinator.run/2`, which runs the whole loop inside a supervised task (more on that below).

## The Five Phases

The coordinator drives a loop over five phases. Each iteration of the loop runs phases 1–4; the loop exits into phase 5 when termination is reached.

1. **Plan** (`Nous.Research.Planner`) — An LLM decomposes the query into 3–7 specific, searchable sub-questions. On iterations after the first, planning is re-targeted at the *remaining gaps* rather than the original query. If planning fails, it falls back to a single-step plan using the query verbatim.
2. **Search** (`Nous.Research.Searcher`) — Each sub-question gets its own isolated search agent. The agent is given your `:search_tool` plus the built-in `Nous.Tools.ResearchNotes` tools (`add_finding`, `add_gap`, `add_contradiction`, …) so it records structured findings as it works.
3. **Synthesize** (`Nous.Research.Synthesizer`) — All findings so far are consolidated: similar claims are merged and re-cited, contradictions between sources are flagged, and remaining gaps are identified.
4. **Evaluate** — The coordinator decides whether to iterate again or stop (see [Termination](#termination)).
5. **Report** (`Nous.Research.Reporter`) — Once stopped, an LLM writes a structured markdown report with an executive summary, cited key findings, contradictions/caveats, gaps, and a numbered source list.

### Supervision

`Coordinator.run/2` does not run the loop in the calling process. It launches it via `Task.Supervisor.async_nolink(Nous.TaskSupervisor, ...)` and waits with a hard `:timeout` (default 10 minutes). This means:

- A crash in the research loop does not bring down the caller, and vice versa.
- Application shutdown can send graceful exits to in-flight research.
- The parallel search phase *also* fans out under `Nous.TaskSupervisor` (`async_stream_nolink`, max concurrency 5, 60s per-step timeout, `on_timeout: :kill_task`).

`Nous.TaskSupervisor` is started by the Nous application, so no setup is required on your end.

If the overall `:timeout` elapses, the task is shut down and `run/2` returns `{:error, :timeout}`. A task exit returns `{:error, {:task_exit, reason}}`.

## Options

All options are passed as the keyword second argument to `Nous.Research.run/2`:

| Option | Default | Notes |
|--------|---------|-------|
| `:search_tool` | — (**required**) | A search function `fn ctx, args -> ... end`, or a list of functions / `%Nous.Tool{}` structs. |
| `:model` | `"openai:gpt-4o-mini"` | Model used for planning, synthesis, and report generation. |
| `:max_iterations` | `5` | Maximum number of plan→search→synthesize loops. |
| `:timeout` | `:timer.minutes(10)` | Hard wall-clock limit for the whole run, in milliseconds. |
| `:strategy` | `:parallel` | `:parallel`, `:sequential`, or `:tree` (see below). |
| `:deps` | `%{}` | Dependencies threaded into search tools — e.g. API keys. |
| `:on_plan_ready` | none | HITL callback to review/edit/reject the plan. |
| `:on_iteration_complete` | none | HITL callback after each iteration. |
| `:callbacks` | none | `%{on_progress: fn event -> ... end}`. |
| `:notify_pid` | none | PID to receive `{:research_progress, ...}` / `{:research_finding, ...}` messages. |
| `:session_id` | none | Broadcasts progress over `Nous.PubSub` (see [Progress streaming](#progress-streaming)). |

### Strategy

The `:strategy` controls how the planner decomposes the query and how the coordinator executes the steps:

- `:parallel` (default) — Independent sub-questions, executed simultaneously via `async_stream_nolink` (max concurrency 5).
- `:sequential` — Steps run one after another; each step is tagged as depending on the previous one. Use when later sub-questions need earlier results.
- `:tree` — Branching exploration. At execution time the coordinator treats any non-`:sequential` strategy as parallel, so `:tree` currently fans out like `:parallel` while influencing how the planner phrases the decomposition.

## Supplying a Search Tool

The search tool is whatever the per-sub-question agent calls to gather information. Nous ships several built-in tools you can pass directly. Each is a 2-arity function `(ctx, args)` and reads its API key from `ctx.deps`, application config, or the environment — in that order.

### Tavily (purpose-built for AI research)

Returns clean, pre-extracted content (no HTML parsing needed). Get a key from <https://tavily.com>.

```elixir
Nous.Research.run("...",
  search_tool: &Nous.Tools.TavilySearch.search/2,
  deps: %{tavily_api_key: System.fetch_env!("TAVILY_API_KEY")}
)
```

### Brave Search

High-quality web results with a privacy focus. Get a key from <https://brave.com/search/api/>.

```elixir
Nous.Research.run("...",
  search_tool: &Nous.Tools.BraveSearch.web_search/2,
  deps: %{brave_api_key: System.fetch_env!("BRAVE_API_KEY")}
)
```

Or let it fall through to the `BRAVE_API_KEY` environment variable / `config :nous, brave_api_key: ...`.

### SearchScrape (fetch + summarize many URLs)

`Nous.Tools.SearchScrape.scrape_results/2` fetches and summarizes multiple URLs in parallel (built on `WebFetch` + `Summarize`, also under `Nous.TaskSupervisor`). It needs a summary model in `:deps`. Pair it with a search tool so the agent first finds URLs, then scrapes them:

```elixir
Nous.Research.run("...",
  search_tool: [
    &Nous.Tools.BraveSearch.web_search/2,
    &Nous.Tools.SearchScrape.scrape_results/2
  ],
  deps: %{
    brave_api_key: System.fetch_env!("BRAVE_API_KEY"),
    summary_model: "openai:gpt-4o-mini"
  }
)
```

`Nous.Tools.WebFetch.fetch_page/2` (requires the optional `floki` dependency) is another option for pulling readable content from a single page, with SSRF protection and per-hop redirect validation built in.

### Custom search tools

Any `(ctx, args)` function that returns a map works. The searcher wraps it with `Nous.Tool.from_function/1` automatically, alongside the `ResearchNotes` tools the agent uses to record findings. You can pass a single function or a list mixing functions and pre-built `%Nous.Tool{}` structs:

```elixir
search_tool: [
  &Nous.Tools.BraveSearch.web_search/2,    # function — auto-wrapped
  my_custom_tool_struct                     # %Nous.Tool{} — used as-is
]
```

### How findings are recorded

Inside a search agent, the LLM is instructed to call `add_finding` for each fact (with `source_url`, `source_title`, and a `confidence` score). `ResearchNotes` deduplicates near-identical claims (Jaro distance > 0.85) and accumulates them in the agent's context deps. The searcher then converts each recorded entry into a `Nous.Research.Finding` struct tagged with the originating sub-question. A search agent that fails is logged and contributes an empty finding list rather than aborting the whole run.

## Human-in-the-Loop Checkpoints

Two callbacks let you intervene without blocking the loop's structure.

`:on_plan_ready` runs once per planning phase. Return:

- `:approve` — execute the plan as-is (the default when no callback is set).
- `{:edit, modified_plan}` — execute your edited plan instead.
- `:reject` — abort; `run/2` returns `{:error, :plan_rejected}`.

```elixir
Nous.Research.run("Compare React vs Svelte for enterprise apps",
  model: "openai:gpt-4o",
  search_tool: &Nous.Tools.BraveSearch.web_search/2,
  on_plan_ready: fn plan ->
    IO.inspect(plan.steps, label: "Research Plan")
    :approve
  end,
  on_iteration_complete: fn synthesis ->
    IO.puts("Gaps remaining: #{length(synthesis[:gaps] || [])}")
    :continue
  end
)
```

`:on_iteration_complete` runs after each iteration's synthesis. It receives the synthesis map and returns `:continue` or `:stop`. Note this callback is only consulted when neither the iteration cap nor the "no gaps left" condition has already decided to stop.

## Progress Streaming

For UIs (e.g. LiveView) you can observe the loop as it runs through three channels — all driven by the coordinator's internal `notify/2`:

- **`:notify_pid`** — sends messages to a PID:
  - `{:research_progress, %{phase: :planning | :searching | :synthesizing | :evaluating | :reporting, iteration: n, ...}}`
  - `{:research_finding, %{query: "...", phase: :searching}}` (per sub-question as it starts)
- **`:callbacks`** — `%{on_progress: fn event -> ... end}` receives the same events.
- **`:session_id`** — broadcasts the same events over `Nous.PubSub` to the topic `nous:research:<session_id>`. Subscribe with `Nous.PubSub.research_topic(session_id)` and it uses the configured PubSub (`Nous.PubSub.configured_pubsub/0`) unless you pass `:pubsub`.

```elixir
Nous.Research.run("...",
  search_tool: &search/2,
  notify_pid: self()
)

receive do
  {:research_progress, %{phase: phase}} -> IO.puts("phase: #{phase}")
end
```

## Termination

Evaluation stops the loop when **any** of these hold:

1. `iteration >= max_iterations`.
2. The latest synthesis has no remaining gaps.
3. The `:on_iteration_complete` callback returns `:stop`.

Otherwise the loop re-plans against the remaining gaps and runs again.

## The Returned Report

On success `run/2` returns `{:ok, %Nous.Research.Report{}}`:

| Field | Type | Meaning |
|-------|------|---------|
| `:title` | `String.t()` | Title parsed from the report's first line. |
| `:query` | `String.t()` | The original research question. |
| `:content` | `String.t()` | Full markdown report with inline `[N]` citations. |
| `:findings` | `[Finding.t()]` | Every raw finding collected across iterations. |
| `:sources` | `[%{url:, title:}]` | Deduplicated source list. |
| `:gaps` | `[String.t()]` | Knowledge gaps still open at completion. |
| `:iterations` | `non_neg_integer()` | Number of loops executed. |
| `:total_tokens` | `non_neg_integer()` | Token accounting. |
| `:duration_ms` | `non_neg_integer()` | Wall-clock duration. |
| `:completed_at` | `DateTime.t()` | Completion timestamp. |

Each `Nous.Research.Finding` is a single recorded fact:

| Field | Type | Meaning |
|-------|------|---------|
| `:claim` | `String.t()` | The factual statement (required). |
| `:source_url` | `String.t() \| nil` | Where it came from. |
| `:source_title` | `String.t() \| nil` | Title of the source. |
| `:confidence` | `float()` | 0.0–1.0, defaults to `0.5`. |
| `:search_query` | `String.t() \| nil` | The sub-question that produced it. |
| `:timestamp` | `DateTime.t()` | When it was recorded. |

`report.content` is the human-facing artifact; `report.findings` and `report.sources` are the structured backing data if you want to render citations yourself.

## Related Guides

- [Workflow Engine Guide](workflows.md) — the graph-based engine behind `research_pipeline.exs`, for when you want explicit, deterministic orchestration instead of an autonomous loop.
- The built-in search tools live in `Nous.Tools.TavilySearch`, `Nous.Tools.BraveSearch`, `Nous.Tools.WebFetch`, `Nous.Tools.SearchScrape`, and `Nous.Tools.ResearchNotes`.
