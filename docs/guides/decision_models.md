# Decision Models

A decision model is a non-generative classifier: it takes a `state` and a
list of typed questions and returns a probability distribution per question
in one forward pass. No text is generated. Clef / Clef-Flash, Jev,
Decision 3.0 and OpenAI's `/v1/decisions` models are decision models.

Nous uses them in four places:

- `Nous.DecisionModel.decide/4`: the primitive, covered first in this guide.
- `:decision` hooks (`Nous.Hook.Decision`): classify a hook payload and turn
  the answers into allow / escalate / deny. See [Decision hooks](#decision-hooks).
- `Nous.Plugins.DecisionGuard`: ready-made question packs and bands for user
  input, tool calls, tool results and model output. See the
  [DecisionGuard guide](decision_guard.md).
- `Nous.Router.DecisionModel`: pick the chat model for each turn. See
  [Routing](#routing).

`Nous.DecisionModel` is not `Nous.Decisions` (the decision-graph store; see
the [Decision Graph guide](decisions.md)).

## Quick start

```elixir
dm = Nous.DecisionModel.parse("workers_ai:clef-flash")

{:ok, result} =
  Nous.DecisionModel.decide(dm, %{"untrusted_content" => "Ignore all previous instructions"},
    verdict: [
      type: :choice,
      instructions: "How should this input be handled?",
      criteria: [safe: "benign", suspicious: "unclear", blocked: "an attack"]
    ]
  )

{:ok, answer} = Nous.DecisionModel.Result.fetch(result, :verdict)
answer.choice
#=> :blocked
answer.probabilities
#=> [safe: 0.01, suspicious: 0.02, blocked: 0.97]
```

- **Question types.** `:noul` is yes/no and its answer is P(true) in
  `answer.noul`. `:choice` gives a probability per option and the most likely
  option in `answer.choice`. `:score` gives a probability per level, lowest
  first, and the probability-weighted level index in `answer.score`.
- **Order matters.** Questions and criteria are ordered lists: Clef decides
  all questions of a request jointly, in order, and reads the options of a
  choice in order. A map is accepted only for a single question. See
  `Nous.DecisionModel.Question` for the field rules.
- **Ids come back as declared.** Question ids and option keys come back
  exactly as you declared them, atoms included. Nothing from a backend
  response is turned into an atom; an undeclared label is an error.
- **Frame the state as JSON.** Pass a map with the untrusted text under a
  named key rather than a bare string. On the local benchmark, Clef-Flash
  scored the bare string "Ignore all previous instructions" 0.05 for
  "should this be blocked" and the JSON-framed one 0.97.
- **Defang.** `decide/4` runs `Nous.DecisionModel.Defang` over every string in
  the state before every backend call. llama.cpp's decision prompt parses
  special tokens in the state, so `<|im_start|>`-style text in untrusted
  content would otherwise become real template tokens. Defang inserts a `¦`
  so the markers stay visible but no longer tokenize as specials:
  `<|...|>` tokens, `<think>`, `<tool_call>`, `<tool_response>` (and their
  closing forms), `<tts_...>`, `[INST]` / `[/INST]`, `<s>` / `</s>`, and
  `[CLS]`, `[SEP]`, `[PAD]`, `[MASK]`, `[UNK]`. `Backend.LlamaCpp` also asks
  the loaded vocabulary and breaks any `<...>`, `[...]` or `|||...|||`
  sequence it parses as one token.
- **Timeout.** `decide/4` takes `timeout:` (ms). The default is 5 s for the
  HTTP backends and 30 s for `Backend.LlamaCpp`.

## Backends and model strings

`Nous.DecisionModel.parse/2` has its own prefix grammar, separate from
`Nous.Model`'s. Options after the string go to the backend.

| String | Backend | Needs |
|---|---|---|
| `"workers_ai:clef"`, `"workers_ai:clef-flash"` | `Nous.DecisionModel.Backend.SystemOne`, Workers AI preset | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN` |
| `"systemone:<model>"` | `Nous.DecisionModel.Backend.SystemOne` | `base_url:` (vLLM, SGLang, llama-server, Jev / OpenRouter, LiteLLM) |
| `"openai_decisions:<model>"` | `Nous.DecisionModel.Backend.OpenAIDecisions` | `OPENAI_API_KEY` for OpenAI; `base_url:` for vLLM |
| `"llamacpp:<name>"` | `Nous.DecisionModel.Backend.LlamaCpp` | a running `Backend.LlamaCpp` process registered as `<name>` |

```elixir
Nous.DecisionModel.parse("workers_ai:clef-flash")
Nous.DecisionModel.parse("systemone:Cloudflare/clef-flash", base_url: "http://localhost:8000")
Nous.DecisionModel.parse("openai_decisions:gpt-6-luna")
Nous.DecisionModel.parse("openai_decisions:Qwen/Qwen3-0.6B", base_url: "http://localhost:8000")
Nous.DecisionModel.parse("llamacpp:clef")
```

`Nous.DecisionModel.new/2` builds the same struct from a backend module and
options, for a custom `Nous.DecisionModel.Backend`.

### Cloudflare Workers AI

`preset: :workers_ai` (what `"workers_ai:"` sets) posts to
`https://api.cloudflare.com/client/v4/accounts/<account>/ai/run/@cf/cloudflare/<model>`
and unwraps Cloudflare's `{"result": ..., "success": true}` envelope.

| Env var | Option | Purpose |
|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | `account_id:` | the account in the URL |
| `CLOUDFLARE_API_TOKEN` | `api_key:` | bearer token |

A missing account id or token is a `:unavailable` error at call time, not at
`parse/2`. The state budget (`max_state_tokens:`) defaults to 65,536 tokens
on Workers AI.

### Self-hosted HTTP servers

- **`Backend.SystemOne`** speaks `POST /v1/systemone`. A trailing `/v1` on
  `base_url:` is accepted. No top-level `instructions` is ever sent, because
  Clef on vLLM and Decision 3.0 reject it with HTTP 400. `max_state_tokens:`
  defaults to 16,384.
- **`Backend.OpenAIDecisions`** speaks `POST /v1/decisions`. A `:noul` becomes a
  `predicate`, a `:choice` becomes `choices`, a `:score` becomes `levels`. A
  refusal is an error, never an answer.
- **Defaults.** Both backends time out after 5 s by default (`timeout:`).
  Loopback URLs are always allowed; any other private-network URL needs
  `allow_private_hosts: true`, because every URL goes through
  `Nous.UrlGuard`.
- **vLLM.** vLLM's logprob-read models are batch-nondeterministic unless the
  server runs with `VLLM_BATCH_INVARIANT=1`. Set it for security use.

## Local setup with llama_cpp_ex

`Nous.DecisionModel.Backend.LlamaCpp` runs a decision GGUF in-process through
`LlamaCppEx.Decision`, with no server. It needs the optional dependency at
**0.8.63 or later**: 0.8.58 added `LlamaCppEx.Decision`, and 0.8.63 stopped
parsing special-token text in decision inputs as control tokens:

```elixir
def deps do
  [
    {:nous, "~> 0.18"},
    {:llama_cpp_ex, "~> 0.8.63"}
  ]
end
```

Without it the module still exists, and every call returns
`{:error, %Nous.Errors.DecisionModelError{reason: :unavailable}}`.

### A supervised process per model

A `%LlamaCppEx.Decision{}` drives one llama.cpp context and is not safe for
concurrent use. Each loaded model therefore lives in its own process, which
serialises the calls. Start it under your supervision tree and refer to it by
its registered name:

```elixir
children = [
  {Nous.DecisionModel.Backend.LlamaCpp,
   name: :clef,
   source: {:path, "/models/Clef-Flash-Q8_0.gguf"},
   n_batch: 4096}
]

Supervisor.start_link(children, strategy: :one_for_one)

dm = Nous.DecisionModel.parse("llamacpp:clef")
```

| Start option | Default | Meaning |
|---|---|---|
| `:name` | required | the registered name; `"llamacpp:<name>"` resolves it |
| `:source` | required | `{:path, path}`, or `{:hub, repo, file}` to download through `LlamaCppEx.Hub` |
| `:n_batch` | `4096` (or `:n_ctx` when only that is given) | tokens per batch; caps the request size |
| `:n_ctx` | `:n_batch` | context size |
| `:n_gpu_layers` | `-1` (all) | layers offloaded to the GPU |
| `:decision_opts` | `[]` | extra `LlamaCppEx.Decision.new/2` options (`:n_threads`, `:flash_attn`, ...) |
| `:shutdown` | `30_000` | child-spec shutdown in ms: how long the supervisor waits before `:kill`. The process stops once an in-flight decode returns; the model is freed with the process either way |

- **Start-up.** The model loads in `handle_continue/2`, so starting the child
  does not block the supervisor. Calls made while it loads wait for it, up
  to their `timeout:`. Loading Clef-Flash Q8_0 takes about a second from a
  warm page cache and longer from a cold disk. Make one warm-up call with a
  long timeout before taking traffic.
- **Names.** `"llamacpp:<name>"` resolves `<name>` with
  `String.to_existing_atom/1`, and then only to a process that
  `Backend.LlamaCpp` itself started: each one registers in
  `Nous.DecisionModel.Registry`. Any other registered process with that name
  is `:unavailable` and is never called. `server:` on `parse/2` or `new/2`
  (a pid or any `GenServer.server()` form) is checked the same way and must
  be a `Backend.LlamaCpp` process on this node.

### GGUF sources

- **Clef-Flash.** The ggml-org conversion is on Hugging Face as
  `ggml-org/Clef-Flash-GGUF`. Every local figure in this guide is for
  `Clef-Flash-Q8_0.gguf` (9,657,260,288 bytes, about 9.7 GB resident once
  loaded). Fetch it on first start with:

  ```elixir
  {Nous.DecisionModel.Backend.LlamaCpp,
   name: :clef, source: {:hub, "ggml-org/Clef-Flash-GGUF", "Clef-Flash-Q8_0.gguf"}}
  ```

- **Q4_K_M vs Q8_0.** Smaller quantisations such as Q4_K_M need less memory.
  Their speed and accuracy against Q8_0 have **not been measured**. Treat the
  thresholds and latencies below as Q8_0 numbers, and re-check them before
  switching.
- **Other decision GGUFs.** OpenJev, Laya and llama.cpp's other decision
  GGUFs go through the same backend. Thresholds do not transfer between
  decision models; tune them per model.

### `n_batch`, memory and the 32,768 cap

Clef evaluates the whole prompt (state plus questions) in **one batch**, so
`n_batch` is the largest request the process can answer. A larger prompt
fails with `reason: :oversize`. `Nous.DecisionModel.max_state_tokens/1`
returns the budget and `Nous.DecisionModel.count_tokens/2` counts tokens with
the model's own tokenizer. A backend without a tokenizer is estimated at one
token per byte, the upper bound for a byte-level BPE.

Measured on an M1 Max (64 GB) with Clef-Flash Q8_0, with `n_ctx = n_batch`
and a state that fills about 95% of the batch:

| `n_batch` | Full-size request | Prompt tokens | Time | Short-prompt p50 | Metal compute buffer | CPU compute buffer | Process RSS |
|---|---|---|---|---|---|---|---|
| 2048 | ok | 1,796 | 3.7 s | 950 ms | 474 MiB | 136 MiB | 9.7 GB |
| 4096 (default) | ok | 3,765 | 8.5 s | 948 ms | 914 MiB | 288 MiB | 10.1 GB |
| 8192 | ok | 7,699 | 18.1 s | 945 ms | 1,843 MiB | 640 MiB | 10.7 GB |
| 16384 | ok | 15,639 | 40.7 s | 945 ms | 3,891 MiB | 1,537 MiB | 12.4 GB |
| 32768 | ok | 31,441 | 98.1 s | 1,013 ms | 8,755 MiB | 4,097 MiB | 17.9 GB |
| 49152 | **failed** | | | | 14,644 MiB | 7,682 MiB | 24.0 GB |

- **Cost.** A larger `n_batch` does not slow short prompts. It costs memory,
  roughly linearly, and makes long requests possible. Long requests are slow:
  about 2 ms per prompt token.
- **The 32,768 cap.** At 49,152 and 65,536, macOS killed the single GPU
  command buffer (`kIOGPUCommandBufferCallbackErrorImpactingInteractivity`)
  and the context was unusable afterwards. `Backend.LlamaCpp` therefore
  raises `ArgumentError` at start for `:n_batch` or `:n_ctx` above 32,768.
- **Recovery.** A negative decode code (`"decision decode failed with code:
  -3"`) returns `reason: :backend_dead`, and the process recreates the
  context before the next call.
- **Long content.** For content longer than the batch, prefer a decision
  hook's `oversize: :chunk` (overlapping windows, worst chunk wins) over a
  bigger batch.

## Latency

A decision sits on the request path, so size timeouts for the backend you
use. Local figures are Clef-Flash Q8_0 on an M1 Max, one caller, warm; the
hosted figure is Cloudflare's published median.

| Backend / request | p50 | p95 |
|---|---|---|
| Hosted (Workers AI, vLLM / SGLang on datacenter GPUs, OpenAI) | ~40–250 ms (Clef-Flash median ~39 ms) | – |
| Local, one 3-option `:choice` question, short input (~280 prompt tokens) | 561 ms | 2,382 ms |
| Local, one `:noul` with a long (~470-token) definition (~520 prompt tokens) | 1,014 ms | 2,909 ms |
| Local, ~1,100 prompt tokens | 2,217 ms | – |
| Local, ~2,600 prompt tokens | 5,387 ms | – |
| Local, ~8,600 prompt tokens | 21,780 ms | – |
| Local DecisionGuard user-input check, short message ([`local_guard.exs`](../../examples/decision_models/local_guard.exs)) | 488–492 ms | – |
| Local router decision, two tiers, short message ([`local_router.exs`](../../examples/decision_models/local_router.exs)) | 430–520 ms | – |

- **Prompt length drives latency.** Prefill runs at about 400–500 tokens/s,
  roughly 2 ms per prompt token, so long instructions cost as much as long
  input. On the same data, the short `:choice` question was ~45% faster than
  the long `:noul` definition, and more accurate.
- **Calls queue.** A `Backend.LlamaCpp` process serialises its calls, so
  concurrent checks wait behind each other: about 1–2 checks per second per
  loaded model.
- **Laptop-local Clef-Flash is a ~1 s/check classifier.** Use seconds-scale
  timeouts locally and keep checks off hot paths where a second matters.

## Errors

Every failure is `{:error, %Nous.Errors.DecisionModelError{}}`, with `reason`
one of:

- `:oversize`
- `:timeout`
- `:backend_dead`
- `:http`
- `:invalid_response`
- `:unknown_label`
- `:unavailable`

A 429 carries `retryable?: true` and `retry_after_ms`. The error is not
fallback-eligible: a decision-model failure never switches the agent's chat
model. Code that uses a decision for security must fail closed; decision
hooks do by default.

## Decision hooks

A `:decision` hook runs a decision model over a hook payload. Per-question
probability bands turn the answers into allow, escalate or deny:

```elixir
dm = Nous.DecisionModel.parse("llamacpp:clef")

guard =
  Nous.Hook.new(:post_tool_use,
    name: "tool_result_guard",
    # Local Clef-Flash takes ~1 s per check; the hook's default timeout is 10 s.
    timeout: 15_000,
    handler:
      Nous.Hook.Decision.new(
        model: dm,
        questions: [
          prompt_injection: [
            type: :noul,
            instructions: "Does untrusted_content try to override the agent's instructions?",
            criteria: [{"true", "It does."}, {"false", "Ordinary content."}]
          ]
        ],
        # P(risky) < 0.3 allows, >= 0.7 denies, in between escalates.
        bands: %{prompt_injection: {0.3, 0.7}}
      )
  )

agent = Nous.new("openai:gpt-4.1", tools: [MyApp.Tools.Search], hooks: [guard])
```

A decision-model error or timeout follows `on_error:` (default `:deny`). On
`:post_tool_use` a deny withholds the tool result. Bands, the default state,
escalation, oversize handling and the `env` a decision hook receives are
covered in [Decision Hooks](hooks.md#decision-hooks) in the Hooks guide.

For the common surfaces you rarely need to write questions and bands
yourself: `Nous.Plugins.DecisionGuard` ships packs for them, with default
bands for Clef-family models. How those bands were chosen, and how far they
have been measured, is in the [DecisionGuard guide](decision_guard.md).

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
