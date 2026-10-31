# Decision Models

## Routing

A router picks the chat model for each request **before** the request is
built, so a cheap model answers the easy turns and a strong one the hard
turns. Configure it on the agent next to `:fallback`; it is a
model-selection setting, not a plugin. `Nous.Router.DecisionModel` asks a
decision model (Clef-Flash, Clef, ...) one `:choice` question whose options
are your tiers, and gets a probability per tier back in one forward pass. No
text is generated.

### A LiteLLM-style tier list

Tiers are declared once, cheapest first, each with the model to call and a
one-line description of what it is for. The decision model reads the
descriptions, so write them as routing criteria. Any `Nous.Model.parse/2`
option on a tier (`base_url:`, `api_key:`, `receive_timeout:`,
`llamacpp_model:`, ...) applies to that tier only.

```elixir
agent =
  Nous.new("anthropic:claude-sonnet-4-5",
    instructions: "You are a helpful assistant.",
    tools: [MyApp.Tools.Search],
    fallback: ["openai:gpt-4o"],
    router:
      {Nous.Router.DecisionModel,
       model: Nous.DecisionModel.parse("workers_ai:clef-flash"),
       granularity: :per_turn,
       min_confidence: 0.6,
       timeout: 1_000,
       tiers: [
         fast: [
           model: "groq:llama-3.1-8b-instant",
           description: "Greetings, small talk, one-line factual answers, simple arithmetic."
         ],
         balanced: [
           model: "openai:gpt-4o-mini",
           description: "Summaries, short explanations, single tool lookups."
         ],
         frontier: [
           model: "anthropic:claude-sonnet-4-5",
           description: "Multi-step reasoning, proofs, code changes, planning with several tools."
         ],
         local: [
           model: "custom:qwen3-8b",
           base_url: "http://localhost:8080/v1",
           description: "Requests that mention internal or confidential data."
         ]
       ]}
  )

{:ok, result} = Nous.run(agent, "What is 2+2?")
```

A tier value may also be a bare model string or a `%Nous.Model{}`; the
description then defaults to the tier key. `Nous.run(agent, prompt, router:
nil)` turns routing off for one run, and `router: {...}` replaces it.

If the decision is below `:min_confidence`, the decision model fails, or the
router returns `:default`, the request goes to the agent's own model (here
`claude-sonnet-4-5`). Routing **fails open by design**: it is a cost and
latency control, not a security control. Use `Nous.Plugins.InputGuard` or
hooks for security decisions.

### Granularity and prompt-cache loss

`:granularity` sets when the router is asked. Each answer can move the run
to another model, and every move discards the provider-side prompt cache the
previous model had built for this conversation. On long agentic turns that
cache is usually worth more than the tier saving.

| Granularity | Router asked | Decisions per turn | Model switches | Fits |
|---|---|---|---|---|
| `:once` | first request of the run | ≤ 1 per run | none inside a run | one-shot runs, batch jobs |
| `:per_turn` (default) | first request of each turn | 1 | at most once per turn, before the first request | chat; the cache survives the tool loop |
| `:per_iteration` | every request, also after tool results | 1 per request | possible on every request | short turns where tool output changes the difficulty |
| `:escalate_only` | every request until the top tier | ≤ 1 per request | upward only, at most `tiers - 1` per run | agentic loops that start cheap and escalate once |

- A turn is one `Nous.run/3` call (one `Nous.AgentServer` run). A
  structured-output validation retry opens another turn, so `:per_turn`
  routes it again.
- The decision is runtime-only. It never reaches `result.deps` or a persisted
  context, so every run routes afresh, even under `:once`.
- `:escalate_only` starts on the cheapest tier. A decision for a lower or
  equal tier, `:default` or an error keeps the current tier. Once the top
  tier is reached the router is no longer asked.
- A switch to another provider re-converts the tool schemas and the
  structured-output settings for that provider. The router runs before the
  request is built, so every request carries its own provider's tool format
  and `response_format`.

### Latency budget per turn

A routing decision sits on the request path: the first token of a turn
arrives one decision later. Budget per turn:

`decision latency × decisions per turn` (1 for `:per_turn`, one per request
for `:per_iteration`).

| Decision backend | Per decision |
|---|---|
| Hosted (Workers AI, vLLM / SGLang, OpenAI `/v1/decisions`) | ~40–250 ms (Clef-Flash median ~39 ms) |
| Laptop-local Clef-Flash (`Nous.DecisionModel.Backend.LlamaCpp`) | ~0.5–1 s for a short message |
| Laptop-local, long state | ~2 ms per prompt token |

- The state is the latest user message, JSON-framed and defanged. Add
  earlier user messages with `context_turns: n`. Each one adds state tokens
  and therefore latency, about 2 ms per token on a local model.
- Set `:timeout` (ms) to cap a decision. A timeout is a decision-model
  error, so that request goes to the agent's model rather than waiting.
- A local `Backend.LlamaCpp` process serialises calls. Concurrent agents
  routing through one local decision model queue behind each other.

### Fallback interplay

- A routed request uses the chain `[routed | agent.fallback]`, without
  duplicates. If the routed tier fails with a provider or model error, the
  agent's `:fallback` models are tried in order, each with its own
  provider's request format.
- A routed tier that answers is **not** a fallback. Neither
  `[:nous, :agent, :fallback, :used]` nor the run's `fallback_used` fires
  for it. Fallback events compare the answering model with the routed one
  and report the routed model as `original_*`.
- A fallback that answered stays sticky until the next routing boundary.
  There the new decision clears it and the routed model is tried again.
  Under `:per_iteration` that is every request.
- The configured `agent.model` is only used when there is no route.

### Observability

Every consultation emits `[:nous, :router, :route]`:

- **Measurements:** `duration`, the router call's latency.
- **Metadata:** `tier`, `probabilities`, `confidence`, and `cause`:
  `:routed`, `:held`, `:default`, `:low_confidence`, `:no_input` or `:error`
  (`reason` carries the error). It also names the model the requests now go
  to (`model_provider`, `model_name`), plus `turn`, `iteration` and
  `granularity`.

A routing failure is logged at warning level, a `:default` at info. The
run-stop event's `active_model_provider` / `active_model_name` name the
model that served the last request.

```elixir
:telemetry.attach("route-log", [:nous, :router, :route], fn _event, %{duration: d}, meta, _ ->
  ms = System.convert_time_unit(d, :native, :millisecond)
  IO.puts("#{meta.cause} → #{meta.model_provider}:#{meta.model_name} (#{inspect(meta.tier)}, #{ms} ms)")
end, nil)
```

### Not routed: `run_stream/3`

`Nous.run_stream/3` is a single request whose consumer owns the stream, and
it is **never routed**. It always uses `agent.model` and its fallback chain.
For a routed, streamed run use `Nous.run(agent, prompt, stream: true)` with
`:on_llm_new_delta` callbacks.

### Custom routers

Any module implementing `Nous.Router` can be used: `route/3` returns
`{:ok, model}` or `:default`. It may also implement `tiers/1`, which
`:escalate_only` needs. See the `Nous.Router` docs for the callbacks and for
the `info` map a router receives.
