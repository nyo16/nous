# Online Evaluation Guide

`Nous.Eval.Online` samples your production agent runs, redacts them, scores
them in the background and stores them next to your offline eval runs. It
answers "how is the agent doing on real traffic?" without slowing a single
request and without keeping content you did not decide to keep. Interesting
samples can then be promoted into offline datasets and guard calibration
sets.

Online evaluation is **off by default**. Nothing is captured until you add the
child to your supervision tree, and the child refuses to start unless you have
decided how content is redacted, how long samples are kept, and (when a scorer
calls a model) how much scoring may cost.

## Contents

- [Quick start](#quick-start)
- [How a run is captured](#how-a-run-is-captured)
- [Redaction](#redaction)
- [Rules and scorers](#rules-and-scorers)
- [Budget](#budget)
- [Backpressure and coverage](#backpressure-and-coverage)
- [Storage and retention](#storage-and-retention)
- [Reading samples](#reading-samples)
- [Promotion and the review queue](#promotion-and-the-review-queue)
- [OpenTelemetry export](#opentelemetry-export)
- [Multiple nodes](#multiple-nodes)
- [Testing your setup](#testing-your-setup)
- [Configuration reference](#configuration-reference)

## Quick start

```elixir
# lib/my_app/application.ex
children = [
  # ...
  {Nous.Eval.Online,
   sample_rate: 0.05,
   redact: MyApp.TraceRedactor,
   store: {Nous.Eval.Store.File, root: "/var/lib/my_app/nous-online"},
   retention: [max_age: {14, :day}],
   rules: [
     [name: "health", scorers: [Nous.Eval.Scorers.NoToolErrors,
                                {Nous.Eval.Scorers.MaxLatency, max_ms: 10_000}]],
     [name: "quality", sample_rate: 0.01,
      scorers: [{Nous.Eval.Scorers.Judge,
                 judge: "openai:gpt-4o-mini",
                 rubric: "The answer resolves the user's request."}]]
   ],
   budget: [max_cost: 2.0, per: :hour]}
]
```

```elixir
defmodule MyApp.TraceRedactor do
  @behaviour Nous.Eval.Online.Redactor

  @email ~r/[\w.+-]+@[\w-]+\.[\w.]+/
  @card ~r/\b(?:\d[ -]?){13,19}\b/

  @impl true
  def redact(content) do
    Nous.Eval.Online.Redactor.map_text(content, fn text ->
      text |> String.replace(@email, "[email]") |> String.replace(@card, "[card]")
    end)
  end

  @impl true
  def version, do: "2026-11-01"
end
```

That is all: every `Nous.run/3`, `run_stream/3` and `Nous.AgentServer` turn
of your application is now a candidate.

## How a run is captured

At the **root** `[:nous, :agent, :run, :start]` of a run, a telemetry handler
in the request process decides:

1. Runs Nous starts for itself (`role` `:judge`, `:simulator`,
   `:reflector`) and sub-agent runs are skipped. Sub-agents belong to their
   root's trace and are captured with it. Online scorers run under the
   `:judge` role, so online eval never samples its own judge calls.
2. The decision is **deterministic**: the trace id's low 56 bits are compared
   with `sample_rate * 2^56` (the OpenTelemetry probability-sampler rule,
   `Nous.Eval.Online.Sampler`). The same trace gets the same decision on every
   node and after every restart, and a lower rate always samples a subset of
   a higher one. With `sample_by: :session`, the session id
   (`deps[:session_id]`, or the `Nous.AgentServer` session) is the key
   instead, so all turns of a sampled conversation are captured.

   Without a salt, the session decision is a public function of the session
   id: anyone can compute it with `Nous.Eval.Online.sampled?/2`, so a client
   that picks its own session ids can choose ones that are never sampled.
   Set `sampling_salt:` to a secret binary of at least 16 bytes (e.g.
   `:crypto.strong_rand_bytes(32)`, kept in runtime config) and the
   key is `HMAC-SHA-256(salt, session_id)` instead, which nobody without the
   salt can predict. It is still deterministic across nodes and restarts as
   long as every node has the same salt; changing it reshuffles which
   sessions are sampled.
3. The `agents:` allowlist and your `filter:` apply. The filter runs on the
   request path: keep it cheap and pure. A raise or a non-boolean answer means
   "not captured" and is counted, never propagated to the request.
4. Admission: at most `max_in_flight` traces are being captured at once;
   beyond that new runs are not captured (and counted).

The run's events are then collected like an offline eval sample
(`Nous.Eval.Trace`). When the root run stops, the trace is handed to the
instance's coordinator with a single `send/2`. **The request path never calls
a process, never waits, and never blocks**; a full queue drops the new trace
and counts it.

A run that never stops (a killed process, a cancelled turn, an abandoned
stream) is finalized after `max_trace_age` as `outcome: :killed` with
`abandoned: true`, so its partial trace is still visible. A stopped trace
waiting in the coordinator's queue is never expired, however long the
backlog; only a trace whose job was lost with a crashed coordinator is
discarded after `max_trace_age` and counted `lost`.

## Redaction

Every captured trace passes through `redact:` **before anything else sees
it**: scorers, the store, the exporter. Raw content exists only in the
background job that finalizes the trace, for the time it takes to redact it.

The trace is split into a read-only **skeleton** and **content**
(`Nous.Eval.Online.Content`):

| Skeleton (always kept) | Content (redactor decides) |
|---|---|
| trace, run and tool-call ids; agent, model, tool and hook names; roles; iterations; timings; token counts; cost; tool `outcome` and `approval`; guard `verdict`, `severity`, `action`, `surface`; `finish_reason`; the error *kind* | prompts and `messages` (including each message's `metadata.content_parts`, which providers send instead of `content`), model `response`, tool `arguments` and `result`, error reasons and stack traces, guard reasons, `session_id`, and any key a later Nous version adds |

A tool name the model chose (a tool call's `tool_name`, a requested call in
`requested_tool_calls`) is skeleton only when the run offered that tool: it
is in the `tool_names` or `blocked_tool_names` of the same run's model
requests. A model can put any text in a tool name, so any other name is
content, and the redactor decides what survives of it (under
`:drop_content` the call keeps its id and loses the name).

`redact:` takes one of:

- `:drop_content` - keep the skeleton only. Scorers that read content refuse
  to start under it.
- a module implementing `Nous.Eval.Online.Redactor`, or a 1-arity function.
  It receives the `Content` and may replace values (with other JSON values or
  `:redacted`); it may not add or remove paths, or touch the skeleton.
  `Nous.Eval.Online.Redactor.map_text/2` applies a function to every piece of
  text and leaves the stored structure intact.

If the redactor raises, throws, exits, takes longer than `redact_timeout`, or
returns something that breaks the contract, the sample is stored **without
content**, marked `redaction: "failed"` with the failure kind. The exception
and its message are discarded unread: they may quote the content.

Score explanations are content too (a judge may quote the user): a score's
`reason` and `details`, and a scorer error's `reason`, are passed through the
same redactor and dropped under `:drop_content`.

Nous ships no default redactor. Use `Nous.Eval.Online.Redactor.check/2` in
your tests to check yours, including that it is deterministic.

## Rules and scorers

Rules say what to score. Each has a `name`, a list of `scorers` (the same
scorers as offline eval), an optional `sample_rate` (at most the capture rate;
the rule scores the subset of captured traces its rate admits) and an optional
`when:` predicate on the redacted `Nous.Eval.Sample`.

Scorers see **only the redacted sample**: an LLM judge would otherwise send
raw production text to a third-party provider. The sample's `input` is the
root run's last user message and its `output` the root run's last answer,
both as redacted. Every scorer runs in its own task with `score_timeout`; a
crash or timeout is recorded as a `Nous.Eval.ScorerError`, never as a score,
and never affects the other scorers. Scores are named `"<rule>/<score>"`.

Scorers declare whether they read content with `content/0` (`:required` by
default). The trace-only built-ins (`tool_count`, `guard_verdict`,
`max_cost`, `max_latency`, `max_tokens`, `output_retries`) declare `:none`
and work under `:drop_content`.

## Budget

A rule whose scorer calls a model (`kind/0` is `:model_graded`, e.g. the
judge) requires `budget: [max_cost: usd, per: :minute | :hour | :day]`. The
scorer's model (its `:judge` or `:model` option) must have a known price, or
the instance does not start.

Before each model-graded call, its worst case is **reserved**: two requests
per judge sample (the answer and its structured-output retry) at
`reserve_tokens` (default 16 000 input and 2 000 output tokens). A call that
does not fit what is left of the window is not made; the sample records
`{"<rule>/<scorer>", "budget_exhausted"}` in `skipped`. After the call the
reservation is replaced by its actual cost (the whole reservation when the
cost is unknown, e.g. after an error). Parallel judges therefore cannot
overshoot the budget together.

The reservation is a fixed `reserve_tokens`, not derived from the judge's
evidence caps, so size `reserve_tokens: [input: ...]` to cover the judge's
largest request: about (`max_transcript_bytes` × message-list spans +
`max_span_bytes` × other spans) ÷ ~3 bytes per token. With the judge
defaults (`max_transcript_bytes: 40_000`), a transcript judge's ~10k input
tokens fit the default 16 000. A judge with more or larger spans needs a
larger reservation, or its real cost can exceed what was reserved.

The budget is per node: divide the cluster's budget by the node count.

## Backpressure and coverage

| Stage | Bound | When full |
|---|---|---|
| capture | `max_in_flight` | run not captured (`dropped_admission`) |
| trace size | `max_events`, `max_bytes` | trace truncated (`truncated?`) |
| finalize queue | `max_queue` | trace discarded (`dropped_queue`) |
| background jobs | `max_concurrency` (own `Task.Supervisor`) | wait in the queue |
| model spend | `budget` | scorer skipped (`skipped_budget`) |
| redactor / scorers | `redact_timeout` / `score_timeout` | content dropped / `:timeout` error |
| store | `store_retries` | batch dropped (`dropped_store`) |

Overload sheds new work and counts it, so the stored samples never claim more
coverage than they have. Every `window_ms` the instance emits
`[:nous, :eval, :online, :window]` with `seen_roots`, `sampled`, `captured`,
the drops, `scored`, `stored` and more; `captured / seen_roots` is the
effective capture rate. See `Nous.Telemetry` for all online events. None of
them carries content.

Worst-case memory is about `max_in_flight * max_bytes` plus the traces being
processed (`max_concurrency`).

## Storage and retention

Samples are stored in the `Nous.Eval.Store` you configure, as runs of task
`"online:<instance>"`: one run per batch (`batch_size` samples, or once per
window). Each sample's case id is its trace id; the run's
`metadata["online"]["samples"]` has, per trace, `captured_at`, `redaction`,
`explanations`, the applied `rules`, `abandoned` and a `group` hash (of the
session or trace).

The coordinator is the **only writer** of the store on its node. On a cluster,
give each node its own File root or database file.

`retention:` is required: `[max_age: {14, :day}]` deletes online runs older
than that (`Nous.Eval.Store` `delete_runs_before/3`, implemented by the File,
SQLite and DuckDB stores), at start and every `prune_interval`; `:infinity`
keeps everything, explicitly. Retention deletes only the instance's online
runs: offline runs and promoted datasets are never touched, and scoring never
extends a sample's life.

## Reading samples

```elixir
{:ok, state} = Nous.Eval.Store.File.init(root: "/var/lib/my_app/nous-online")

{:ok, entries} =
  Nous.Eval.Online.list({Nous.Eval.Store.File, state},
    since: ~U[2026-11-01 00:00:00Z],
    score_below: {"quality/judge", 0.5})

for %{sample: sample, info: info} <- entries do
  IO.puts("#{sample.trace_id} #{sample.verdict} #{info["captured_at"]}")
end
```

Stored samples are ordinary `Nous.Eval.Sample`s with traces, so the trace
queries (`Nous.Eval.Trace.tool_calls/2`, `runs/1`, ...) and
`Nous.Eval.rescore/3` work on them.

## Promotion and the review queue

`Nous.Eval.promote/3` turns stored samples into dataset lines. It **redacts
again** with the redactor you pass (stored samples may predate your current
redactor), skips anything it cannot redact, and records where each line came
from.

```elixir
Nous.Eval.promote({Nous.Eval.Store.File, state}, trace_ids,
  to: "test/eval/datasets/support.jsonl",
  redact: MyApp.TraceRedactor,
  reviewer: "alice")
#=> {:ok, %{promoted: 2, skipped: [{"4bf9...", :no_content}]}}
```

- `as: :case` (default) writes `nous.case/1` lines with the root run's request
  as `input`. The production answer is **not** copied into `expected`: that
  would bake production mistakes into the gold answers.
- `as: {:guard_case, surface: "user_input"}` (or `"tool_call"`,
  `"tool_result"`, `"model_output"`) writes `nous.guard_case/1` lines with
  `"label": null` and `provenance.review: "pending"`. The guard's own verdict
  is kept as `provenance.promoted_from.observed_verdict` for prioritising
  review, never as the label: a guard cannot certify itself.
- Samples stored without content (`:drop_content`, a failed redaction) are
  skipped as `:no_content`; a trace or text already in the file as
  `:duplicate`.

The JSONL file **is** the review queue. `Nous.Eval.Online.Review.pending/1`
lists unlabelled cases (guard escalations and denials first), and
`Nous.Eval.Online.Review.label/5` records a decision: it sets `label`,
`provenance.label_source: "promoted_reviewed"`, `provenance.review:
"approved"` and `provenance.reviewed: {by, at}`. Unlabelled cases are left out
of guard calibration.

From the command line:

```bash
mix nous.eval.promote --store file:/var/lib/my_app/nous-online \
  --ids-file ids.txt --to guards/online.jsonl --as guard_case:user_input \
  --redactor MyApp.TraceRedactor --reviewer alice

mix nous.eval.promote --to guards/online.jsonl \
  --label online-4bf92f3577b34da6a3ce929d0e0e4736-user_input=block --reviewer alice
```

`--redactor` must name an existing module; the name is never turned into a
new atom.

## OpenTelemetry export

`Nous.Eval.Online.OTel` maps a stored sample to OpenTelemetry GenAI spans
(`invoke_agent`, `chat`, `execute_tool`, and `gen_ai.evaluation.result`
events for scores). It only ever sees redacted samples. Wire it as the
exporter:

```elixir
{Nous.Eval.Online, ..., exporter: Nous.Eval.Online.OTel.exporter()}
```

Content attributes (`gen_ai.input.messages`, tool arguments and results) and
score explanations are exported only with
`Nous.Eval.Online.OTel.exporter(export_content: true)`, and never exist under
`:drop_content`. Nous does not depend on OpenTelemetry: `export/2` returns
`{:error, :opentelemetry_not_loaded}` unless the `opentelemetry` API is in
your application.

## Multiple nodes

Each node runs its own instance: its own capture, budget and store writer.
Because sampling is deterministic, all nodes agree on which traces are
sampled, and a replayed request with the same trace id gets the same decision.

## Testing your setup

- `Nous.Eval.Online.drain/1` waits until every queued trace is processed and
  the batch is written; `Nous.Eval.Online.tick/1` runs the abandoned-run
  sweep and emits the coverage window now; `Nous.Eval.Online.prune/1`
  applies retention now.
- Plant a unique **canary** string in a prompt, a tool argument and result,
  a model answer and an error, then assert it appears nowhere in the store
  directory, your logs, the online telemetry or the exported spans. Nous's
  own suite does exactly this for every redaction path.

## Configuration reference

| Option | Default | Meaning |
|---|---|---|
| `sample_rate` | **required** | share of root runs captured, `0.0..1.0` |
| `redact` | **required** | `:drop_content`, a 1-arity function or a `Nous.Eval.Online.Redactor` module |
| `store` | **required** | `{store_module, init_opts}` |
| `retention` | **required** | `[max_age: {n, :second \| :minute \| :hour \| :day}]` or `:infinity` |
| `name` | `Nous.Eval.Online` | registered name, one instance per name per node |
| `instance` | `"default"` | stored with the samples (task `"online:<instance>"`) |
| `sample_by` | `:trace` | `:trace` or `:session` |
| `sampling_salt` | none | secret binary (16+ bytes) keying the `sample_by: :session` decision (only with `:session`) |
| `agents` | all | allowlist of agent names |
| `filter` | none | `fn run_start_metadata -> boolean end` |
| `rules` | `[]` | `[name:, scorers:, sample_rate:, when:]` |
| `budget` | required with model-graded scorers | `[max_cost:, per:, reserve_tokens: [input: 16_000, output: 2_000]]` |
| `max_in_flight` | 200 | traces being captured |
| `max_queue` | 1 000 | traces waiting for a job |
| `max_concurrency` | 4 | jobs at once |
| `max_events` / `max_bytes` | 2 000 / 4 000 000 | per trace |
| `redact_timeout` | 2 000 ms | per redactor call |
| `score_timeout` | 30 000 ms | per scorer |
| `max_trace_age` | 15 min | then a run that never stopped is stored as abandoned |
| `batch_size` | 100 | samples per stored run |
| `store_retries` / `store_backoff` | 3 / 1 000 ms | write attempts and spacing |
| `prune_interval` | 1 hour | retention prune period (also at start) |
| `window_ms` | 1 min | coverage window and batch flush period |
| `sweep_interval` | 10 s | abandoned-run sweep and handler check |
| `exporter` | none | `fn sample -> any end`, e.g. `Nous.Eval.Online.OTel.exporter/1` |
