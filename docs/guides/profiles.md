# Profiles and Optimization

A `Nous.Profile` is a versioned replacement for the text an agent reads:
its instructions, its tool descriptions and its tool parameter
descriptions. `Nous.Eval.Optimizer` searches for better text against an
eval task and hands you a profile plus a report, never a code change. You
review it, then load it.

## Contents

- [Profiles](#profiles)
- [Keeping profiles current](#keeping-profiles-current)
- [Storing and promoting](#storing-and-promoting)
- [Optimizing](#optimizing)
- [Acceptance](#acceptance)
- [Feedback policy and safety](#feedback-policy-and-safety)
- [Budgets](#budgets)
- [The report](#the-report)

## Profiles

A profile carries text only. Tool names, parameter types, `required`
lists, enums and defaults always come from the live agent, so a profile
can change what the model reads but never the call contract.

```elixir
profile = Nous.Profile.load!("priv/profiles/support.json")

agent = Nous.new("openai:gpt-4o", instructions: @base, tools: tools, profile: profile)

# One run with other text, or with the base text:
Nous.run(agent, prompt, profile: candidate)
Nous.run(agent, prompt, profile: nil)
```

`profile:` takes a `%Nous.Profile{}` only; `Nous.new/2` does no I/O. An
invalid or stale profile raises `Nous.Errors.ProfileError` at `Nous.new/2`
and returns it from a run before any model call.

Component keys:

| Key | Replaces |
|---|---|
| `"instructions"` | the agent's static `instructions` (or `system_prompt`) |
| `"tool:<name>"` | the description of the app tool `<name>` |
| `"tool:<name>#<pointer>"` | the `"description"` of the parameter schema node at the JSON pointer, e.g. `"tool:search#/properties/status"` |

Built-in tools (`Nous.Tools.*`), plugin, skill and guard prompts are not
addressable: they change through a reviewed release. Agents with function
instructions cannot have their instructions replaced.

Precedence: a run-level `profile:` beats the agent's; sub-agents never
inherit a profile (give a `Nous.Plugins.SubAgent` template its own
`profile:`). DecisionGuard always reads the developer's base tool
description, so a profile cannot talk the guard out of a decision.

On a continued context (`context:`, AgentServer turns) a different profile
rebuilds the system prompt and emits `[:nous, :profile, :switched]`. A
system message the caller wrote is never overwritten: that returns
`{:error, %Nous.Errors.ProfileError{reason: :system_message_diverged}}`.

The file format (`Nous.Profile.encode/1`, canonical JSON; `load/1` also
reads YAML for hand-written profiles):

```json
{"components":{"instructions":"...","tools":{"search_orders":{
  "description":"...","params":{"/properties/status":"..."}}}},
 "id":"sha256:...","manifest":{"instructions":"sha256:...",
 "tool:search_orders":"sha256:..."},"name":"support_agent","nous_profile":1}
```

`id` is the content hash; `manifest` pins the hash of every base text a
component replaces.

## Keeping profiles current

When a developer edits the base text a profile replaces, the manifest no
longer matches and the profile is `:stale`: the app refuses to boot with
it rather than silently overwriting the new text. Catch this in CI:

```bash
mix nous.profile.check --agent MyApp.Agents.support --profile priv/profiles/support.json
```

`--agent Mod.fun` names a public 0-arity function returning the
`%Nous.Agent{}` the profile is for. Exit status 1 means a profile does not
apply (stale, unknown tool, unknown parameter); 2 an operational error.

- `mix nous.profile.rebase --agent Mod.fun PROFILE` re-seals a stale
  profile against the current base text when every component still has a
  target (the old profile becomes the parent).
- `mix nous.profile.seal --agent Mod.fun PATH` computes the manifest and id
  of a hand-written profile.

## Storing and promoting

`Nous.Eval.Store` backends store profiles content-addressed, with versions
per name and append-only labels:

```bash
mix nous.profile.promote --store file:.nous/eval support_agent production sha256:9f2c...
mix nous.profile.diff --store file:.nous/eval support_agent@production support_agent#7
```

Refs are `sha256:<hex>`, `name@label` or `name#version`.
`Nous.Eval.Profiles.fetch/2` loads one and verifies its content hash, so a
tampered stored profile is refused.

## Optimizing

```elixir
{:ok, result} =
  Nous.Eval.Optimizer.run(MyApp.Evals.Support,
    reflector: "openai:gpt-4o",
    components: ["instructions", "tool:search_orders"],
    budget: [max_cost: 5.0, max_metric_calls: 2_000],
    k: 3,
    store: {Nous.Eval.Store.File, root: ".nous/eval"},
    name: "support_agent"
  )

result.verdict
#=> :accepted
IO.puts(Nous.Eval.ProfileReport.render(result.report, format: :markdown))
```

or from the shell:

```bash
mix nous.optimize --task MyApp.Evals.Support --reflector openai:gpt-4o \
  --budget-cost 5 --store file:.nous/eval --name support_agent \
  --out priv/profiles/candidate.json
```

Exit status: 0 accepted, 1 rejected, 2 operational error.

The task's dataset needs all three splits (`Nous.Eval.Dataset` assigns
them by hashed group, 60/20/20 by default):

- **train** feeds the search. Only train cases' text reaches the
  reflector.
- **val** scores candidates and picks the best. The reflector sees val
  scores, never val text.
- **test** decides once whether the best candidate is accepted.

Cases tagged `"guard"` are guard cases: a candidate must not regress them.

Two strategies:

- **GEPA** (default): each step samples a parent from the Pareto frontier
  over per-case validation scores, picks one component in round-robin
  order (`mode: :all` or `:coupled` to change several), evaluates the
  parent on a seeded train minibatch, asks the reflector for new text from
  those cases' traces and scorer feedback, keeps the child only if it is
  strictly better on the same minibatch and passes the guard filter, then
  scores it on validation. `merge: n` enables up to `n` component-wise
  merges of compatible candidates.
- **OPRO** (`strategy: :opro`): the reflector sees the best earlier
  versions with their scores and writes 8 new ones per step at temperature
  1.0, scored on a fixed train subset. It never sees traces, so it is
  cheaper but blind to why a case failed; prefer GEPA when the signal is in
  the trajectory (wrong tool, wrong arguments).

## Acceptance

The best candidate and the seed (the agent's base text) are evaluated on
the test split with `k` samples per case and compared with
`Nous.Eval.Compare` on `case_score` and `pass_rate` (paired cluster
bootstrap over cases, Holm across both metrics):

1. no metric significantly worse, and the candidate's error rate within
   `max_error_rate` (default 0);
2. at least one metric significantly better (`alpha`, default 0.05);
3. no regression on the test split's guard cases.

Only then is the verdict `:accepted` and, with `store:`, the profile
stored. A small test split cannot show a small improvement: read the MDE
in the report before concluding the search failed.

## Feedback policy and safety

The optimizer writes text that will steer a production agent, so the
reflector is treated as an attack surface:

- **`feedback: :diagnostic`** (default) shows the reflector scorer names,
  pass/fail, values, reasons, mismatched argument *paths*, missing tool
  names and judge critiques, but never a case's expected values, a rubric
  or a judge prompt; reasons that quote them are withheld. This keeps
  answers and grader wording out of the agent's text.
  **`feedback: :with_expected`** adds train cases' expected maps (GEPA's
  default); it is recorded in the profile's provenance.
- **Fenced evidence.** Case inputs, agent outputs, tool arguments and
  results, critiques and the current component text are rendered inside
  random-boundary fences the reflector is told never to obey. Scores come
  from scorer structs, never from text.
- **Closed output.** A proposal may only change the components it was
  asked for; anything else, an empty text or an unparseable answer is
  rejected and still costs budget.
- **Lint.** A proposal that repeats 8 consecutive words of a validation or
  test case, or contains a fence marker (`<<<`, `>>>`, a fence boundary),
  is rejected before it is evaluated.
- **Gates, not detection.** The guard filter, the held-out test decision,
  the diff report and human promotion are the defence; nothing is deployed
  automatically.

## Budgets

`budget:` is required: `max_tokens`, `max_cost` (USD) and
`max_metric_calls` (samples run), at least one. Every evaluation and
reflector call is charged. With `max_cost`, an unpriced agent or reflector
model is refused before any call (add prices with
`config :nous, :model_prices`). The seed's measured test cost is reserved
so the acceptance test can always run, and a budget that cannot cover the
seed's validation and test evaluations is refused.

## The report

`Nous.Eval.ProfileReport` (also `mix nous.profile.diff`) shows the
verdict and the test used, each changed component with a text diff and
token delta, the fixed and broken cases, and a **removed text** section
that lists every line the candidate deletes from the base, with lines
that look like safety rules ("never", "do not", "must not", "refuse",
"confirm") flagged. Read that section before promoting a profile.
