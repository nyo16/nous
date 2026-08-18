# Code Mode

Instead of a chain of individual tool calls, the model writes a **program** that
calls tools — it loops, branches and fans out in one round trip. Only what the
program logs or returns re-enters the conversation.

```elixir
# 1. Add the optional runtime dependency to your app.
{:tyrex, "~> 0.4"}

# 2. Configure a provider.
config :nous, :code_runtime, {Nous.CodeRuntime.JS, timeout_ms: 30_000}

# 3. Turn it on for an agent.
agent =
  Nous.new("openai:gpt-4o",
    tools: [MyApp.Tools.Search, MyApp.Tools.Fetch],
    code_mode: :both
  )
```

The model now sees one extra tool, `run_code`, whose description carries a
generated typed SDK declaring every tool it may call. A program looks like this:

```javascript
const ids = await tools.search({ query: "elixir otp" });
const pages = await Promise.all(ids.map((id) => tools.fetch({ id })));
console.log(`fetched ${pages.length}`);
return pages.filter((p) => p.score > 0.5).map((p) => p.title);
```

Three tool calls' worth of work — a search, a fan-out, a filter — in one model
turn, and the conversation only gains the returned titles.

## Read this before turning it on

**It is not an unconditional token saving.** The SDK is a prompt prefix, and for
a handful of tools with rich JSON Schemas it can rival the native tool schemas it
replaces — under `mode: :both` the model sees *both*. Code Mode wins when a task
is genuinely multi-step or fans out; it loses on a single `bash` or `read`, where
a native call is already ideal. That is why `:both` is the default rather than
`:code`, and why the honest advice is to measure your own workload.

**The public evidence is thinner than the marketing.** No primary benchmark
compares Code Mode against tool-calling on identical tasks. Treat per-task
savings as something to verify, not to assume.

## Modes

| Mode      | The model sees                        | With no runtime configured        |
|-----------|---------------------------------------|-----------------------------------|
| `:native` | Tools only. No `run_code`.            | unchanged                         |
| `:both`   | Tools **and** `run_code` (default).   | degrades to `:native`             |
| `:code`   | `run_code` only.                      | `run_code` returns a clear error  |

`:both` degrades because advertising a `run_code` that can only fail is worse
than not advertising it. `:code` does **not** degrade: an operator who asked for
code mode gets an actionable error rather than a silent revert to a mode they
turned off.

Set it per agent (`code_mode: :both`) or globally
(`config :nous, :code_mode, :both`).

## Permissions and approval

There is one permission mechanism, not a second one inside Code Mode.

- **Bindings come from your policy.** Tools that survive
  `Nous.Permissions.filter_tools/2` get real closures; denied tools are present
  as stubs that return an error naming the tool, so a program gets a
  comprehensible failure instead of an undefined-function crash.
- **`run_code` sits outside the restriction layers** deliberately: it is injected
  *after* filtering, so a deny-all policy still restricts the agent rather than
  muting it. It dispatches through the whole pipeline, so hooks and permission
  plugins can inspect the program text before it runs.
- **Approval is per sub-call, not per program.** Approving a `run_code` call
  approves running *that program*; every sub-call to a tool with
  `requires_approval: true` consults your approval handler on its own, with the
  real tool name and the real arguments. A program computes its arguments at
  runtime, so the approved program text does not show them. With no handler in
  the context, such a tool is refused rather than run.
- Under `mode: :code`, a model-direct call to any other tool is denied *before*
  pre-tool hooks run — a guard should never have to observe, or worse approve, a
  call that can only fail.

## Sub-calls

Every sub-call goes through one driver lane (`Nous.CodeMode.Scheduler`):

- `max_parallel` bounds concurrency; a tool that declares
  `concurrency_safe?(args) == false` runs alone, and the lane drains before and
  after it. Absent or unreadable, a tool is treated as **exclusive** — guessing
  wrong costs interleaved side effects.
- Each dispatch is recorded as a bookkeeping session event, so the run is
  auditable while `ctx.messages` stays untouched.
- A failed sub-call surfaces in the program as an error carrying the tool name
  and a message, and nothing else. Stacktraces and internal error structs stay in
  your logs.

## The bundled runtime

`Nous.CodeRuntime.JS` runs programs in an embedded V8 isolate (Deno via Rustler
NIFs), one **fresh isolate per run** — no pooling, so no state survives a run.

| Budget | Setting | Behaviour |
|---|---|---|
| Wall clock | `:timeout_ms` (30s) | BEAM timer kills the isolate. Covers time spent in tool calls, which the substrate's own timeout does not. |
| Memory | `:max_heap_mb` (256) | Ends the run with an `:abort` failure; the BEAM is unaffected. |
| Output | `:max_output_bytes` (1MB) | Byte-accurate; keeps the fitting prefix and appends a truncation notice. |
| Capabilities | `:permissions` (`:none`) | Deno permissions. Filesystem, network, env and subprocess all denied. |

Isolation, stated exactly: it is a V8 isolate **in-process**, not an OS sandbox.
There is no separate process, so a V8 escape is an escape into the BEAM. What it
does enforce is that a program has no filesystem, network, env or subprocess
access, and no route into Elixir except the tools you granted — the runtime's
arbitrary-module bridge is narrowed to a single function and then removed from
the isolate before any model-authored code runs.

There is deliberately **no instruction budget**: this substrate has no fuel
metering, so the wall-clock deadline is the only bound on a compute-bound
program. It is a real one — the isolate is terminated, not abandoned.

A fresh isolate costs roughly 170ms per run. Against a multi-second model call
that is small, and it buys the guarantee that nothing carries over between runs.

## Writing a provider

Implement `Nous.CodeRuntime`: `language/1`, `isolation/1`, `start_run/2`,
`cancel/2`. Two rules matter more than the rest:

- **Failure is a field, never a raise.** `start_run/2` returns
  `{:error, {:contract, message}}` for *seam misuse only*. Everything the program
  does — throwing, looping to the deadline, flooding output, dying with its
  substrate — arrives as `%Nous.CodeRuntime.Result{error: %Failure{}}`. Running
  model-authored code that fails is the normal case, and the model needs to read
  the failure to write a better program.
- **The request carries no tuning knobs.** Budgets are provider configuration, so
  a program can never negotiate its own deadline.

A provider also owes callers a real kill, eager log streaming so a killed run
still reports what it said, and bindings called with the caller's authority and
nothing more. If your substrate cannot deliver a real kill, say so in its
moduledoc rather than implying it can.
