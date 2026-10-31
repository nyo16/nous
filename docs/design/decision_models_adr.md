# Decision Models: Architecture Decisions

> **Status: accepted, implemented** (branch `feat/decision-models`). This
> records *why* the decision-model features are shaped the way they are. For
> *how to use* them see the [Decision Models](../guides/decision_models.md)
> and [DecisionGuard](../guides/decision_guard.md) guides.

## Context

Decision models (Clef / Clef-Flash, Jev, Decision 3.0, OpenAI
`/v1/decisions`) read a state and return a probability for each answer of a
list of typed questions. They generate no text. That suits three jobs where a
generated verdict is the weak point: hook decisions, security guards and
pre-dispatch model routing. A generated verdict can be forged by the text it
judges; a probability cannot be.

## Decisions

### 1. A separate primitive, not a chat provider

`Nous.DecisionModel` has its own struct, `Backend` behaviour and model-string
grammar (`workers_ai:`, `systemone:`, `openai_decisions:`, `llamacpp:`). It is
not a `Nous.Model` provider.

- **Why:** the contract is different in kind. Input is a state plus an
  *ordered* question list; output is probabilities keyed by declared ids. None
  of chat's messages, tools, streaming or fallback applies. Folding it into
  `Nous.Provider` would have meant optional callbacks most providers can't
  honour.
- **Consequence:** `DecisionModelError` is deliberately not
  fallback-eligible. A guard's backend failing must surface as an error, not
  silently move to a different model.

### 2. Questions are ordered lists; order survives JSON

Clef decides jointly, so question and option order changes the answers. A
map input with more than one question is rejected.

- **Chosen:** an internal `OrderedObject` struct implementing both
  `Jason.Encoder` (used by the Req backend) and `JSON.Encoder` (used by
  Hackney), passed through the existing `HTTP.post/4`.
- **Rejected:** adding a raw-body callback to `Nous.HTTP.Backend`. That would
  break every custom HTTP backend for one caller.

### 3. Defang before every backend, plus a vocabulary check locally

llama.cpp tokenizes the decision state with special-token parsing.
Benchmarked on Clef-Flash: "contains template tokens?" scored 0.02 on the raw
text and 0.93 after defanging.

- **Chosen:** `Nous.DecisionModel.decide/4` defangs every string in the state
  for every backend. Hosted servers were not measured, and defanging costs
  nothing. `Backend.LlamaCpp` additionally breaks any `<…>`, `[…]` or
  `|||…|||` that its loaded vocabulary reads as one token, because some
  special tokens (`<think>`, `<tool_call>`) are single tokens even without
  special parsing.
- **Token estimate:** without a tokenizer, assume one token per byte, an
  upper bound. The earlier 1.3 bytes per token undercounted digit runs, so
  chunking could rely on servers truncating silently.

### 4. One owning process per local model, resolved through a Registry

`Backend.LlamaCpp` is a GenServer that loads the GGUF in `handle_continue/2`
and serialises calls, because `%LlamaCppEx.Decision{}` is single-caller. It
registers in `Nous.DecisionModel.Registry`, with the model as the entry value.

- **Why a process:** model memory runs to gigabytes and the decision context
  is not concurrency-safe. Serialising is the correct default. A pool of
  contexts was considered and deferred: one GPU is shared, and the throughput
  gain was never measured.
- **Why a Registry:** review found that resolving `"llamacpp:<name>"` with
  `String.to_existing_atom/1` and calling the name directly reached *any*
  registered process (it crashed `Nous.TaskSupervisor`). Atom safety is not
  target safety. Keeping the model in `:persistent_term` also leaked it after
  the owner was killed. The registry entry solves both: only processes this
  module started resolve, and the model lives and dies with its process.
- **Other choices:** a request whose caller has already timed out or exited
  is skipped rather than decoded. If the context can't be rebuilt after a GPU
  watchdog failure, the process exits so its supervisor reloads the model.

### 5. Decision hooks keep `Hook.result` three-valued

A `:decision` hook maps bands to allow, escalate or deny, and resolves
escalation *inside* the runner. On `:pre_tool_use` it goes to the run's
approval handler; with no handler, the call is rejected.

- **Why:** every existing hook consumer matches `:allow | {:deny, r} |
  {:modify, m}`. A fourth `:escalate` result would have touched all of them
  and invited fail-open fallthroughs.
- **Invariant:** a decision hook can never approve what the permission policy
  refuses, because the normal approval gate still runs afterwards.
- **Edits are event-scoped:** an escalation `{:edit, changes}` applies only
  through the event's own key. Any other edit counts as not approved. Review
  showed that a generic merge let original content through on the wrong key.

### 6. Hook tasks are bounded; escalations are serial in the run process

`:function` and `:module` hooks run in tasks bounded by `Hook.timeout`, which
die with their caller. `timeout: :infinity` keeps a hook in-process, for hooks
that need `self()` or the process dictionary. With `parallel_tool_calls:
true`, pre-tool hooks run concurrently, but every escalation (a human prompt)
is sent back to the run process and handled one at a time.

- **Rejected:** a `:global.trans` lock for approvals. It polls with random
  back-off of up to about 8 s, and it is global for a per-run concern.

### 7. The router is an Agent field, and fails open

`router: {module, opts}` sits beside `:fallback` and is consulted by the
runner's single `effective_model/2`, before the request is built.

- **Why not a plugin:** model selection must happen before
  `prepare_request/4`, which plugins can't reach. Routing is also not security
  policy, so it is not inherited by sub-agents.
- **Fails open** to `agent.model` on error or low confidence. A routing
  outage should not stop the agent; guards, by contrast, fail closed.
- **Same seam as the fallback fix:** each iteration has exactly one effective
  model, and tool schemas and structured-output settings are built for it.
  This fixed sticky fallback, where requests had been shaped for the primary
  but sent to the fallback.

### 8. DecisionGuard user input: `before_request/3`, tracked on the session log

The user-input surface runs in the plugin's `before_request/3`, not as a
`:pre_request` hook, because `Nous.run/3`'s initial prompt is not part of the
hook payload. It checks every user message added since the last check.
"Since" is a position in the append-only session log, plus an anchor hash.

- **Rejected: list indices into `ctx.messages`.** Summarization compaction
  renumbers the projection, so later messages fell below the marker unchecked.
- **Rejected: a length heuristic for the system-prompt overlay.** A plugin
  could insert a user message that matched it. Now, unless `ctx.messages`
  exactly equals the log projection plus the overlay, every user message is
  checked. Drift costs a repeated check, never a skipped one.
- **Redaction:** a refused message is replaced by a *fresh* placeholder via
  `Context.replace_message/3`, which appends a log event. Patching `content`
  left `metadata.content_parts` in place, and the provider adapters send
  those parts.
- **Plugin order** must be before Summarization (enforced) and after plugins
  that inject user messages (documented).

### 9. Canary as a separate call

The opt-in canary is a second `decide/4` call on the same state. Placed inside
the main request it perturbed Clef's joint decoding: 13 verdicts flipped,
about −3 pp accuracy.

### 10. Default user-input preset `:balanced`

`:balanced` (allow below 0.3, deny at 0.7) escalates about 9.5% of inputs and
missed 30 of 166 attacks on the 326-item benchmark. `:strict` (0.06 / 0.53)
escalates about 32%. With no `on_escalate` handler an escalation on a blocking
surface rejects, so `:strict` as the default would reject a quarter to a third
of traffic. Both presets were tuned in-sample; the other surfaces' bands are
provisional (an 8-item probe).

## Open questions

- Port the session-log scan and `content_parts` classification to InputGuard,
  which still checks only the newest message's `content`.
- Measure a pool of decision contexts and Q4_K_M vs Q8_0 on local hardware.
- Seed independent corpora for the tool-call, tool-result and model-output
  surfaces, then re-tune their bands.
