# DecisionGuard

`Nous.Plugins.DecisionGuard` is a security guard backed by a decision model
(`Nous.DecisionModel`: Clef / Clef-Flash, locally or hosted). For each
guarded *surface* a question pack asks the model about what is crossing it,
and probability bands turn the answers into **allow**, **escalate** or
**deny**. No text is generated, so there is no verdict line an attacker can
forge: every answer is a probability.

See [Decision Models](decision_models.md) for backends, local setup and
latency in general, and [Hooks](hooks.md#decision-hooks) for the
`:decision` hook type the tool and output surfaces are built on.

## Quick start

```elixir
agent = Nous.new("openai:gpt-4.1", plugins: [Nous.Plugins.DecisionGuard])

{:ok, result} =
  Nous.run(agent, "Summarise the attached report",
    deps: %{
      decision_guard_config: %{
        model: "workers_ai:clef-flash",
        surfaces: [:user_input, :tool_call]
      }
    }
  )
```

The configuration lives in `deps[:decision_guard_config]` (a map or keyword
list); see `Nous.Plugins.DecisionGuard` for every key. Only `:model` is
required.

## Surfaces

| Surface | Where it runs | Pack | What a deny does |
|---|---|---|---|
| `:user_input` (**default**) | plugin `before_request/3` | `Nous.Plugins.DecisionGuard.Packs.UserInput` | Blocks like `Nous.Plugins.InputGuard`'s `:block`: an assistant refusal is added and no chat request is sent |
| `:tool_call` | `:pre_tool_use` hook | `Nous.Plugins.DecisionGuard.Packs.ToolCall` | The tool never runs; the model is told the call was denied |
| `:tool_result` | `:post_tool_use` hook | `Nous.Plugins.DecisionGuard.Packs.ToolResult` | The result is replaced by `"[tool result withheld by decision hook]"` before the model, history or `on_tool_response` see it |
| `:model_output` | `:post_response` hook (blocking) | `Nous.Plugins.DecisionGuard.Packs.ModelOutput` | The run returns `{:error, %Nous.Errors.ResponseDenied{}}`; callbacks and PubSub never see the response |

**Only the user input is guarded by default.** Each check costs a model call,
and on a laptop that is about a second (see below). Turn the other surfaces on
when you can afford them:

```elixir
deps = %{
  decision_guard_config: %{
    model: "workers_ai:clef-flash",
    surfaces: [
      :user_input,
      tool_call: [matcher: ~r/^(bash|file_write|file_edit)$/],
      tool_result: [timeout: 30_000],
      model_output: []
    ]
  }
}
```

- **User input** runs the `Nous.Plugins.InputGuard.Strategies.DecisionModel`
  strategy and, with `pattern_ensemble: true` (the default),
  `Nous.Plugins.InputGuard.Strategies.Pattern` through
  `Nous.Plugins.InputGuard.Engine` under `:any`: a Pattern hit blocks even when
  the model says safe. Each new user message is checked once, including the
  initial prompt of `Nous.run/3`.
- **Tool call, tool result and model output** are `:decision` hooks
  contributed through the plugin's `hooks/2` callback at priority **900**
  (late, so they judge what earlier hooks produced) with `fail_closed: true`.

### Escalation

An escalation goes to `:on_escalate` (global or per surface):

- user input: `fn info -> :allow | :deny | {:edit, %{content: text}} end`,
  where `info` has `:surface`, `:content`, `:reason` and `:probabilities`.
  `{:edit, ...}` replaces the user message before the model sees it.
- hook surfaces: the `Nous.Hook.Decision` callback (`info.event` names the
  event); `{:edit, changes}` becomes `{:modify, changes}`.

Without a handler, a tool-call escalation asks the run's approval handler
through `Nous.Permissions.consult_handler/2` (no handler rejects), and every
other surface denies. With no `:on_escalate`, **an escalation blocks**.

### Failure is closed

A decision-model error or timeout follows `:on_error`: `:deny` (default),
`:escalate` or `:allow`. A model that is down never reads as "safe".

## Presets and measured trade-offs

The user-input pack asks one `:choice` question (`safe` / `suspicious` /
`blocked`) and bands **P(suspicious) + P(blocked)**. Clef-Flash almost never
picks `suspicious` as its top option, so the model's own argmax is not used.

Benchmark: 326 labelled prompts (deepset/prompt-injections test,
jackhhao/jailbreak-classification, the InputGuard test strings), Clef-Flash
Q8_0 in-process on an M1 Max. The bands were tuned on the same data, so the
rates are optimistic (±4 pp).

| `:preset` | allow below / deny at | Escalated | Allowed (attacks among them) | Denied (benign among them) |
|---|---|---|---|---|
| `:balanced` (default) | 0.3 / 0.7 | 9.5% | 172 (30) | 123 (5) |
| `:strict` | 0.06 / 0.53 | 32.2% | 91 (3) | 130 (6) |

`:strict` keeps ≥95% allow-NPV and deny-precision, but an escalation with no
`:on_escalate` handler blocks, so it rejects a quarter to a third of traffic.
Choose it only with a human or a second classifier behind `:on_escalate`.

For comparison, on the same data: Clef-Flash at a 0.5 cut scored accuracy
0.853 / precision 0.947 / recall 0.753; a local Qwen3-4B LLM judge scored
0.853 / 0.855 / 0.855; the default Pattern strategy alone 0.647 / 0.870 /
0.361. Adding Pattern under `:any` buys a little recall for precision.

The opt-in corpus eval (`mix test --only decision_model`, 140 records vendored
in `test/fixtures/decision_guard/user_input.jsonl` from Apache-2.0 sources
plus hand-written hard negatives) measured `:balanced` on Clef-Flash Q8_0 at
**0.878 holdout accuracy** (n = 41; 0.879 over all 140), 10% escalated, and 19
of 20 hard negatives allowed. With Pattern under `:any` the accuracy over all
items drops to 0.829, because Pattern flags benign role-play requests
("act as a code reviewer…").

The tool-call, tool-result and model-output bands are **provisional**: they
come from an 8-item probe per surface. Re-tune them on your own traffic.

### Other model families

Prompts and thresholds do not transfer between decision-model families. The
packs declare `model_family: "clef"` and refuse to hand out default bands for
anything else. The family is inferred from the model name (it contains
"clef"), or set with `:model_family`; for another family, pass `:bands` for
every question:

```elixir
deps = %{
  decision_guard_config: %{
    model: Nous.DecisionModel.parse("systemone:my-jev", base_url: "http://localhost:8000"),
    model_family: "jev",
    surfaces: [user_input: [bands: %{verdict: %{[:suspicious, :blocked] => {0.2, 0.8}}}]]
  }
}
```

Questions can be replaced or extended per surface with
`questions: {:replace, questions}` or `{:extend, questions}`; every question
then needs a band.

## Latency per surface

A check sits on the request path. Hosted figures are the providers'
published medians, not measured here; laptop figures are Clef-Flash Q8_0 on
an M1 Max (Metal, one caller, warm).

| Surface | Prompt size | Hosted | Laptop-local |
|---|---|---|---|
| User input | one `:choice` question, ~280 tokens for a short message | ~40–250 ms | ~0.56 s p50, 2.4 s p95 |
| Tool call | 5 questions, ~770 tokens before the arguments | ~40–250 ms | 1.6–7.1 s per call, median 3.1 s (8-item probe, 545–850-token prompts) |
| Tool result | 5 questions plus the result; long results are chunked | per chunk as above | ~2 ms per prompt token per chunk: ~2 s at 1k tokens, ~5 s at 2.5k |
| Model output | 4 questions, ~560 tokens before the response | ~40–250 ms | same probe range as the tool call |

- The canary doubles the number of calls.
- A local `Backend.LlamaCpp` process serialises its calls: concurrent checks
  queue (about 1–2 checks per second per loaded model).
- Set `:timeout` (per call, default 10 s) for your backend: seconds-scale
  locally.

## A guard verdict is not a trust signal

An allowed input is "not flagged", not "trusted". Classifiers miss attacks
(even `:balanced` let 30 of 166 benchmark attacks through), and the
classifier reads the attacker's text itself. Keep the real controls in
place: `:permissions`, the sandbox, approval handlers, `UrlGuard`. Never
widen what an agent may do because DecisionGuard allowed something.

## The canary is weak evidence

`canary: true` makes a second, separate call per check (and per chunk) asking
whether a random `check` number added to the state exceeds a random
threshold; the number, margin and polarity are fresh from `:crypto` every
call, and the content cannot see or forge them. A wrong answer floors the
verdict at escalate and emits `[:nous, :decision_guard, :canary_failed]`.

It is a separate call because asking it in the same request perturbed
Clef's joint answers (13 of 326 verdicts flipped, −3 pp accuracy). Its
detection power against content that steers the classifier is unmeasured: a
correct canary proves nothing, and it never lowers a verdict.

## Streaming gap

`Nous.run_stream/3` does not call `before_request/3`, so the user-input
surface does not apply to it; check input yourself before streaming. Under
`stream: true`, the model-output surface still denies the response, but its
tokens have already been streamed to `on_llm_new_delta` by then.

## Workflow nodes are not covered

`Nous.Workflow` graphs do not inherit a guard. An `:agent_step` node runs its
own agent: add `Nous.Plugins.DecisionGuard` and the config to that agent's
`deps` explicitly. `:tool_step` nodes run no hooks, and `:subworkflow` nodes
drop deps. Workflow graphs are developer-authored, not LLM-spawned.

## Sub-agents

`:decision_guard_config` is confinement, like `:workspace_root`.
`Nous.Plugins.SubAgent` always forwards it, whatever `:sub_agent_shared_deps`
says (`:all`, a key list or nothing), so no sharing choice can withhold it or
swap in a looser one, and it adds `Nous.Plugins.DecisionGuard` to every
sub-agent's plugins, for both `delegate_task` and `spawn_agents`.

The accepted limitation: a sub-agent template cannot change the inherited
config, because templates carry no deps. A template can only *add* hooks of
its own (for example a stricter `:decision` hook), and those tightenings do
not reach the sub-agent's own sub-agents, which inherit the original config
only.

## Telemetry

| Event | Measurements | Metadata |
|---|---|---|
| `[:nous, :decision_guard, :verdict]` | `duration`, `chunk_count` | `surface`, `verdict`, `result`, `probabilities`, `canary_failed`, `error` |
| `[:nous, :decision_guard, :canary_failed]` | `count` | `surface` |
| `[:nous, :decision_guard, :strategy_dropped]` | `count` | `aggregation`, `fail_closed` |

Hook surfaces also emit `[:nous, :hook, :decision]`; see
[Observability](observability.md).
