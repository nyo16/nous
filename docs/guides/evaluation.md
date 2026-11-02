# Evaluation Guide

`Nous.Eval` tells you whether a change to an agent (a prompt, a tool
description, a model, a guard) made it better or worse, and how sure you can
be. You describe the agent and a dataset of cases in a **task module**, run
every case several times under a trace collector, score each run with
**scorers**, and compare the result with a stored **baseline** using
statistics that account for model randomness. The same run gates pull
requests in CI.

## Contents

- [The model](#the-model)
- [Quick start](#quick-start)
- [Task modules](#task-modules)
- [Datasets](#datasets)
- [Scorers](#scorers)
- [Trajectories and tool calls](#trajectories-and-tool-calls)
- [LLM judge](#llm-judge)
- [Traces and failure inspection](#traces-and-failure-inspection)
- [Running](#running)
- [Budgets](#budgets)
- [Statistics](#statistics)
- [Store and baselines](#store-and-baselines)
- [Comparing runs](#comparing-runs)
- [CI gate](#ci-gate)
- [Optimizing the agent's text](#optimizing-the-agents-text)
- [Beyond single-turn offline cases](#beyond-single-turn-offline-cases)
- [Re-scoring](#re-scoring)
- [Examples](#examples)

## The model

| Concept | What it is | Module |
|---|---|---|
| Task | A module that says which agent to build, which cases to run and which scorers judge them | `use Nous.Eval` |
| Dataset | A validated, content-hashed list of cases (Elixir, YAML or JSONL) | `Nous.Eval.Dataset`, `Nous.Eval.Case` |
| Sample | One execution of one case: output, trace, scores, verdict, usage, cost | `Nous.Eval.Sample` |
| Scorer | Turns a sample into scores, a skip, or an error | `Nous.Eval.Scorer`, `Nous.Eval.Scorers.*` |
| Trace | Every telemetry event the sample emitted (model calls, tool calls, guard verdicts, sub-agents) | `Nous.Eval.Trace` |
| Run | All samples, the summary statistics and a fingerprint of the configuration | `Nous.Eval.Run`, `Nous.Eval.Summary`, `Nous.Eval.Fingerprint` |
| Store | Where runs and baseline labels live | `Nous.Eval.Store` |
| Comparison | A paired, case-matched gate between a baseline and a candidate run | `Nous.Eval.Compare` |

Every case runs `k` times (default 3). LLM agents are not deterministic, so a
single pass/fail per case says little; repeated samples and per-case
statistics separate a real regression from noise.

A scorer that cannot produce a verdict (it raised, timed out, was
misconfigured, or the trace it needed was truncated) is a
`Nous.Eval.ScorerError`. A sample with any scorer error has verdict `:error`,
which is never counted as a pass or a fail, and a CI run with errors exits 2.

## Quick start

`Nous.Eval.Examples.Basic` is a complete task that runs offline against a
scripted model, so you can try the whole workflow without an API key:

```bash
mix nous.eval --task Nous.Eval.Examples.Basic --k 3 --seed 1 --set-baseline main
```

```text
Stored run 20261101t221045z-8a0df0a5 in file:.nous/eval
Eval run 20261101t221045z-8a0df0a5 (Nous.Eval.Examples.Basic): completed
Cases 5, samples 15, k 3
Verdicts: 15 pass, 0 fail, 0 error, 0 not run
Error rate: 0.0%
Pass rate: 100.0%  95% Wilson [79.6%, 100.0%]  95% clustered [100.0%, 100.0%]
pass@3: 100.0%  pass^3: 100.0% (5 cases)
MDE (one-sided alpha 0.05, 80% power): 21.4 pp
Scorers:
  contains: pass 100.0% [79.6%, 100.0%], mean 1.000, skipped 0, errors none
  no_tool_errors: pass 100.0% [79.6%, 100.0%], mean 1.000, skipped 0, errors none
  trajectory: pass 100.0% [79.6%, 100.0%], mean 1.000, skipped 0, errors none
Errors by kind: none
Agent outcomes: 15 ok, 0 error, 0 killed, 0 budget_exhausted
Resources: cost $0.0003 total, $0.0000/sample; latency mean 15 ms, p95 24 ms; tokens 1026 total, 68/sample

Exit status 0 (pass)
Baseline main -> 20261101t221045z-8a0df0a5 (file:.nous/eval)
```

The scripted model decides from the tool **descriptions** it is offered, like
a real model: it only calls `get_weather` when a tool's description mentions
the weather. Change the description in `weather_tool/0` (for example to
"Look up a city.") and gate against the baseline:

```bash
mix nous.eval --task Nous.Eval.Examples.Basic --k 3 --seed 1 --baseline main
```

The comparison lists the weather cases as `broken`, reports
`Fingerprint changes: tools`, and the task exits 1 (regression). Set
`NOUS_EVAL_EXAMPLE_MODEL=openai:gpt-4o-mini` (any `provider:model`) to run the
same task against a real model.

## Task modules

A task is a module that `use`s `Nous.Eval`:

```elixir
defmodule MyApp.Evals.Refunds do
  use Nous.Eval

  alias Nous.Eval.Scorers.{NoToolErrors, MaxCost}

  @impl true
  def dataset, do: "evals/refunds.yaml"

  @impl true
  def scorers do
    [
      NoToolErrors,
      {MaxCost, max_usd: 0.02, required: false, weight: 0}
    ]
  end

  @impl true
  def setup(_opts), do: {:ok, %{orders: MyApp.Fixtures.orders()}}

  @impl true
  def deps(%{orders: orders}), do: %{orders: orders}

  @impl true
  def agent(%{deps: _deps, seed: _seed}) do
    Nous.new("openai:gpt-4o-mini",
      instructions: "You are Acme's support agent.",
      tools: [&MyApp.Tools.search_orders/2, &MyApp.Tools.refund_order/2]
    )
  end
end
```

| Callback | Required | Purpose |
|---|---|---|
| `agent/1` | yes | Builds the agent for one sample. The context map has `:case` (the `Nous.Eval.Case`), `:sample` (0-based index), `:seed` (the sample's seed or `nil`), `:deps` and `:state` |
| `dataset/0` | yes | A `Nous.Eval.Dataset`, a list of cases, or the path of a YAML/JSONL file |
| `scorers/0` | no | Scorers applied to every case, before the case's own (default `[]`) |
| `setup/1` | no | Runs once per eval run with the run options; `{:ok, state}` or `{:error, reason}` (aborts the run before any model call) |
| `teardown/1` | no | Releases what `setup/1` acquired; runs even when the run fails |
| `deps/1` | no | The deps every sample's agent run receives, from the setup state (default `%{}`) |

`Nous.Eval.Task.load/2` validates a task module; `Nous.Eval.run/2` and
`mix nous.eval` call it before anything else runs.

A case's `input` is either a string (run with `Nous.run(agent, input)`) or a
message list (run with `Nous.run(agent, messages: input)`).

Build the agent inside `agent/1` rather than in a module attribute: the
fingerprint is built from the first case's agent, so the prompt, tool
schemas, model settings and any `Nous.Profile` it applies are recorded on the
run. Two runs are only comparable when you know what each one tested.

## Datasets

A dataset is a list of `Nous.Eval.Case`s. Every case has a stable string `id`:
runs, baselines and comparisons match cases by it, so renaming an id makes it
a new case.

| Key | Type | Meaning |
|---|---|---|
| `id` | string, required | Stable and unique within the dataset |
| `input` | string or message list, required | The prompt, or `{role, content}` messages (`system`, `user`, `assistant`) |
| `expected` | map | Free-form expectations the scorers read (`expected["output"]` is the default reference for `equals`/`similarity`) |
| `scorers` | list | Case-specific scorers, added after the task's |
| `threshold` | number in 0..1 | Pass threshold for the soft scorers' weighted mean (default 0.5) |
| `tags` | strings | For selecting cases (`--tag`) and per-tag breakdowns |
| `split` | `train`, `val`, `test` | Assigned from `group` when absent |
| `group` | string | Cases that must share a split (paraphrases); defaults to the id |
| `metadata` | map | Carried into the run record |

### Elixir

```elixir
{:ok, dataset} =
  Nous.Eval.Dataset.new([
    %{
      id: "refund-1",
      input: "Refund order 42",
      tags: ["refund"],
      scorers: [{Nous.Eval.Scorers.Contains, values: ["refund"]}]
    },
    [id: "greet-1", input: "Hi!", expected: %{"output" => "Hello!"}]
  ])
```

Cases are maps, keyword lists or `%Nous.Eval.Case{}` structs. `dataset/0` may
return the list directly; the runner builds the dataset.

### YAML

```yaml
schema: nous.case/1
name: refunds            # optional; defaults to the file name
cases:
  - id: refund-1
    input: Refund order 42
    expected: {tool: refund_order}
    tags: [refund]
    scorers:
      - no_tool_errors
      - scorer: trajectory
        expected:
          - {name: search_orders, args: {order_id: "42"}}
          - {name: refund_order}
      - scorer: contains
        values: [refund issued]
        required: false
  - id: refund-2
    input:
      - {role: system, content: You are terse.}
      - {role: user, content: Refund order 43}
    group: refund-2
    split: test
```

### JSONL

One case object per line, the same keys; a line may carry
`"schema": "nous.case/1"`. Blank lines are skipped and errors name the line.

```json
{"schema": "nous.case/1", "id": "capital-fr", "input": "Capital of France?", "expected": {"output": "Paris"}, "scorers": [{"scorer": "equals", "case_sensitive": false}]}
{"id": "capital-jp", "input": "Capital of Japan?", "expected": {"output": "Tokyo"}, "scorers": ["equals"]}
```

```elixir
{:ok, dataset} = Nous.Eval.Dataset.load("evals/capitals.jsonl")
```

### Strict loading

Loading fails closed with `{:error, message}` on an unknown key, a duplicate
id, a non-string object key, an unknown role, split or scorer, or an unknown
scorer option. **Nothing in a file becomes an atom**: scorer names resolve
through a fixed table of built-ins plus your application's own table
(`Nous.Eval.Scorer.resolve/2`):

```elixir
# config/config.exs
config :nous, :eval_scorers, %{"house_style" => MyApp.Eval.HouseStyle}
```

The built-in names are `equals`, `similarity`, `contains`, `not_contains`,
`regex`, `output_schema`, `trajectory`, `tool_args`, `tool_count`,
`no_tool_errors`, `guard_verdict`, `max_cost`, `max_latency`, `max_tokens`,
`output_retries` and `judge`. Enum-valued options are written as strings
(`mode: in_order`). `Nous.Eval.Scorers.Function` takes an Elixir function, so
it is available in Elixir datasets only.

### Splits and content hash

A case without a `split` is assigned one from its `group`:
`sha256("nous.split/1:" <> group)` picks a bucket cut by the ratios
`train: 0.6, val: 0.2, test: 0.2` (option `:split_ratios`). The assignment
depends only on the group, so adding or removing cases never moves the
others, and paraphrases sharing a group never straddle splits. Run only the
held-out cases with `--split test`.

The dataset hash is the canonical JSON hash of the cases sorted by id
(`Nous.Eval.CanonicalJSON`). It ignores key order, file format and case
order: the same cases in YAML and JSONL hash the same. A comparison refuses
runs of different datasets unless you allow it explicitly.

## Scorers

A scorer implements `Nous.Eval.Scorer`. `score/2` receives a
`Nous.Eval.ScoreInput` (`case`, `sample`, `seed`, `output`, `run_outcome`,
`trace`, `usage`, `duration_ms`) and returns:

- `{:ok, score}` or `{:ok, [score]}`: a `Nous.Eval.Score` with a string
  `name`, a `value` (`:pass`, `:fail`, a float in `0.0..1.0` or
  `{:label, string}`) and `passed?`
- `{:skip, reason}`: the scorer does not apply to this sample
- `{:error, %Nous.Eval.ScorerError{}}`: the instrument failed

`init/1` runs once per eval run and validates options; bad options abort the
run before any agent runs. Scorers run isolated under a supervisor with a
time limit (`:scorer_timeout`): a raise or a timeout becomes a scorer error of
kind `:raised` or `:timeout` and never discards another scorer's result.

### Built-in scorers

| Scorer | Passes when |
|---|---|
| `Nous.Eval.Scorers.Equals` | the output equals `:expected` (or `expected["output"]`); structured values deep-equal |
| `Nous.Eval.Scorers.Similarity` | the Levenshtein ratio to the expected text is at least `:threshold` (default 0.8) |
| `Nous.Eval.Scorers.Contains` | the output contains `:values` (`mode: :all \| :any`); an empty list is a config error |
| `Nous.Eval.Scorers.NotContains` | the output contains none of `:values` |
| `Nous.Eval.Scorers.Regex` | the output matches `:patterns`; an invalid regex is a config error |
| `Nous.Eval.Scorers.OutputSchema` | the output validates against `:schema`, optionally with expected field `:values` |
| `Nous.Eval.Scorers.Trajectory` | the tool calls match an expected trajectory (see below) |
| `Nous.Eval.Scorers.ToolArgs` | one tool's calls have the expected arguments |
| `Nous.Eval.Scorers.ToolCount` | the number of tool calls is within `:min`/`:max`/`:exact` |
| `Nous.Eval.Scorers.NoToolErrors` | no tool call failed (invalid arguments, not found, timeout, crash) |
| `Nous.Eval.Scorers.GuardVerdict` | a guard decided as expected (DecisionGuard, InputGuard, LoopGuard, decision hooks) |
| `Nous.Eval.Scorers.OutputRetries` | structured-output retries are at most `:max` |
| `Nous.Eval.Scorers.MaxCost` | the sample cost at most `:max_usd` |
| `Nous.Eval.Scorers.MaxLatency` | the sample took at most `:max_ms` |
| `Nous.Eval.Scorers.MaxTokens` | the sample used at most `:max` tokens (`:field`: total, input or output) |
| `Nous.Eval.Scorers.Judge` | an LLM judge's verdict reaches `:threshold` (see [LLM judge](#llm-judge)) |
| `Nous.Eval.Scorers.Function` | your function returns `true` or a number at least `:threshold` |

Output scorers fail a sample whose agent run failed (reason `"run_failed"`);
trace scorers score the partial trace. A failed run is not a scorer error.

### Composition

Each scorer is declared as a module, `{module, opts}` or a
`Nous.Eval.Scorer.Spec`. Three options shape how its scores combine into the
sample's verdict:

- `required:` (default `true`): the scorer is a **gate**; a failed score
  fails the sample
- `weight:` (default `1`): the weight of a non-required scorer in the soft
  group's mean; `weight: 0` tracks the metric without affecting the verdict
- `skippable:` (default `false`): a required scorer may skip; otherwise a
  skip is an `:invalid_config` error, because "the gate did not look" must
  not read as "the gate passed"

The verdict is, in order:

1. `:error` if any scorer returned an error
2. `:fail` if any required score has `passed?: false`
3. `:fail` if there are soft scores (`required: false`, `weight > 0`) and
   their weighted mean is below the case threshold (default `0.5`)
4. `:pass` otherwise

The sample's `case_score` is the gated objective: `nil` on `:error`, `0.0`
when a required score failed, else the soft weighted mean (`1.0` with no soft
scores). It ignores the threshold.

Resource scorers (`MaxCost`, `MaxLatency`, `MaxTokens`) are best declared
track-only, `required: false, weight: 0`: their per-scorer pass rates show in
every report without turning a slow day at the provider into a failed case.
An unpriced model is a `MaxCost` scorer error, never a pass.

### A custom scorer

```elixir
defmodule MyApp.Eval.CitesOrder do
  @behaviour Nous.Eval.Scorer

  alias Nous.Eval.Score

  @impl true
  def id, do: "cites_order"

  @impl true
  def init(opts), do: {:ok, Keyword.get(opts, :prefix, "order #")}

  # Lets dataset files configure it: `{scorer: cites_order, prefix: "PO-"}`
  @impl true
  def option_keys, do: [:prefix]

  @impl true
  def score(%{output: output}, prefix) when is_binary(output) do
    passed? = String.contains?(output, prefix)
    {:ok, %Score{name: id(), value: if(passed?, do: :pass, else: :fail), passed?: passed?}}
  end

  def score(_input, _prefix), do: {:skip, "no text output"}
end
```

Register it in `config :nous, :eval_scorers` to reference it from files. For
one-off checks in Elixir, `Nous.Eval.Scorers.Function` wraps a function:

```elixir
{Nous.Eval.Scorers.Function,
 name: "short_answer", fun: fn input -> String.length(input.output || "") < 400 end}
```

## Trajectories and tool calls

`Nous.Eval.Scorers.Trajectory` compares the tool calls in the sample's trace
with an expected list:

```elixir
{Nous.Eval.Scorers.Trajectory,
 expected: [
   %{name: "search_orders", args: %{"order_id" => "42"}},
   # any arguments
   %{name: "refund_order"},
   # one or two calls
   %{name: "notify", count: {1, 2}}
 ],
 mode: :superset,
 forbid: ["delete_all"]}
```

| Mode | Passes when |
|---|---|
| `:superset` (default) | every expected call was made; extra calls are allowed |
| `:subset` | every call made was expected; expected calls may be missing |
| `:unordered` | the calls are exactly the expected multiset, in any order |
| `:in_order` | the expected calls appear in order; others may be interleaved |
| `:strict` | the calls are exactly the expected ones, in order |

Matching is a multiset: two `search` entries need two `search` calls.
Order-free modes use maximum bipartite matching, so a wildcard entry listed
before a specific one never steals the only call the specific entry could
match. Calls the model requested in one response may run in parallel, so they
are compared order-free within their batch (`parallel: :as_emitted` to
compare them in emitted order).

Defaults worth knowing:

- `args: :subset`: expected arguments must be present (recursively); extra
  arguments are fine. Use `:exact`, `:ignore`, per-tool `:args_overrides`,
  `:ignore_args` globs (`"*_cursor"`) and `:arg_defaults` to tune it.
- `include: [:executed]`: only calls that actually ran count. A call denied
  by a hook, rejected at approval or with invalid arguments does not satisfy
  an expectation. `:forbid` counts every attempt, denied or not.
- `scope: :root`: only the root agent's calls; `:tree` includes sub-agents,
  `{:sub_agent, template}` selects one sub-agent template.
- `score: :binary` (`:pass`/`:fail`); `score: :f1` reports precision/recall
  as a float for partial credit while `passed?` still follows the mode.

`details` names what went wrong: `missing` entries, `unexpected` calls,
`out_of_order` entries and `arg_mismatches` with the differing argument
paths.

`Nous.Eval.Scorers.ToolArgs` checks one tool's arguments
(`occurrence: :all | :any | :first | :last | n`), `ToolCount` bounds call
counts (it counts failed attempts by default, since they cost time and
tokens) and `NoToolErrors` fails on tool failures. When a trace was truncated,
any result that depends on calls being absent is a `:missing_trace` error,
not a pass.

## LLM judge

`Nous.Eval.Scorers.Judge` grades a sample with a tool-less judge agent that
answers with a verdict from a declared, closed label set:

```elixir
{Nous.Eval.Scorers.Judge,
 judge: "openai:gpt-4o-2024-08-06",
 rubric: "The answer states the refund amount and the order number.",
 scale: {:likert, 1, 5, labels: %{1 => "wrong", 5 => "complete and correct"}},
 threshold: 0.75,
 include: [:input, :output, :tool_calls]}
```

- **`judge:` is required.** There is no fallback to the agent's model or a
  global default. Pin a dated model id; an alias such as `-latest` moves under
  you and logs a warning.
- **Scales are declared:** `:binary` (default; `"pass"`/`"fail"`),
  `:ternary`, `{:likert, min, max}` (normalized to `0.0..1.0`) or
  `{:choices, %{"A" => 1.0, "B" => 0.4}}`. `threshold:` is required for every
  scale but `:binary`. A verdict outside the label set is a
  `:judge_out_of_range` scorer error, an unparseable answer is
  `:judge_unparseable` and a failed call is `:judge_call_failed`; none of
  them is a fail.
- **Determinism:** temperature 0 by default; `:seed` is sent when the
  provider supports one. `samples: n` with `reduce: :majority | :mean` makes
  several judge calls per sample.
- **Untrusted evidence is fenced.** Each piece (input, output, tool calls,
  transcript, reference) goes into the user message inside its own fence with
  a random boundary minted for that request; fence-like markers in the
  evidence are broken up first.
- **Separate trace, counted cost.** Each judge run executes under its own
  trace id with role `:judge`, so its telemetry never lands in the graded
  sample's trace. The score's metadata carries `judge_trace_id`, the judge
  `usage` and `model`, and run budgets count it.

### Calibration

A judge is an instrument: before you gate on it, measure it against human
labels. Write a `nous.judge_case/1` JSONL file of stored agent outputs with
human verdicts, split into `tune` (iterate on the rubric) and `holdout`
(never look at it while tuning):

```json
{"id": "refund-17", "input": "Refund order 42", "output": "Refunded $20 for order 42.", "human_label": "pass", "annotator": "ana", "split": "holdout", "group": "refund-17"}
```

```bash
mix nous.eval.judge.calibrate --judge openai:gpt-4o-2024-08-06 \
  --dataset priv/eval/judge_cases.jsonl --rubric-file priv/eval/rubric.md
```

The task replays the stored outputs through the judge (no agent runs) and
reports, on the holdout split only, agreement, Cohen's κ (quadratic-weighted
for Likert scales), the confusion matrix, the false-pass rate with a Wilson
interval and the judge error rate. The result is stored in the eval store
under the judge's fingerprint id (`Nous.Eval.Scorers.Judge.fingerprint_id/1`).
From Elixir: `Nous.Eval.JudgeCalibration.load/1` and
`Nous.Eval.JudgeCalibration.calibrate/3`.

Then require it:

```elixir
{Nous.Eval.Scorers.Judge,
 judge: "openai:gpt-4o-2024-08-06",
 rubric: File.read!("priv/eval/rubric.md"),
 require_calibration: [min_kappa: 0.6, max_false_pass: 0.1]}
```

With `require_calibration`, the run looks the calibration up in its store
and refuses to start (before any model call) when none matches this exact
judge configuration or it misses either threshold. The fingerprint covers the
model, temperature, seed, prompt (template, rubric, labels), scale,
threshold, include, samples, reduce, span limit **and the Nous version**: a
judge prompt or Nous upgrade is a new instrument and must be re-calibrated.
The calibrate options must match the eval's judge options exactly. Without
`require_calibration`, an uncalibrated gate judge logs a warning once per run.

## Traces and failure inspection

Every sample carries a `Nous.Eval.Trace`: everything Nous emitted under the
sample's `trace_id`, in emission order: the root run, its model and tool
calls, guard verdicts and every sub-agent run. The collector keeps partial
traces of failed and killed runs, so a failing sample can be inspected up to
the point it stopped. Traces are capped at 10 000 events and 8 MB per sample
(`:max_trace_events`, `:max_trace_bytes`); past a cap the trace is
`truncated?` and scorers that need to prove an absence return
`:missing_trace` instead of passing.

Read a trace through the query helpers rather than walking events:

```elixir
{:ok, run} = Nous.Eval.run(MyApp.Evals.Refunds, k: 3, seed: 1)

failed = Enum.filter(run.samples, &(&1.verdict in [:fail, :error]))

for sample <- failed do
  IO.puts("#{sample.case_id} ##{sample.index}: #{sample.verdict} (#{sample.outcome})")

  # What each scorer said, and why
  for score <- sample.scores, not score.passed?, do: IO.inspect({score.name, score.reason, score.details})
  for error <- sample.scorer_errors, do: IO.inspect(error)

  # Every tool call, including denied and failed attempts
  for call <- Nous.Eval.Trace.tool_calls(sample.trace, include: :all, scope: :tree) do
    IO.inspect({call.name, call.arguments, call.outcome, call.approval})
  end

  # Guard decisions and the reconstructed conversation
  IO.inspect(Nous.Eval.Trace.guard_verdicts(sample.trace))
  IO.inspect(Nous.Eval.Trace.transcript(sample.trace))
end
```

| Helper | Returns |
|---|---|
| `Nous.Eval.Trace.tool_calls/2` | `Nous.Eval.Trace.ToolCall`s: name, arguments (post-edit when edited at approval), outcome, approval, result, iteration, batch |
| `Nous.Eval.Trace.model_calls/1` | `Nous.Eval.Trace.ModelCall`s: requested and answering model, messages, response, usage, finish reason |
| `Nous.Eval.Trace.guard_verdicts/2` | `Nous.Eval.Trace.GuardVerdict`s from DecisionGuard, InputGuard, LoopGuard and decision hooks |
| `Nous.Eval.Trace.runs/1` | the run tree as `Nous.Eval.Trace.AgentRun`s |
| `Nous.Eval.Trace.usage/1` | summed `Nous.Usage` of every completed model request |
| `Nous.Eval.Trace.transcript/2` | the message history of a run, rebuilt from its events |
| `Nous.Eval.Trace.output_retries/2` | structured-output retries |

Trace events use the metadata documented in `Nous.Telemetry`, including the
correlation ids `trace_id`, `agent_run_id`, `parent_agent_run_id` and
`tool_call_id` (see the [observability guide](observability.md#correlation-ids)).
Content keys (`messages`, `response`, `arguments`, `result`) hold user data;
treat stored runs like logs that contain prompts.

## Running

From Elixir:

```elixir
{:ok, run} =
  Nous.Eval.run(MyApp.Evals.Refunds,
    k: 3,
    seed: 1,
    splits: ["test"],
    tags: ["refund"],
    budget: [max_cost: 2.0],
    store: {Nous.Eval.Store.File, root: ".nous/eval"}
  )

IO.puts(Nous.Eval.Reporter.render(run))
```

From the command line:

```bash
mix nous.eval --task MyApp.Evals.Refunds --k 3 --seed 1 --split test --tag refund
```

| Option (`run/2` / `mix nous.eval`) | Default | Meaning |
|---|---|---|
| `:k` / `--k` | 3 | samples per case |
| `:seed` / `--seed` | `nil` | base seed (see below) |
| `:parallelism` / `--parallelism` | schedulers online | samples in flight |
| `:timeout` / `--timeout` | 120 000 ms | per-sample limit; a sample past it is `:killed`, its trace kept |
| `:splits` / `--split` | all | run only these splits |
| `:tags` / `--tag` | all | run only cases with one of these tags |
| `:budget` / `--budget-*` | none | see [Budgets](#budgets) |
| `:store` / `--store` | none / `file:.nous/eval` | where the run is stored (`mix nous.eval` always stores) |
| `:scorer_timeout` | scorer default | per-scorer limit |
| `:max_trace_events`, `:max_trace_bytes` | 10 000 / 8 MB | trace caps |
| `:metadata` | `%{}` | stored on the run (git sha, CI job) |

**Seeds.** Each sample's seed is a deterministic function of the base seed,
the case id and the sample index. It is set as the agent's
`model_settings[:seed]` and passed to `agent/1` as `:seed`. Only providers with
a seed parameter send it on the wire; the fingerprint records it as
`"seed_forwarded"`, so you know whether a rerun could reproduce a sample.

`Nous.Eval.run/2` returns `{:error, reason}` before any model call when the
task is invalid, the filters leave no case, a scorer's options are invalid, a
price is missing for a cost budget, or the store cannot be opened. Each
sample's `outcome` is `:ok`, `:error` (the agent run failed), `:killed` (it
timed out) or `:budget_exhausted`; the run's `status` is `:completed`,
`:budget_exhausted` or `:aborted` (the trace collector lost its telemetry
handler, so traces could no longer be trusted).

## Budgets

```elixir
Nous.Eval.run(MyApp.Evals.Refunds, budget: [max_tokens: 500_000, max_cost: 2.0, max_samples: 300])
```

```bash
mix nous.eval --task MyApp.Evals.Refunds --budget-cost 2 --budget-tokens 500000
```

- Spend is counted from **every answered model request** of every sample's
  trace, including turns that failed afterwards and samples later killed,
  plus the usage model-graded scorers (the judge) report. Requests are priced
  with `Nous.Usage.cost/2` at the model that actually answered, so a fallback
  or a routed model counts at its own price.
- With `max_cost`, every model the run is known to call (the agent's model and
  fallbacks, judge models) must have a price, or the run is refused with
  `{:error, {:unknown_price, "provider:model"}}` **before any model call**.
  Add prices with `config :nous, :model_prices` (see `Nous.Usage.Pricing`).
- Once a limit is reached no new sample starts, running agents are cancelled
  at their next step, and model-graded scorers are no longer called. Samples
  that never ran or were cancelled are `:budget_exhausted`, and so is a sample
  whose final answer crossed the limit. The run's status is
  `:budget_exhausted` and `mix nous.eval` exits 2: a gate never passes on
  partial results.

## Statistics

The **case** is the unit of analysis. The k samples of a case are not
independent, so `Nous.Eval.Summary` reduces them per case or treats each case
as a cluster. Only `:pass` and `:fail` samples are scored: `:error` samples
are left out of every pass rate and counted in `error_rate`.

| Summary key | Meaning |
|---|---|
| `"pass_rate"` | pooled pass rate with a Wilson interval (exact for k = 1) and a **clustered** interval (cluster-robust SE, one cluster per case): read the clustered one when k > 1 |
| `"pass_at_k"` | unbiased pass@k: the chance at least one of k samples passes |
| `"pass_hat_k"` | pass^k: the chance all k samples pass, a reliability measure |
| `"case_score"` | mean gated objective with an interval |
| `"mde"` | the minimum detectable effect at this run size |
| `"scorers"` | per score name: pass rate, mean with a bootstrap interval, labels, skips, errors |
| `"resources"` | cost, latency (mean, p50, p95), tokens, iterations |
| `"cases"` | per case: passes, pass rate, pass@k, status (`pass`, `fail`, `mixed`, `error`, `not_run`) |

The underlying functions live in `Nous.Eval.Stats` (Wilson, Clopper–Pearson,
Jeffreys and Beta-posterior intervals, clustered and paired standard errors,
pass@k, McNemar, Fisher, Holm, Benjamini–Hochberg, κ) with power analysis in
`Nous.Eval.Stats.Power`, all in pure Elixir and tested against
SciPy/statsmodels golden values.

### Read the MDE

"No significant change" means no change larger than about the MDE was
detected; **it is not evidence of no change.** The MDE is the smallest
pass-rate drop a comparison of runs this size could detect with 80% power at
one-sided α = 0.05. Small datasets are blunt instruments: a 30-case dataset
cannot see drops much smaller than 10–25 percentage points, and about
100 cases × k = 3 gets you to roughly 13 points. Plan the dataset size for the
regressions you care about:

```elixir
# Variance of the per-case difference at the planned k (see variance_components/2):
# Miller's illustrative ω² = 1/9, σ² = 1/6, k = 3 gives 2/9.
{:ok, mde} = Nous.Eval.Stats.Power.mde(100, 2 / 9)
# mde ≈ 0.132 (two-sided α = 0.05 by default)

# Cases needed to detect a 10-point drop at that variance
{:ok, n} = Nous.Eval.Stats.Power.sample_size(0.10, 2 / 9)
```

## Store and baselines

A run is persisted by passing `:store` to `run/2`; `mix nous.eval*` tasks
always store, by default in `file:.nous/eval`.

| Store | Spec | Notes |
|---|---|---|
| `Nous.Eval.Store.File` | `file:DIR` | default; a directory of JSON files, no dependencies |
| `Nous.Eval.Store.SQLite` | `sqlite:PATH` | needs `{:exqlite, "~> 0.43"}` |
| `Nous.Eval.Store.DuckDB` | `duckdb:PATH` | needs `{:duckdbex, "~> 0.7"}` |

Records are versioned (`Nous.Eval.Codec`): a newer Nous reads every older run
format and an older Nous refuses newer records instead of misreading them.
Runs are immutable.

A **baseline** is a label (`main`, `release-0.20`) pointing at a run.
Labels are append-only: setting one adds a history entry, so a rollback is
just another entry and who-pointed-what-when is never lost. A label that was
never set is `{:error, :not_found}`; a store never falls back to the latest
run, because a gate that compares against whatever ran last passes every
regression.

```bash
mix nous.eval.baseline set 20261101t153012z-1a2b3c4d main
mix nous.eval.baseline show main
mix nous.eval.baseline history main
```

```elixir
{:ok, store} = Nous.Eval.Store.File.init(root: ".nous/eval")
{:ok, %Nous.Eval.Store.Baseline{run_id: run_id}} = Nous.Eval.Store.File.get_baseline(store, "main")
{:ok, baseline} = Nous.Eval.Store.File.get_run(store, run_id)
```

Write your own backend with `@behaviour Nous.Eval.Store` and hold it to the
same contract with `use Nous.Eval.Store.Conformance` in a test.

## Comparing runs

```elixir
{:ok, comparison} = Nous.Eval.Compare.compare(baseline, candidate, gate: [metrics: [:pass_rate]])
comparison.verdict
#=> :pass | :regression | :error

IO.puts(Nous.Eval.Reporter.render(comparison, format: :markdown))
```

```bash
mix nous.eval.compare baseline:main 20261101t153012z-1a2b3c4d --gate pass_rate,scorer:trajectory
```

Cases are matched by id. Runs of different datasets are refused unless
`allow_dataset_change: true` (`--allow-dataset-change`), and then only common
ids are compared.

**Gate rule.** For each declared gate metric (`pass_rate` by default,
`case_score`, or `scorer:NAME`), Δ is the candidate's mean per-case value
minus the baseline's. A seeded paired cluster bootstrap (the case is the
cluster) tests H0: Δ ≥ −margin against H1: Δ < −margin with
p = (1 + #{Δ\* ≥ −margin}) / (B + 1). The p-values of all gate metrics are
Holm-adjusted together, and a metric **regresses** when its adjusted p-value
is at most α (default 0.05). The verdict is:

1. `:error` when the candidate's scorer error rate exceeds
   `max_error_rate` (default 0), no case is comparable, either run was
   aborted, or a gate metric is defined for fewer than two cases
2. `:regression` when any gate metric regresses
3. `:pass` otherwise

Each gate metric reports its own MDE; a `:pass` means no drop larger than the
margin was *detected*.

**Per-case labels** are descriptive, never a gate: `fixed` (majority pass
now, not before), `broken` (the reverse), `flaky` (mixed samples in either
run) and `unchanged`. With k = 3, even 3-of-3 vs 0-of-3 on one case has
Fisher p = 0.1, so read labels to find failures, not to decide.

Secondary statistics (exact McNemar on per-case majority pass, per-tag and
per-scorer breakdowns with Benjamini–Hochberg adjustment, cost/latency/token
deltas) and `fingerprint_changes` (which parts of the configuration differ:
`model`, `instructions`, `tools`, `guards`, `profile_id`, `scorers`, ...) are
reported but do not gate.

## CI gate

The recipe: refresh a `main` baseline on every merge to main, and gate every
pull request against it.

```bash
# main branch
mix nous.eval --task MyApp.Evals.Refunds --seed 1 --set-baseline main

# pull requests
mix nous.eval --task MyApp.Evals.Refunds --seed 1 --baseline main \
  --budget-cost 2 --format markdown --output eval.md
```

| Exit status | Meaning |
|---|---|
| 0 | pass: the run completed, its scorer error rate is within `--max-error-rate`, and no gate metric regressed |
| 1 | regression: a gate metric dropped by more than `--margin` with significance |
| 2 | operational error: bad arguments, unknown task, no cases, store failure, budget refused or exhausted, aborted run, too many scorer errors, or a comparison that cannot decide |

`--set-baseline` only moves the label when the exit status is 0. The baseline
must be reachable from CI: commit a `file:` store directory, restore it from a
cache or artifact, or point `--store` at a shared SQLite/DuckDB file.

```yaml
# .github/workflows/eval.yml
name: eval
on:
  push:
    branches: [main]
  pull_request:

jobs:
  eval:
    runs-on: ubuntu-latest
    env:
      MIX_ENV: test
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "27"
          elixir-version: "1.18"
      - run: mix deps.get
      - name: Restore eval store
        uses: actions/cache/restore@v4
        with:
          path: .nous/eval
          key: nous-eval-${{ github.run_id }}
          restore-keys: nous-eval-
      - name: Refresh baseline
        if: github.ref == 'refs/heads/main'
        run: mix nous.eval --task MyApp.Evals.Refunds --seed 1 --budget-cost 5 --set-baseline main
      - name: Gate
        if: github.event_name == 'pull_request'
        run: |
          mix nous.eval --task MyApp.Evals.Refunds --seed 1 --baseline main \
            --budget-cost 2 --format markdown --output eval.md
      - name: Save eval store
        if: github.ref == 'refs/heads/main'
        uses: actions/cache/save@v4
        with:
          path: .nous/eval
          key: nous-eval-${{ github.run_id }}
      - uses: actions/upload-artifact@v4
        if: always() && github.event_name == 'pull_request'
        with:
          name: eval-report
          path: eval.md
```

Before trusting the gate, look at the MDE in the report: if it is larger than
the regressions you care about, add cases (or samples) before tightening
`--margin`.

## Optimizing the agent's text

Once a task measures what you care about, `Nous.Eval.Optimizer` (or
`mix nous.optimize`) can search for better instructions and tool
descriptions against it. It uses the train split to propose text, val to
pick a candidate and test once to accept or reject it, and returns a
reviewed `Nous.Profile` with a diff report instead of editing code. See the
[Profiles and Optimization guide](profiles.md).

## Beyond single-turn offline cases

- **Multi-turn conversations**: `Nous.Eval.Simulator` plays the user from
  a persona and a goal (`nous.sim_case/1` cases), scores end state, what
  the agent said and the tools it called, and runs adversarial users with
  breach@k. See the [Simulated Users guide](eval_simulation.md).
- **Production traffic**: `{Nous.Eval.Online, opts}` samples live runs,
  redacts them before anything is scored or stored, and keeps them under a
  retention policy; `mix nous.eval.promote` turns reviewed samples into
  dataset cases. See the [Online Evaluation guide](online_eval.md).
- **Guards**: `Nous.Eval.Guard` calibrates DecisionGuard and InputGuard on
  labelled `nous.guard_case/1` data and gates config changes with a paired
  non-inferiority test. See the calibration section of the
  [DecisionGuard guide](decision_guard.md).

## Re-scoring

After you change a scorer, an expected value or a threshold, re-score stored
traces instead of paying for new agent runs:

```bash
mix nous.eval.rescore baseline:main
mix nous.eval.rescore 20261101t153012z-1a2b3c4d --task MyApp.Evals.Refunds
```

```elixir
{:ok, rescored} = Nous.Eval.rescore(baseline, MyApp.Evals.Refunds, store: {Nous.Eval.Store.File, root: ".nous/eval"})
```

Outputs, traces, usage and cost are reused; scores and verdicts are
recomputed against the task's current scorers and dataset entries (every case
of the run must still exist). The new run has a new id,
`metadata.rescored_from` pointing at the source and a fingerprint with the
current `"scorers"` and `"dataset"`. Model-graded scorers are called again,
bounded by `--budget-cost`/`--budget-tokens`. When the scorers changed, re-score
the baseline and re-point the label so the next gate compares like with like:

```bash
mix nous.eval.rescore baseline:main
mix nous.eval.baseline set RESCORED_RUN_ID main
```

## Examples

- `Nous.Eval.Examples.Basic`: a complete offline task (scripted model, tool
  calls, trajectory and contains scorers), runnable with `mix nous.eval`

Runnable scripts, offline with a scripted model (`mix run examples/eval/<file>.exs`):

| Script | Shows |
|---|---|
| [01_basic_evaluation.exs](../../examples/eval/01_basic_evaluation.exs) | a task module, an Elixir dataset, built-in scorers, `Nous.Eval.run/2`, the console report |
| [02_yaml_dataset.exs](../../examples/eval/02_yaml_dataset.exs) | YAML and JSONL datasets with scorers named in the file, equal content hashes, a markdown report |
| [03_custom_scorer.exs](../../examples/eval/03_custom_scorer.exs) | a `Nous.Eval.Scorer` module, `Scorers.Function`, required gates vs weighted soft scorers, a scorer error |
| [04_baseline_compare.exs](../../examples/eval/04_baseline_compare.exs) | a file store, a baseline label, `Nous.Eval.Compare` on an unchanged and a regressed candidate |
| [05_trace_inspection.exs](../../examples/eval/05_trace_inspection.exs) | reading a failing sample's trace, then `Nous.Eval.rescore/3` |

See also the [observability guide](observability.md) (the telemetry events
traces are built from) and the [migration guide](migration_guide.md#0193-to-0200)
for moving from the pre-0.20 eval API.
