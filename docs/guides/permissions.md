# 🛡️ Permissions & Session Guardrails

Two complementary safety subsystems for Nous agents:

- **Permissions** (`Nous.Permissions` + `Nous.Permissions.Policy`) — controls,
  at the *tool* level, which tools an agent may use, which it must ask the user
  to approve, and which are denied outright.
- **Session Guardrails** (`Nous.Session.Config` + `Nous.Session.Guardrails`) —
  bounds a *whole session*: how many turns it may take and how many tokens it
  may spend, plus when to compact history.

The two are independent. Permissions stop a single tool call from doing
something dangerous; guardrails stop a session from running away. Use both.

Two adjacent hardening mechanisms are documented at the end of this guide,
because both bite operators in production: how `Nous.Plugins.InputGuard` fails
closed when a detection strategy dies, and the scrubbed environment
`Nous.Tools.Env` hands to tool subprocesses.

## Table of Contents

- [The Permissions Engine](#the-permissions-engine)
- [Policy Modes](#policy-modes)
- [Building a Policy](#building-a-policy)
- [Blocking, Approval, and Filtering](#blocking-approval-and-filtering)
- [The Execute Gate](#the-execute-gate)
- [Wiring Permissions into an Agent](#wiring-permissions-into-an-agent)
- [Session Guardrails](#session-guardrails)
- [Guardrails vs. the Agent Loop](#guardrails-vs-the-agent-loop)
- [Input Guard Fail-Closed](#input-guard-fail-closed)
- [Scrubbed Tool Subprocess Environments](#scrubbed-tool-subprocess-environments)
- [Worked Examples](#worked-examples)
- [Gotchas](#gotchas)
- [Related guides](#related-guides)

## The Permissions Engine

`Nous.Permissions` is a pure-function engine over a `%Nous.Permissions.Policy{}`
struct. A policy carries five decision inputs plus a mode:

```elixir
%Nous.Permissions.Policy{
  mode: :default,                 # :default | :permissive | :strict
  deny_names: MapSet.new(),       # exact tool names to block (case-insensitive)
  deny_prefixes: [],              # name prefixes to block, e.g. ["web_"]
  allow_names: MapSet.new(),      # explicit allowlist (exact)
  allow_prefixes: [],             # explicit allowlist (prefix)
  approval_required: MapSet.new(),# tools that need user approval in :default
  allow_unattended_execute: false # opt-in to drop the execute gate under :permissive
}
```

Three preset constructors cover the common cases:

```elixir
Nous.Permissions.default_policy()
# read/search open; bash, file_write, file_edit require approval

Nous.Permissions.permissive_policy()
# %Policy{mode: :permissive} — everything open (but see The Execute Gate)

Nous.Permissions.strict_policy()
# %Policy{mode: :strict} — everything requires approval, deny-by-default at the filter
```

## Policy Modes

| Mode          | Filtering (what tools are exposed)                              | Approval (`requires_approval?/2`)                          |
| ------------- | -------------------------------------------------------------- | ---------------------------------------------------------- |
| `:default`    | all tools except denied                                        | only names in `approval_required`                          |
| `:permissive` | all tools except denied                                        | nothing — *except* `:execute` category (see below)         |
| `:strict`     | **only** tools in the allowlist (deny-by-default with no list) | every tool                                                 |

An unknown/invalid mode is treated as **fail-closed**: `blocked?/2` returns
`true` and `requires_approval?/2` returns `true`, so a corrupt policy never
silently opens up the tool set.

### Deny-by-default: an allowlist applies in EVERY mode

This is the single most important rule. The moment a policy has a non-empty
`allow_names` **or** `allow_prefixes`, `blocked?/2` switches to *deny-by-default*
**regardless of mode** — any tool not on the allowlist (and not already denied)
is blocked. The allowlist is checked before the per-mode fallthrough, so:

```elixir
# :default mode, but with an allowlist -> ONLY file_read is exposed.
policy = Nous.Permissions.build_policy(mode: :default, allow: ["file_read"])
Nous.Permissions.blocked?(policy, "file_read")  #=> false
Nous.Permissions.blocked?(policy, "bash")       #=> true
```

Historically the allow lists were only consulted in `:strict` mode, which made
`build_policy(allow: ["x"])` on the default mode silently allow *every* tool — a
fail-open footgun. That is fixed: an allowlist means deny-by-default everywhere.

## Building a Policy

`build_policy/1` is the ergonomic constructor. It downcases all names/prefixes
(matching is case-insensitive) and validates the mode, raising `ArgumentError`
on anything outside `[:default, :permissive, :strict]`.

```elixir
policy =
  Nous.Permissions.build_policy(
    mode: :default,
    deny: ["bash"],                       # exact names
    deny_prefixes: ["web_"],              # prefix match
    allow: ["file_read", "file_grep"],    # turns on deny-by-default!
    allow_prefixes: ["search_"],
    approval_required: ["file_write"],
    allow_unattended_execute: false
  )
```

Supported options: `:mode`, `:deny`, `:deny_prefixes`, `:allow`,
`:allow_prefixes`, `:approval_required`, `:allow_unattended_execute`. Omitted
keys default to empty/`false`, and `:mode` defaults to `:default`.

## Blocking, Approval, and Filtering

**`blocked?/2`** — is this tool name denied? Checks `deny_names` (exact),
`deny_prefixes` (prefix), then the allowlist (if present), then the mode
fallthrough.

```elixir
policy = %Nous.Permissions.Policy{deny_names: MapSet.new(["bash"]), deny_prefixes: ["web_"]}
Nous.Permissions.blocked?(policy, "bash")       #=> true
Nous.Permissions.blocked?(policy, "web_fetch")  #=> true
Nous.Permissions.blocked?(policy, "file_read")  #=> false
```

**`requires_approval?/2`** — does this tool need a human to say yes?

```elixir
Nous.Permissions.requires_approval?(Nous.Permissions.strict_policy(), "file_read")     #=> true
Nous.Permissions.requires_approval?(Nous.Permissions.permissive_policy(), "bash")      #=> false (but /3 differs!)
Nous.Permissions.requires_approval?(Nous.Permissions.default_policy(), "file_write")   #=> true
```

**`filter_tools/2`** — reject blocked tools from a `[%Nous.Tool{}]` list:

```elixir
tools    = Enum.map([Bash, FileRead, FileWrite], &Nous.Tool.from_module/1)
policy   = Nous.Permissions.build_policy(deny: ["bash"])
allowed  = Nous.Permissions.filter_tools(policy, tools)   # [file_read, file_write]
```

**`partition_tools/2`** is the same decision but returns `{allowed, blocked}`,
handy for logging or showing the user what was withheld.

## The Execute Gate

There are **two** arities of `requires_approval?`:

- `requires_approval?(policy, name)` — name-only.
- `requires_approval?(policy, name, category)` — category-aware.

The category-aware `/3` adds one rule on top of `/2`: under `:permissive` mode,
a tool whose declared `Nous.Tool` `category` is `:execute` (e.g. `bash`) **still
requires approval** unless the policy sets `allow_unattended_execute: true`.

```elixir
permissive = Nous.Permissions.permissive_policy()

Nous.Permissions.requires_approval?(permissive, "bash")            #=> false   (/2 is blind to category)
Nous.Permissions.requires_approval?(permissive, "bash", :execute)  #=> true    (the execute gate)

unattended = Nous.Permissions.build_policy(mode: :permissive, allow_unattended_execute: true)
Nous.Permissions.requires_approval?(unattended, "bash", :execute)  #=> false   (gate opted out)
```

The reason: `:permissive` is a single switch, and without this gate flipping it
would silently turn the LLM into unattended remote-code-execution. The execute
gate ensures one config choice can't do that — you must *separately* set
`allow_unattended_execute: true` to run execute-class tools without approval.

> The agent runtime always calls the `/3` arity (passing `tool.category`), so
> the execute gate is enforced for real agents. Only the name-only `/2` form is
> blind to it.

## Wiring Permissions into an Agent

A policy is attached to an agent via its `:permissions` field
(`Nous.Permissions.Policy.t() | nil`); `nil` means no policy is enforced.

```elixir
agent =
  Nous.Agent.new(
    name: "coder",
    permissions: Nous.Permissions.build_policy(
      mode: :default,
      approval_required: ["bash", "file_write", "file_edit"]
    )
    # ...model, tools, etc.
  )
```

The runtime applies the policy in two distinct places:

1. **Filtering** — before each model call, `filter_tools/2` removes blocked
   tools so the model never even sees them. (`nil` policy → tools pass through
   unchanged.)
2. **Approval** — when a tool is about to run, the policy composes with the
   tool's own `requires_approval` flag: if *either* the per-tool flag is `true`
   *or* the policy's category-aware `requires_approval?/3` says so, the tool is
   marked approval-required. A tool already `requires_approval: true` keeps that
   regardless of the policy.

Approval-required tools are then routed to the `:approval_handler` set on the run
context (`Nous.Agent.Context`) (see
the [human-in-the-loop example](../../examples/11_human_in_the_loop.exs)). Default-deny applies here
too: a tool needing approval with **no** handler configured is *rejected*, not
auto-approved — the `requires_approval` flag is never a silent no-op.

## Session Guardrails

Where permissions guard individual calls, guardrails bound the whole session.

`Nous.Session.Config` holds the limits (with these defaults):

```elixir
%Nous.Session.Config{
  max_turns: 10,             # hard stop after this many turns
  max_budget_tokens: 200_000,# hard stop once input+output tokens reach this
  compact_after_turns: 20    # trigger history compaction past this turn count
}

config = Nous.Session.Config.new(max_turns: 50, max_budget_tokens: 1_000_000)
```

`Nous.Session.Guardrails` is the matching pure-function checker:

**`check_limits/4`** — `check_limits(config, turn_count, input_tokens, output_tokens)`.
Returns `:ok`, `{:error, :max_turns_reached}`, or `{:error, :max_budget_reached}`.
Turns are checked first; the budget compares `input_tokens + output_tokens`
against `max_budget_tokens`. Both bounds are **inclusive** (`>=`):

```elixir
config = %Nous.Session.Config{max_turns: 10, max_budget_tokens: 100_000}
Guardrails.check_limits(config, 5, 1_000, 2_000)   #=> :ok
Guardrails.check_limits(config, 10, 1_000, 2_000)  #=> {:error, :max_turns_reached}
```

**`should_compact?/2`** — `should_compact?(config, turn_count)` returns `true`
once `turn_count` is **strictly greater than** `compact_after_turns`:

```elixir
config = %Nous.Session.Config{compact_after_turns: 20}
Guardrails.should_compact?(config, 25)  #=> true
Guardrails.should_compact?(config, 20)  #=> false   (strict >, not >=)
```

**`remaining/4`** — returns `{remaining_turns, remaining_tokens}`, each floored
at `0`. **`summary/4`** wraps everything into a map for logging or surfacing
session health to the user:

```elixir
Guardrails.summary(config, 5, 10_000, 20_000)
#=> %{
#=>   turns:  %{current: 5, max: 10, remaining: 5},
#=>   tokens: %{used: 30_000, max: 200_000, remaining: 170_000},
#=>   needs_compaction: false
#=> }
```

These functions are *advisory* — they compute decisions but don't enforce
anything by themselves. You wire them into your own session GenServer (e.g.
`Nous.AgentServer` or a custom one): call `check_limits/4` before each turn and
stop the session on `{:error, _}`; call `should_compact?/2` to decide when to
summarize history.

```elixir
def handle_call({:send, msg}, _from, state) do
  case Guardrails.check_limits(state.config, state.turns, state.in_tokens, state.out_tokens) do
    :ok ->
      {reply, new_state} = run_turn(msg, state)
      {:reply, reply, new_state}

    {:error, why} ->
      {:reply, {:error, why}, state}
  end
end
```

## Guardrails vs. the Agent Loop

These limits are **distinct** from the agent loop's `max_iterations`.

- `max_iterations` (default `10`, on `Nous.Agent.Context`) bounds the *inner*
  reason→tool→reason loop of a *single* agent run. Exceeding it raises
  `Nous.Errors.MaxIterationsExceeded`.
- `Session.Config` limits bound a *managed session* — many turns, each of which
  may be a full agent run with its own iteration budget.

One session turn can consume up to `max_iterations` loop steps. Setting
`max_turns: 10` does **not** cap iterations, and a small `max_iterations` does
not bound a long-lived session. Configure both deliberately.

## Input Guard Fail-Closed

`Nous.Plugins.InputGuard` guards a third surface: the *user input*, before the
model ever sees it. It runs in the `before_request` plugin hook and reads its
configuration from `ctx.deps[:input_guard_config]`. Each configured
`{strategy_module, opts}` pair returns a verdict, the verdicts are aggregated
(`:any` — the default — `:majority`, or `:all`), and the resulting severity is
mapped to an action by `Nous.Plugins.InputGuard.Policy` (default
`%{suspicious: :warn, blocked: :block}`: `:warn` injects a system-message
warning and continues, `:block` halts the loop).

What matters for guardrails is what happens when a strategy *fails to* vote. A
strategy that raises, throws, or exits is **dropped**; on the parallel path, a
strategy that outruns `:strategy_timeout` is killed and dropped too. A drop is
not a `:safe` verdict — it is *no* verdict, and counting it as `:safe` is
fail-open: one flaky LLM-judge call and your only substantive detector is gone.

### `:fail_closed`

| Aggregation          | `:fail_closed` default |
| -------------------- | ---------------------- |
| `:any` (the default) | `true`                 |
| `:majority`          | `false`                |
| `:all`               | `false`                |

When `fail_closed` is in effect **and** at least one strategy was dropped, an
otherwise-`:safe` aggregate is upgraded to `:suspicious`, carrying a reason of
"N input-guard strategies did not complete (error or timeout); failing closed"
and `metadata: %{dropped_strategies: n, fail_closed: true}`. Only `:safe` is
upgraded — a `:suspicious` or `:blocked` aggregate passes through untouched, and
with zero drops the aggregate is returned as-is.

`:majority` and `:all` default to `false` because they already count drops
against the *configured* strategy count rather than the number of survivors:
a drop shrinks the numerator, never the denominator, so it can only make those
modes stricter. (That denominator choice is itself deliberate — otherwise an
attacker who makes benign strategies error could shrink the vote and flip the
outcome.)

Every drop — regardless of `fail_closed` — emits a `Logger` warning and the
`[:nous, :input_guard, :strategy_dropped]` telemetry event, with measurement
`%{count: dropped}` and metadata `%{aggregation: mode, fail_closed: boolean}`.
Attach a handler to that event before tuning anything: it tells you whether your
detectors are actually flaky, instead of guessing.

### `:strategy_timeout`

Per-strategy timeout in milliseconds; default `30_000`. It bounds the **parallel
path only** — the default `short_circuit: false`, which runs strategies through
`Task.Supervisor.async_stream_nolink/4` with `on_timeout: :kill_task`. With
`short_circuit: true` strategies run sequentially so the first `:blocked` verdict
can skip the rest, and the timeout is not applied: a strategy that hangs there
hangs the request. If any strategy does network I/O, stay on the parallel path
and set a timeout comfortably below your request budget.

Strategies that never ran because short-circuiting stopped after a `:blocked`
verdict are **not** drops — only errors and timeouts are.

```elixir
{:ok, result} =
  Nous.run(agent, "summarize this ticket",
    deps: %{
      input_guard_config: %{
        strategies: [
          {Nous.Plugins.InputGuard.Strategies.Pattern, []},
          {Nous.Plugins.InputGuard.Strategies.LLMJudge, model: "openai:gpt-4o-mini"}
        ],
        aggregation: :any,
        fail_closed: true,
        strategy_timeout: 5_000,
        policy: %{suspicious: :warn, blocked: :block}
      }
    }
  )
```

> **Upgrading from before 0.16.5: your guard just got stricter.** This is a
> behavior change, not a new opt-in. Previously a dropped strategy was silently
> ignored, so an `:any` guard whose only real detector errored or timed out
> returned `:safe` and the input passed. The same run now yields `:suspicious`,
> which under the default policy injects a system warning into the request — and
> if you mapped `suspicious: :block`, halts the agent loop instead. A flaky
> strategy (network-dependent judges are the usual suspect) will therefore start
> producing warnings or blocks on input that used to pass. Fix the flaky
> strategy, raise `:strategy_timeout`, or set `fail_closed: false` to restore the
> old fail-open behavior — and watch
> `[:nous, :input_guard, :strategy_dropped]` to know which you need.

## Scrubbed Tool Subprocess Environments

Tools that spawn OS processes must not hand the BEAM's environment to a child
whose arguments the LLM controls: that environment routinely holds
`OPENAI_API_KEY`, OAuth tokens, and vault credentials, and the model is one
`printenv` away from exfiltrating them. `Nous.Tools.Env` is the single
definition of what may cross that line:

```elixir
Nous.Tools.Env.scrubbed()
#=> [{"PATH", "/usr/bin:/bin"}, {"HOME", "/Users/me"}, {"LANG", "en_US.UTF-8"}, ...]
```

`scrubbed/0` returns `{name, value}` tuples for exactly these variables —
`PATH`, `HOME`, `LANG`, `LC_ALL`, `TZ`, `USER`, `SHELL`, `TERM` — and only for
those currently set; an unset variable is omitted rather than forwarded as
`nil`.

The allowlist *is* the filter: every `*_API_KEY`, `*_TOKEN`, and `*_SECRET`, plus
the shared-library loader hooks `LD_PRELOAD` and `DYLD_INSERT_LIBRARIES` (a
code-injection vector into any binary the tool runs), are simply not on it.

### Where it is applied for you

- `Nous.Tools.Bash` — passes `env: Nous.Tools.Env.scrubbed()` to its
  `NetRunner.run/2` call, alongside an absolute `/bin/sh` so the shell itself
  isn't resolved through `PATH`.
- `Nous.Tools.FileGrep` — passes it to the `System.cmd/3` call that runs `rg`,
  which is located with `System.find_executable/1` rather than a `which`
  subprocess.

No other built-in tool spawns a subprocess, and nothing intercepts process
spawning globally.

### Tool authors must call it explicitly

If your own tool shells out, pass the scrubbed environment yourself. This is the
one line that keeps your tool from becoming the leak:

```elixir
defmodule MyApp.Tools.GitStatus do
  # ...Nous.Tool.Schema boilerplate...

  def execute(_ctx, _args) do
    case System.cmd("git", ["status", "--short"], env: Nous.Tools.Env.scrubbed()) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end
end
```

### Extending the allowlist

The allowlist is a compile-time module attribute inside `Nous.Tools.Env` with no
runtime configuration hook — deliberately, so there is exactly one auditable
definition. A variable your tool needs (say `GIT_CONFIG_GLOBAL` or
`RIPGREP_CONFIG_PATH`) is therefore dropped unless it is added there upstream.
Until then, extend it at the call site rather than reaching for the raw
environment:

```elixir
env = Nous.Tools.Env.scrubbed() ++ [{"GIT_CONFIG_GLOBAL", "/etc/myapp/gitconfig"}]
System.cmd("git", ["status", "--short"], env: env)
```

Never add a credential-bearing variable back. If a tool genuinely needs a
secret, read it in Elixir and pass it as an argument or on stdin, where you
control the blast radius, instead of exporting it to every child process.

> **`scrubbed/0` decides what Nous forwards; it is not a sandbox boundary.**
> `System.cmd/3`'s `:env` merges over the inherited environment rather than
> replacing it, so a variable the BEAM already exports can still reach the child
> unless you unset it explicitly by passing `{"VAR", nil}`. Size your trust
> accordingly: gate execute-class tools with `Nous.Permissions`, and on nodes
> that run them prefer loading provider keys into application config in
> `runtime.exs` (`config :nous, openai_api_key: fetch_from_vault()`, which is
> where `Nous.Model` reads them from) over exporting them into the OS
> environment.

## Worked Examples

- **`examples/advanced/tool_permissions.exs`** — a tour of the engine: builds
  tools with `Nous.Tool.from_module/1`, prints `blocked?`/`requires_approval?`
  for each preset, builds a custom policy (deny `bash`, block `file_write*`,
  approve `file_edit`), and partitions/filters the tool list for an agent.

- **`examples/19_coding_agent.exs`** — end-to-end: builds a `:default` policy
  (`approval_required: ["bash", "file_write", "file_edit"]`), filters the six
  coding tools through it, then sets up `Session.Config.new(max_turns: 5,
  max_budget_tokens: 50_000, compact_after_turns: 3)` and drives a simulated
  session loop with `Guardrails.check_limits/4` and `Guardrails.summary/4`.

Run either with `mix run examples/<path>.exs`.

## Gotchas

- **An allowlist is deny-by-default in every mode.** Adding `allow:` to a
  `:default` policy does **not** "allow those in addition" — it switches to
  allowlist-only and blocks everything else. If you only want to *add* approval
  or *remove* specific tools, use `deny:`/`approval_required:`, not `allow:`.

- **`requires_approval?/2` is blind to the execute gate.** Only the `/3` arity
  enforces that `:permissive` still gates `:execute` tools. The agent runtime
  uses `/3`; if you call the engine yourself for an execute-class tool, pass the
  category or you'll under-report approval needs.

- **`:permissive` does not mean unattended `bash`.** Execute-class tools still
  require approval under `:permissive` unless `allow_unattended_execute: true`.
  This is intentional anti-RCE protection, not a bug.

- **Approval-required with no handler = rejected.** A policy (or per-tool flag)
  that demands approval but no `:approval_handler` is configured will *reject*
  the call, not silently run it. Wire up a handler whenever you gate tools.

- **Guardrail limits are inclusive; compaction is strict.** `check_limits/4`
  uses `>=` (you stop *on* the limit), but `should_compact?/2` uses `>` (it
  fires only *past* the threshold). The off-by-one is deliberate — mind it in
  tests.

- **Budget counts input + output together.** `max_budget_tokens` is compared
  against the sum, not either side alone. Size it for total spend.

- **Guardrails enforce nothing on their own.** They are pure functions; you must
  call them in your session loop. Forgetting to means the limits do nothing.

- **`max_turns` ≠ `max_iterations`.** See the section above — they cap different
  loops and neither bounds the other.

- **InputGuard fails closed on dropped strategies since 0.16.5.** Under the
  default `aggregation: :any`, a strategy that errors or times out upgrades a
  `:safe` verdict to `:suspicious` — input that used to pass may now warn or
  block. `fail_closed: false` restores the old behavior.

- **A scrubbed env is not a sandbox.** `Nous.Tools.Env.scrubbed/0` controls what
  Nous forwards to a subprocess; it does not unset what the OS child already
  inherits. Custom tools that shell out must pass it themselves — nothing does
  it for them.

## Related guides

- [Tool Development](tool_development.md) — defining tools, the `requires_approval`
  flag, and tool `category` (`:read` / `:write` / `:execute`).
- [Human-in-the-loop example](../../examples/11_human_in_the_loop.exs) — wiring an
  `:approval_handler` to satisfy approval-required tools.
- [Production Best Practices](best_practices.md) — running managed, long-lived
  agent sessions that consume these guardrails.
