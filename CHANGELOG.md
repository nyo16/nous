# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **A tool timeout is no longer retried, so one approval no longer bought two
  executions.** `Nous.ToolExecutor`'s internal `execute_with_timeout` kills the tool
  process on the deadline and then *raises* `Nous.Errors.ToolTimeout`, which the
  generic rescue clause routed into `handle_execution_error/7` — the retry path.
  With `retries` defaulting to 1, every timeout ran the tool a second time:
  measured on the real `bash` tool, a 120-second command asked for at the
  then-30-second deadline came back as `attempt: 2` after 60 seconds. `bash` is
  `requires_approval: true` and side-effecting, so a human who approved one
  `git push`, `rm` or payment POST got two, the first killed part-way through.
  A timeout is now terminal on both timeout paths: the executor cannot know how
  much of the work already landed, and wrongly repeating side effects costs far
  more than the one visible error a caller can retry deliberately. Retries are
  untouched for ordinary failures. Making retry-on-timeout opt-in per tool was
  considered and rejected: nothing can make the second run safe, so there is no
  configuration worth offering. Note that the retry path never re-consulted the
  approval handler — `check_approval/3` runs once in `execute/3` before the
  retry loop — so the second execution was also unprompted.

- **Code Mode sub-calls no longer inherit the runner's approval gate.**
  `Nous.Agent.Context.to_run_context/2` marks a context `approval_gated?: true`
  because the runner already ran the approval pipeline for the call it is
  dispatching — correct for `run_code` itself, and wrong for every tool the
  program then calls. Passed through unchanged, one approval of "run this
  program" silently authorised every `Bash`, `FileWrite` and `FileEdit` the
  program reached: the handler was never consulted and the tool ran. Approving a
  `run_code` call now approves running *that program* only. Each sub-call to a
  tool with `requires_approval: true` consults the handler on its own, with the
  real tool name and the real arguments — which is what an operator needs, since
  a program computes its arguments at runtime and the approved program text does
  not show them. With no handler in the context such a tool is refused rather
  than run, matching the default-deny every other entry point already applies.
  Found by writing the integration test the plan asked for; the test that had
  asserted the old behaviour is corrected with a comment recording why.

- **`Nous.Plugins.HumanInTheLoop` no longer auto-approves tools outside its
  `:tools` list.** The handler is only ever invoked for tools already flagged
  `requires_approval: true`, so filtering it by the configured `:tools` list
  sent every *other* approval-gated tool down an `else -> :approve` branch.
  Configuring HITL with `tools: ["send_email"]` therefore flipped `Bash`,
  `FileWrite`, and `FileEdit` from default-deny to silent auto-approve —
  installing the approval plugin made an agent strictly less safe than
  omitting it, and left unattended command execution one prompt injection
  away. The handler is now passed through unchanged; `:tools` still tags
  those tools as approval-requiring, but can no longer narrow the gate.

- **Approval enforcement is now structural rather than positional.**
  `requires_approval` was only checked inside `Nous.AgentRunner`, so the three
  other paths to a tool — `Nous.LLM`'s tool loop, `Nous.Workflow` `:tool_step`,
  and any direct `Nous.ToolExecutor.execute/3` call — executed `Bash` /
  `FileWrite` / `FileEdit` with no approval, permission policy, or hooks. In
  the workflow case, model-authored `:agent_step` output reached `/bin/sh -c`
  unattended. `%Nous.RunContext{}` gains `:approval_handler` and
  `:approval_gated?`, and `ToolExecutor.execute/3` now default-denies an
  approval-gated tool unless the context supplies a handler that approves it
  or is flagged as already gated. The agent runner marks its context gated, so
  operators are not prompted twice and its behaviour is unchanged.

- **`Nous.Tools.WebFetch` bounds its responses.** The model-supplied-URL egress
  point had no size or content-type limit and fed whole bodies to Floki. It now
  streams into a capped collector (default 5 MB, overridable via
  `ctx.deps[:web_fetch_max_bytes]` or `config :nous, :web_fetch_max_bytes`; a
  model-supplied `max_bytes` argument may only lower the ceiling, never raise
  it) and rejects anything that is not `text/html`, `application/xhtml+xml`, or
  `text/plain`. A missing `content-type` fails closed. The module previously
  had zero tests; its redirect re-validation, metadata-IP blocking, redirect
  cap, and relative-`Location` handling are now covered.

- **Dependency advisories cleared.** `mix deps.update req finch mint hpax ecto
  hackney` resolves req 0.6.3, finch 0.23.0, mint 1.9.3, hpax 1.0.4, hackney
  4.6.0, quic 1.7.1, ecto 3.14.1, decimal 3.1.1. This clears the two advisories
  reachable from production code — CVE-2026-49755 (Req decompression bomb,
  HIGH, reachable via `WebFetch`) and CVE-2026-56810 / CVE-2026-58229 (Mint
  HTTP/1 memory exhaustion, HIGH, on every provider call) — plus the hackney
  and QUIC advisories. No dependency requirement in `mix.exs` changed. The only
  remaining advisories reach the build through `bypass`
  (`only: [:dev, :test]`) and never ship to consumers.

- **`Nous.AgentServer` no longer amplifies its own PubSub traffic.** `init/1`
  subscribes the server to the topic it publishes on, and
  `Phoenix.PubSub.broadcast/3` does not exclude the sender — so the
  `handle_info` clauses that re-broadcast runner notifications received their
  own message and republished it, forever. Any app that actually set
  `config :nous, pubsub:` had one busy-looping process per agent (measured:
  ~1.2e8 reductions/s on an *idle* server) and unbounded duplicate events on
  every subscriber. `Nous.Agent.Callbacks.execute/3` already broadcasts every
  one of those events via the run context, so the five clauses
  (`:agent_delta`, `:tool_call`, `:tool_result`, `:agent_complete`,
  `:agent_error`) are now drains rather than publishers. No test configured a
  real PubSub with an `AgentServer`, which is why this never fired in CI; one
  does now.

- **OS-level confinement for tool subprocesses: `Nous.Sandbox`.** `Nous.Tools.Bash`
  handed the model `/bin/sh -c` as the OS user, with `Nous.Permissions` and
  approval as the only gate — nothing constrained what the shell touched once it
  was running, and `Nous.Tools.PathGuard` fences only the *file* tools. There is
  now a provider behaviour that wraps argv so the kernel enforces a policy, with
  `Nous.Sandbox.Seatbelt` (macOS `sandbox-exec`) and `Nous.Sandbox.Bwrap` (Linux
  bubblewrap) in tree. Three modes — `:read_only`, `:workspace_write`,
  `:danger_full_access` — set per agent (`Nous.new(..., sandbox: :workspace_write)`)
  or per run (`Nous.run(agent, prompt, sandbox: :read_only)`), or globally with
  `config :nous, :sandbox_mode`. `confine/2` is a pure argv builder; enforcement
  is data, and `Nous.Sandbox.classify/3` distinguishes "the OS denied a write"
  from "the sandbox runner broke and the command never ran" — the latter must
  never read as working confinement. With no usable provider the tool **refuses
  to run** rather than running unconfined.
  **The default is still `:danger_full_access`, with a one-time warning.**
  Fail-closed confinement is a behaviour change even though it is not an API
  change: `Bash` would stop working on any host without bubblewrap installed. The
  default will flip in a later release; opt in now with one line of config.
  Command hooks are deliberately *not* confined (they are operator-authored, and
  a hook that cannot write is not a hook) — opt in with
  `config :nous, :sandbox_confine_command_hooks, true`. `Nous.Tools.FileGrep` is
  a documented exemption: neither provider restricts reads, so confining a
  process that only ever reads adds no enforcement.

- **`Nous.Tools.PathGuard` no longer follows a symlink out of the workspace via
  `..`.** `resolve_real/1` began with `Path.expand/1`, which collapses `..`
  *lexically* before any symlink is resolved. With `link -> /etc` inside the
  workspace, `validate("link/../passwd", ctx)` expanded to `<root>/passwd`,
  passed the containment check, and was **accepted** — the resolver never saw the
  `..` it exists to catch. `validate/2` compounded it by handing the resolver the
  already-expanded path. The resolver now starts from `Path.absname/1` (absolute,
  `..` intact) and applies `.`/`..` to the already-*resolved* prefix, component by
  component, as the kernel does; `validate/2` passes it the uncollapsed path. The
  same traversal via `link/passwd` was already blocked, and benign in-workspace
  `..` still resolves. `resolve_real/1` is now public, shared with
  `Nous.Sandbox.writable_roots/1` — canonicalisation is load-bearing there too,
  since an SBPL `(subpath "/tmp")` clause never matches a write the macOS kernel
  sees as `/private/tmp/...`.

- **`Nous.Tools.Bash` was silently discarding every byte of stderr.** It ran
  under `NetRunner`'s default `stderr: :consume`, which reads stderr into an
  internal buffer with no accessor, so `run/2` returned stdout only: compiler
  errors, stack traces and permission failures never reached the model, which saw
  an exit code with no explanation. Output is now merged via
  `Nous.Sandbox.merge_stderr/1` (`/bin/sh -c 'exec "$@" 2>&1'`, argv passed
  positionally, so no quoting surface). Note that `NetRunner`'s documented
  `stderr: :redirect` option is not implemented in net_runner 1.0 and is worse
  than the default — it also disables the `:consume` drain, leaving an unread
  stderr pipe that deadlocks a child which writes more than a pipe buffer.

- **`Nous.Tools.Bash` never actually scrubbed its environment.** The tool passed
  `env: Nous.Tools.Env.scrubbed()` to `NetRunner`, which **has no `:env` option**:
  unknown options reach a port layer that ignores them and the shepherd
  `execvp`s, so the child inherited the BEAM's entire environment. For this
  tool's whole existence, one tool call — `{"command": "printenv"}` — returned
  every provider API key, OAuth token and vault credential in the VM, while the
  moduledoc claimed the opposite. Confinement could not have mitigated it: both
  sandbox providers are write fences and do not restrict reads or env.
  The environment now travels in **argv**, where it cannot be ignored:
  `Nous.Tools.Env.with_scrubbed_env/1` prefixes `/usr/bin/env -i` plus the
  allowlisted `NAME=VALUE` pairs (argv elements, so no shell parses them).
  `Nous.Tools.Env.scrubbed_overrides/0` fixes the sibling bug for
  `System.cmd/3` callers such as `Nous.Tools.FileGrep`: Erlang's `{env, _}`
  *merges* rather than replaces, so listing the allowlist left
  `OPENAI_API_KEY` in place — only `{name, nil}` removes a variable. Measured:
  the child's environment went from 73 names (including the secret) to 9.

- **`Nous.Tools.Bash` rejects a NUL byte in `command`.** The port layer
  *truncates* argv at a NUL rather than rejecting it, and a NUL renders as
  nothing in an approval prompt, an audit log or a terminal. So
  `git push origin main\0 --dry-run` was approved as a dry run and executed as a
  push — a bypass of the approval gate that AGENTS.md makes mandatory for this
  tool. `Nous.Sandbox.Policy` rejects a NUL in `workspace_root` for the same
  reason (it previously failed closed only by luck, by truncating the SBPL
  profile mid-string).

- **A real sandbox denial could be reported as a broken sandbox.**
  `Nous.Sandbox.classify/3` checks runner failure before denial, which is right,
  but macOS refuses a nested-sandbox escape with
  `sandbox-exec: sandbox_apply: Operation not permitted` — a line that satisfies
  the runner-failure signature *and* the denial signature. The escape was
  prevented, and the tool told the model "this is a broken sandbox … the
  command's effects did not happen and were not prevented". Both halves false.
  Three constraints now bound the classifier: exit 0 is always `:ok` (a denial
  fails the command, so `cat`ting a file that merely mentions a signature is no
  longer a denial — that was prompt-injectable); fatal signatures match only at
  the start of a trimmed line (a runner prefixes its own name; a mid-line
  mention is the command talking *about* the runner); and a line matching both
  kinds of signature is a **denial**. `Nous.Tools.Bash` also now *appends*
  verdicts to output instead of replacing it with an error — the classified
  stream is the command's own output, so replacing it let a forged verdict
  launder real side effects out of the transcript.

- **`Nous.Tools.PathGuard.resolve_real/1` refused legitimate deep paths.** The
  hop budget was spent by ordinary directory components, so a symlink-free
  34-deep path returned `{:error, :symlink_loop}` and `validate/2` reported a
  symlink loop that did not exist. It counts symlink **hops** now, the way
  `realpath(3)` counts them before `ELOOP`; loop detection is unchanged. This
  mattered beyond the confusing error: `Nous.Sandbox.Policy.canonical/1`
  swallows the error and falls back to the lexical `Path.expand/1` the resolver
  exists to avoid, so a deep workspace root silently produced a non-canonical
  SBPL `(subpath …)` that the kernel never matches — degrading
  `:workspace_write` to `:read_only`.

- **Sandbox hardening from the review pass.** `Nous.Sandbox.Policy` refuses
  `workspace_root: "/"`, which re-allowed the entire filesystem under
  `:workspace_write` while every log line still said "confined" — reachable by
  accident, since the root defaults to `File.cwd!/0`. `Nous.Sandbox.Bwrap` adds
  `--unshare-pid`: `--proc` without it leaves the host PID namespace, so
  `/proc/<other-pid>/root/…` resolves in a namespace where `/` is read-write,
  which is a write escape. Its unprobed executable default is now the absolute
  `/usr/bin/bwrap` rather than a bare name resolved through an inherited `PATH`
  full of user-writable directories. `Nous.Sandbox.Seatbelt` grants
  `/dev/stdout`, `/dev/stderr`, `/dev/tty` and `/dev/fd` — all denied before, so
  `cmd > /dev/stdout` and `tee /dev/stderr` failed on macOS while succeeding
  under bwrap. Both providers' `probe/1` now assert that a write outside every
  root is actually **refused**, instead of only proving the profile parses, and
  both denial-signature lists cover EACCES as well as EPERM/EROFS. Confined
  command hooks no longer fail **open**: with stdout-only capture the
  classification branches were structurally dead, so any nonzero exit under
  confinement is now `:deny` regardless of `fail_closed` — a security hook that
  never ran was silently permitting the event. A failed provider probe is no
  longer memoized (a 2s timeout on a busy host used to fail closed for the rest
  of the VM's life), and `Nous.Tools.Bash`'s cgroup path is flat because the
  shepherd's `mkdir` is not recursive, so the nested path it used could never be
  created and the cgroup containment was a silent no-op.

- **A saved session silently rewrote every tool-calling assistant message.**
  Found by the plan-03 regression gate before any refactor, in three layers that
  hid each other:
  `Nous.Message`'s changeset used Ecto's default `empty_values: [""]`, so
  `content: ""` was treated as *absent* and became `nil`. `Message.assistant/2`
  builds its struct directly and kept `""`, while `Message.new/1` dropped it — so
  the same logical message differed by which constructor made it, and
  `Context.deserialize/1` goes through `new!/1`. Every save/restore therefore
  rewrote the `content: ""` that a pure tool-call turn carries into `content:
  nil`, and providers distinguish the two, so a resumed session sent a different
  request shape than the one that was saved.
  Underneath that, `validate_content/1` rejected empty content outright, so once
  the coercion was removed, deserializing any transcript containing a tool call
  failed instead of merely corrupting it. Empty content is now valid for
  `:assistant` in both its forms (`""` for OpenAI/Gemini, `nil` for Anthropic),
  which is what a pure tool-call turn looks like and what streaming produces
  before the first delta.
  Underneath *that*, the Anthropic and Gemini response parsers manufactured `""`
  for content that was simply absent — masked until now by the very coercion
  above. They set the key only when it carries something, as the OpenAI parser
  already did, so "the model sent no content" is `nil` and "the model sent an
  empty string" is `""`, and the two are no longer conflated.

- **Compaction no longer destroys history.** `Nous.Agent.Context` is now backed by
  an append-only event log (`Nous.Session.Log`) whose model-visible surface is a
  pure fold. `ctx.messages` is materialized from that fold and kept in lockstep,
  so every existing reader — including `result.messages`, `result.all_messages`
  and `result.new_messages` — is byte-identical. The log is internal.
  What it buys immediately: `Nous.Plugins.Summarization` appends a
  `{:replace, start, stop}` event instead of rewriting the message list, so a
  summary *shadows* the range it replaces and every original event stays in the
  log. Its in-place tool-result pruning became a replace too — previously the next
  append re-materialized and silently resurrected the oversized results, undoing
  the pruning it had just done.
  Six sites wrote `%{ctx | messages: ...}` directly, which is what made
  "model-visible implies logged" decorative; all six now go through the log
  (`Plugins.Memory` and `Plugins.KnowledgeBase` carry a `source` marker so
  injected context is distinguishable from conversation, and
  `patch_dangling_tool_calls/1`'s synthetic results are events).
  `Context.serialize/1` is `version: 2` and persists events; a v1 blob still
  loads and seeds a log that folds back to its original messages.
  The plan's rule that an assistant event with empty content should be skipped in
  derivation was **dropped**: skipping it made `Context.last_message/1` and output
  extraction disagree with the log, turning a run whose model replied with empty
  content — a content filter, a `max_tokens` cutoff, a provider hiccup — from
  `{:ok, ""}` into `{:error, :no_output}`. "Providers reject an empty assistant
  turn" is a fact about what a *request* may contain; the fold is history and
  filters nothing.

- **The plugin system prompt no longer compounds across runs.** The per-request
  system-prompt rewrite is assembly-time state, applied as an idempotent overlay
  during materialization rather than written over the message list. Continuing one
  context across three runs used to append the plugin fragment to the system
  message three times.

- **You can talk to an agent mid-run.** `Nous.AgentServer.steer/2`, `inject/2` and
  `followup/2` are new public API on top of `Nous.Session.Inbox`, which has two
  ordered queues and one primitive with three presets: `followup` = next turn and
  wake, `steer` = next step and wake, `inject` = next step and **no wake**. That
  last distinction is the point: injected context waits for the next admitted
  request rather than starting one, so you can enrich an idle agent without
  provoking it. A message sent mid-run is claimed by the *next* step, not the one
  already in flight.
  `AgentServer` gained an explicit `run_state` so "is a run in flight" has one
  answer — it was previously spread across five handlers while an `async_nolink`
  task announces its end three different ways, which is too thin a basis for a
  wake decision. Cancellation behaviour is unchanged.

- **Turns and steps are durable events.** A step is one model request plus the
  tools it calls; a turn is zero or more steps. Both are logged, so a run is
  reconstructable after the fact: which turn a tool call belonged to, which step
  produced a request, where a crash landed. A zero-step turn is legal and is what a
  rejected input leaves behind. `pre_step` rejection reuses the existing
  `:pre_request` hook rather than adding a second mechanism, since a step *is* one
  request.

- **A crashed run no longer loses or invents history.** `Nous.Session.Recovery`
  repairs an orphaned `:turn_start` by **appending** — never deleting or rewriting —
  synthetic risk-classified `:tool_result` events plus a `:turn_end` with reason
  `:interrupted`, the one reason no live loop emits, so its presence is unambiguous
  evidence of a crash. Ambiguity always resolves to `:tool_outcome_unknown` rather
  than `:tool_not_started`: wrongly saying "may have run" costs a human one check,
  wrongly saying "did not run" is how a duplicate charge or a second `rm -rf`
  happens. Recovery is idempotent and leaves a clean log untouched.
  `Nous.Session.fork/2` copies an event prefix and records its parent, and
  **refuses a boundary inside an open turn** rather than clipping it.

- **Every committed event is broadcast**, so a LiveView can render from the log
  instead of from ad-hoc callbacks. Existing `Nous.PubSub` topics are reused; the
  publish is a no-op when no pubsub is configured, is driven by a count delta
  through the new `Log.since/2` (O(new), not O(log) — otherwise publishing would be
  quadratic over a session), and a broadcast failure cannot break an append.

- **`Nous.Session.Invariant`** checks that every model-visible request is
  reconstructable from the log, including an orphaned-tool-result pass for the
  provider-400 class that an unbalanced compaction range can still produce. It
  **warns and emits telemetry, never raises** (`config :nous, :session_invariant`
  promotes it to `:strict` for our own suite, or `:off`), because a legacy append
  path stays alive for at least one release and taking down a production run over a
  bookkeeping discrepancy would be the wrong trade.

### Performance

- **Oversized tool results can spill to a store instead of the context window.**
  A multi-megabyte `grep` result cost roughly a million tokens of context and was
  almost never read in full. New `Nous.Spill` behaviour with a filesystem backend
  (`Nous.Spill.Local`): results over `max_inline_bytes` (default 64 KB) are
  written out and replaced with a head+tail preview plus an opaque locator and
  the backend's own retrieval hint. `Nous.Tools.Bash`'s 1 MB truncation now keeps
  the bytes it captured instead of discarding them.
  Opt-in and best-effort by construction: with no `deps[:spill_config]` (or
  `config :nous, :spill`) behaviour is byte-for-byte unchanged, and a store error
  logs and keeps the result inline — spilling must never turn a successful tool
  call into a failure. `file_read` is excluded because spilling it creates a
  read→spill→read loop. Locators are opaque: callers render them with
  `retrieval_hint/1` rather than assuming a path a tool can open. Spilled files
  are `0o600` inside a `0o700` per-session directory, created exclusively so a
  planted symlink cannot redirect the write, and they **persist until the
  operator deletes them** — there is no reaper, by design.

- **Compaction prunes before it pays for a summary.**
  `Nous.Transcript.prune_tool_results/2` replaces any tool result over
  `max_result_chars` with head 4096 + a marker + tail 1024, with no LLM call at
  all. `Nous.Plugins.Summarization` now prunes first, re-measures, and skips the
  summarization request entirely when pressure has cleared — measured at a 90%
  estimated-token cut on a 50 KB tool result, which is the single largest saving
  in this release. Pruning only ever rewrites content in place, so it cannot
  reorder, drop, or split a `tool_call`/`tool_result` pair.

- **One compaction path, not two.** `Nous.Transcript` was public, correct, and
  entirely dead — nothing in `lib/` called it — while `Nous.Plugins.Summarization`
  carried a second, independent implementation of the tool-pair boundary rule that
  all three providers 400 on. `Summarization` is now the live entry point and calls
  `Transcript` for boundary balancing, pruning and estimation;
  `balance_tool_call_boundary/2` is public and is the only implementation left.

- **Compaction is observable and crash-detectable.**
  `[:nous, :compaction, :start | :stop | :exception]` telemetry carries message
  counts, byte counts (pruning never changes the count, so counts alone make a
  prune-only compaction look like a no-op), whether the LLM was called, and the
  summarization `provider`, `model` and usage — enough to reconstruct a compaction
  after the fact. The in-progress marker is cleared only *after* `:stop`, so a
  crash mid-compaction leaves a detectable orphaned `:start` rather than a false
  success.

- **Summarization reuses the provider's KV prefix cache.** It built a brand-new
  agent with different instructions and no tools, guaranteeing a cache miss on
  every compaction. It now replays the conversation's own system messages and
  tools verbatim, and keeps only the returned text — tool calls and reasoning are
  discarded, so a compaction can no longer produce an orphaned tool call, and a
  tool-call-only response is an error rather than an empty summary overwriting
  history.

- **Gemini/Vertex JSON-array streaming is no longer O(n²).** The
  `:stream_parser` buffer was re-walked byte-by-byte from position 0 on every
  arriving chunk, so one large object spread across many chunks cost quadratic
  time. `parse_buffer/2` now accepts and returns a resumable
  `{pos, depth, in_string}` scan state that both stream backends thread through
  their buffer state; `parse_buffer/1` is unchanged for the SSE default and any
  third-party parser. Measured over the report's shape (one object, 1400-byte
  chunks): 3/14/59/243 ms at 60/120/240/480 KB becomes 0/0/1/8 ms — **27-30x at
  the larger sizes**, and linear rather than quadratic. The median path (many
  small objects) is unchanged. Resume is byte-identical to a full rescan,
  pinned by a test that splits 14 adversarial inputs at *every* byte boundary,
  including a lone trailing backslash inside a string — the one case where a
  naive resume diverges.

- **The Req stream backend now bounds buffered bytes, not message count.** The
  guard capped the consumer mailbox at 1000 messages while never inspecting
  chunk size, so resident memory was roughly 1000 x chunk size. It now tracks
  bytes through a shared `:atomics` counter with an 8 MB high-water mark and
  parks the producer in a `receive` instead of polling. A/B measurement
  streaming 100 MB to a deliberately slow consumer: peak binary memory 23.9 MB
  bounded vs 108.5 MB unbounded, and the bounded peak is flat in stream size
  where the unbounded one grows linearly. This also removes a cross-process
  `Process.info/2` call that ran on every chunk, and a `Process.sleep/1`
  busy-wait.

- **Decisions graph traversal is linear again.** Both BFS frontiers in
  `Nous.Decisions.Store.ETS` used `queue ++ [node]`, which silently defeated
  the adjacency index built directly above them. Now `:queue`. Star graph:
  20/74/284 ms at V=4000/8000/16000 becomes 4/10/19 ms (**14.8x at V=16000**),
  scaling ~2x per doubling instead of ~4x. Reachable set and emission order
  are unchanged.

- **Knowledge-base link queries push filters into the match spec.**
  `backlinks/2`, `outlinks/2`, `link_counts_by_source/1` and `related_entries/3`
  each `tab2list`'d the entire links table, and `related_entries/3` applied its
  limit only after fetching every neighbour. Over 20,300 links: 7.1x, 6.7x,
  5.7x and 3.3x respectively. `related_entries/3` still returns up to `limit`
  entries that actually exist — it fills lazily rather than truncating before
  dangling links are rejected, so the dangling-link behaviour is preserved.

- **Default `count_tokens/1` no longer inspects every message.** It used
  `inspect |> String.length` (measured ~13,000x slower than necessary) where
  the internal estimator already used `byte_size`. Both now agree.

- **`Teams.SharedState` reads run in the caller.** The table was `:private`,
  forcing every read through the GenServer. It is now `:protected` with
  `read_concurrency: true`, and `get_discoveries/1` / `get_claims/1` select
  directly. Eight concurrent readers over 1,000 discoveries: 713 ms serialized
  vs 203 ms concurrent. Discoveries also now expire on the same
  `Process.send_after` mechanism claims already used, via a new
  `:discovery_ttl` option (default 1 hour, accepts `:infinity`) — previously
  they accumulated for the lifetime of the process.

- **`AgentServer.save_context/1` no longer blocks the agent process.**
  Serialization and backend IO move to a task, mirroring `:load_context` which
  was already offloaded. The call remains synchronous *for the caller* — the
  reply is sent after the backend write returns — so the "the save has landed
  when this returns" guarantee is unchanged; only the server stops blocking.

- **`Persistence.ETS` is bounded** rather than growing without eviction, and
  the global Finch pool is configurable instead of hard-capping the node at 10
  connections per provider — which directly throttled the concurrency
  `parallel_tool_calls` exists to enable.

- Missing `read_concurrency` / `write_concurrency` flags added to the ETS
  tables whose access pattern warrants them (not blanket-applied — the flags
  cost memory and hurt single-writer tables).

### Added

- **Code Mode: the model can write a program that calls tools, instead of a chain
  of individual tool calls.** One `run_code` call carries a generated typed SDK
  declaring every tool in scope; the program loops, branches and fans out in a
  single round trip, and only what it logs or returns re-enters the conversation.
  A 10-sub-call fan-out completes in 244ms where a serial chain of the same work
  needs 400ms plus ten model round trips.

  `Nous.CodeRuntime` is the provider behaviour, and `Nous.CodeRuntime.JS` is the
  shipped provider: an embedded V8 isolate (Deno via Rustler NIFs) behind the
  optional `{:tyrex, "~> 0.4"}` dependency, one **fresh isolate per run** so no
  state carries over. Budgets are provider configuration, never per request, so a
  program cannot negotiate its own deadline: `:timeout_ms` enforced by a BEAM
  timer that really terminates the isolate, `:max_heap_mb`, and a byte-accurate
  `:max_output_bytes` ledger that keeps the fitting prefix.

  Isolation is stated exactly rather than marketed: it is in-process, so a V8
  escape is an escape into the BEAM. What it does enforce is no filesystem,
  network, env or subprocess access, and no route into Elixir except the tools you
  granted — the runtime's arbitrary-module bridge is narrowed to one function and
  then removed from the isolate before any model-authored code runs. There is
  deliberately **no instruction budget**, because this substrate has no fuel
  metering; the wall-clock kill is the only bound on a compute-bound program and
  it is a real one.

  `mode: :both` is the default and degrades to `:native` when no runtime is
  configured, rather than advertising a `run_code` that can only fail. It is **not
  an unconditional token saving** — the SDK is a prompt prefix that can rival the
  native schemas it replaces — so `docs/guides/code_mode.md` says to measure your
  own workload instead of implying a win.

- **`Nous.Usage.cost/2` and `Nous.Usage.Pricing`.** `%Usage{}` counted tokens and
  priced nothing, so no caller could answer what a run cost. Prices are per 1M
  tokens with separate input, output, cache-read and cache-write rates, keyed by
  `{provider, model}`, with a longest-family-prefix fallback on a `-` boundary so
  `gpt-4o-2026-05-13` finds `gpt-4o` while an unreleased generation stays
  `:unknown` rather than inheriting a stale rate. Unknown models return
  `{:error, :unknown_model}` — never a guess. Local providers (ollama, lmstudio,
  vllm, sglang, llamacpp) are explicitly zero. Override or extend the table with
  `config :nous, :model_prices`.
  Cost is **derived, not stored**: no `cost` field on `%Usage{}`, because a price
  table changes independently of the run and a stale number persisted in the
  struct would be worse than no number. Prices are a snapshot recorded
  2026-08-14 and will go stale; the override config is the fix.

### Changed

- **LM Studio's default `receive_timeout` is 5 minutes, up from 2.** LM Studio
  JIT-loads a model on the first request that names it, so "slow first token on
  cold weights" — the reason `:llamacpp` already had 5 minutes — is the *default*
  behaviour there, not an edge case: loading an 18GB 27B took 21s before a single
  token appeared. Generation is slow too; one tool-calling step with three tools
  measured 36.7s for 515 completion tokens, and a loop's later steps carry bigger
  contexts than its first. At 2 minutes that surfaced mid-run as a bare
  `%Req.TransportError{reason: :timeout}`, which reads like a broken server rather
  than a budget the caller can raise. `:vllm` and `:sglang` are the same class of
  host and were left alone because they were not measured. Override per model with
  `receive_timeout:` as before.

- **`llama_cpp_ex` updated to `0.8.44`** (from `0.8.22`) and verified against real
  GGUF models: the four functions this library calls — `init/0`, `load_model/2`,
  `chat_completion/3`, `stream_chat_completion/3` — are unchanged, and the tagged
  `--only llama` suite passes on two different local models, covering chat,
  streaming, `enable_thinking: false`, grammar-constrained JSON and embeddings.
  Tool calling is still absent upstream, so the provider's "not supported by this
  backend" behaviour is unchanged. `req`, `ecto` and `elixir_make` were
  deliberately *not* moved with it: `mix deps.update llama_cpp_ex` pulls them
  opportunistically, none is required by 0.8.44, and req is the default HTTP
  backend for every provider.

- **`Nous.HTTP.Buffer` extracted.** Both stream backends reached up into
  `Nous.Providers.HTTP` for buffer helpers, making the transport layer depend
  on the provider layer — the one genuine (non-benign) runtime cycle in the
  graph. The helpers now live in `Nous.HTTP.Buffer`; `Nous.Providers.HTTP`
  keeps delegating wrappers, so nothing external breaks. Runtime cycles drop
  from 7 to 6; compile-time cycles remain 0.

- **`Nous.AgentRunner`'s 199-line orchestration loop** moved out of the facade
  into a new internal Nous.AgentRunner.IterationLoop, alongside the four
  submodules added in 0.17.0. Pure move: the public API and every telemetry
  event are unchanged.

- **`AGENTS.md`'s "What NOT to use" list corrected.** It declared several
  modules private that are in fact documented plug-in points —
  `Nous.HTTP.Backend.*` and `Nous.HTTP.StreamBackend.*` are behaviours with a
  published guide, `Nous.Providers.HTTP` is injected into every provider by
  `use Nous.Provider`, `Nous.AgentRunner` holds the canonical option docs that
  `Nous.Agent` points at, and `Nous.AgentServer` is used throughout the
  LiveView guide. Those are now documented as public. Only
  `Nous.Workflow.Engine.{Executor,ParallelExecutor,StateMerger}` were genuinely
  internal; they gain `@moduledoc false` and leave the docs groups.

- **`Nous.Plugins.KnowledgeBase` honours a caller-supplied `:store_state`.**
  `init/2` called `store_mod.init/1` unconditionally, discarding any store
  passed in config, so an agent configured against a pre-populated knowledge
  base searched an empty one. It now mirrors the `:store_state` reuse guard
  `Nous.Plugins.Memory` has always had. **Behaviour change:** a
  `kb_config[:store_state]` that used to be ignored is now used.

- **`Nous.Util` is `@moduledoc false`.** The module described itself as
  "internal" while carrying a visible `@moduledoc`, which under this project's
  own mechanical rule (`@moduledoc false` == private, everything else is
  semver-covered API) made it public. It is now hidden, matching both its own
  description and `AGENTS.md`. Its doctests still run.

- **`Nous.Hook`'s `@type event` union was incomplete.** It omitted
  `:workflow_start`, `:workflow_end`, `:pre_node` and `:post_node`, all four of
  which `Nous.Workflow.Engine` dispatches. Type-only change.

- **`Nous.AgentRegistry.via_tuple/1` and `lookup/1` accept any registry key.**
  The specs said `String.t()`, but `Nous.Teams.Coordinator` has always
  registered members under a `{:team, team_id, member}` tuple. Spec-only
  change, now expressed as `t:Nous.AgentRegistry.key/0`.

### Tests

- **Provider request shaping is now asserted.** `Nous.Providers.Gemini` sat at
  4.35% coverage and `Anthropic` at 4.76% — message *translation* was well
  covered, but nothing checked the URL, auth headers, or body of an outgoing
  request. That is exactly how the malformed Gemini tool payload above shipped
  green. New `gemini_test.exs`, `anthropic_test.exs` and `openai_test.exs`
  decode the real request inside a Bypass plug and assert path, method, auth
  header, system-prompt placement, and tool schema per dialect. The Gemini file
  explicitly refutes the OpenAI `"type"` / `"function"` envelope keys inside
  `functionDeclarations`, so that specific regression cannot recur. Coverage:
  Gemini 4.35% → 91.30%, Anthropic 4.76% → 85.71%.

- **Write-tool sandbox escapes are now tested.** `FileRead` had an escape test;
  `FileWrite` and `FileEdit` did not, so deleting their `PathGuard.validate/2`
  call would not have failed anything — and a write escape is strictly worse
  than a read escape. Both now have absolute-path and `../../` traversal tests
  that also assert the target file was not created or modified, and the real
  `Nous.Tools.Bash` is tested for approval refusal via a filesystem side effect
  that must not happen. Each new protection test was verified to fail under a
  targeted mutation of the `lib/` line it defends.

- **The 17 `AgentServer` cancellation tests now run in CI.** They were
  `@moduletag :llm`-excluded, so the only cancellation coverage was a trivial
  `{:ok, :no_execution}` assertion — cancel-while-running, double-cancel,
  cancel-then-restart and multi-agent isolation were all unverified. They now
  use stub dispatchers that signal readiness, so cancellation is triggered at a
  provably-parked point instead of after a `Process.sleep`. Whole suite: 0.1s.

- **Tests no longer reach the public internet.** Several tests issued live
  requests to `api.openai.com` and `aiplatform.googleapis.com` and passed only
  because they asserted on the resulting error — slow, broken offline, and if
  `OPENAI_API_KEY` were ever set in CI they would have made real billed calls
  with different behaviour. The two Vertex region tests additionally never
  checked the thing they were named for; they now assert the resolved URL
  directly. Full-suite wall time dropped from ~9s to ~6.4s.

- **A process-scoped dispatcher seam** (`Nous.ModelDispatcher.put_dispatcher/1`,
  resolved through `$callers`) lets tests inject a stub without mutating
  application environment. Precedence is explicit option → process override →
  app env → default, pinned by a test. 12 files moved from `async: false` to
  `async: true` (39 → 30 sync). Files driving `Nous.AgentServer` stay sync and
  say why: `$callers` does not cross `GenServer.start_link`.

- **`Nous.ReActAgent`'s own tools declared no parameters, so the agent could not
  work.** All six — `plan`, `note`, `add_todo`, `complete_todo`, `list_todos`,
  `final_answer` — were built with `Tool.from_function/2` passing only `name:` and
  `description:`, so the schema fell back to an empty object. Measured: every one
  reached the model with `properties: []` and `required: []`, while their
  descriptions promised parameters in prose ("Parameter: answer (your complete
  solution)").

  A model that honours the schema therefore called them with `{}`. `final_answer`
  returned the literal string `"No answer provided"`, and `note`/`final_answer` —
  which pattern-match on `%{"content" => _}` and `%{"answer" => _}` — raised
  `FunctionClauseError` instead. The loop retried calls that could never succeed
  until it ran out of iterations, which is what made ReAct look like a
  model-capability problem. All six now carry real schemas, and those two functions
  answer a schema-violating call with a sentence naming the missing parameter
  rather than raising, because models do ignore schemas and a crash teaches them
  nothing.

- **The ReAct prompt contained an obligation that could never be discharged.**
  "Complete all pending todos before calling `final_answer`" makes every
  `add_todo` create a new prerequisite for finishing, so a task whose deliverable
  *is* a todo list can never be answered — measured as
  `{:error, %MaxIterationsExceeded{}}` on "make a todo list for learning Elixir,
  then answer with the list", having done the work and never being allowed to
  report it. Completing todos is now advised rather than required, and the prompt
  states plainly that an answer with pending todos beats running out of steps.

- **`Nous.ReActAgent` defaults to 25 iterations rather than the generic 10.** Its
  mandated workflow is plan (1) + one `add_todo` per step + `note` observations +
  one `complete_todo` each + `final_answer` (1), so a four-step task needs 11
  iterations before it is permitted to answer. The agent could not follow its own
  instructions inside the default budget.

  Together these take the `:eval` ReAct suite from 1 of 11 to **11 of 11 on two
  different local models** — a 4B in 155s and a 27B in 793s — where before the fixes
  the suite spent 25 minutes mostly timing out. `7.1` answers `"8"` to "What is 5
  plus 3?" instead of `"No answer provided"`.

- **`Nous.Transcript.estimate_messages_tokens/1` was blind to tool-call
  arguments, so no token budget could see a tool-calling transcript.** It summed
  `Message.extract_text/1`, which returns content only. Measured exactly: a
  102,000-byte payload counted as 25,500 tokens when carried as message content
  and as **0 tokens** when carried as tool-call arguments — the same payload
  serialises to 102,137 bytes on the wire either way. Arguments are now counted as
  encoded JSON, which brings the estimate to 25,503 against that 25,534-token
  wire size.

  This is the root cause behind the ReAct blow-ups below, and it silently weakened
  every consumer of the estimate: compaction thresholds, spill decisions and
  `should_compact?/2`. It bit hardest on the agents that need a budget most,
  because a tool-using agent keeps its payload in `arguments` by definition.

- **`Nous.ReActAgent` enables context management by default.** ReAct's defining
  feature is looping, which makes it the one agent shape that must not be handed
  an unbounded transcript. `Nous.Plugins.Summarization` is now on by default with
  `max_context_tokens: 30_000, keep_recent: 8`; passing your own `plugins:` or
  `summarization_config` replaces it entirely.

  Enabling it costs nothing on the common path — the plugin prunes oversized tool
  results for free and only pays for a summarization if still over budget. On one
  "plan the area of a rectangle" task against a local model, measured end to end:

  | | peak request | outcome |
  |---|---|---|
  | before | 170,732 tokens | refused by the server (32k window) after 775s |
  | trigger fixed | 46,809 tokens | still refused, 203s |
  | + estimator fixed | **4,866 tokens** | completed, 3 iterations, 19.8s |

  The `:eval` ReAct suite went from ~1 to **7 of 11** passing on a 4B local model,
  with zero context-size rejections. The remainder is throughput, not capability
  or context: the same test measured 27s and >180s minutes apart because the model
  loops a variable number of times, and a *larger* model is worse rather than
  better — a 27B Q8 generates at ~13 tokens/sec, so one ReAct-shaped request took
  72.7s and a request near the 30,000-token ceiling exceeded even a 5-minute
  per-request budget. 648 of its 956 completion tokens were reasoning, and
  `enable_thinking: false` was ignored by that model, so two thirds of the
  generation is invisible overhead for an agent already being told to reason.

- **Race-hiding sleeps replaced with real synchronisation**, wall-clock
  concurrency assertions replaced with a structural in-flight counter asserting
  the maximum is *exactly* the expected concurrency (a `<=` bound also passes
  for a fully sequential implementation), and several tests that could not fail
  for their stated reason were fixed or deleted.

- `Nous.Messages` doctests re-enabled (7 → 23 doctests total). Dead `:mox`
  dependency removed; `bypass` narrowed to `only: :test` so a Cowboy server is
  no longer on the `:dev` code path.

- **CI now enforces test coverage.** Total went 56.80% → ~60%, and the gate is
  a ratchet at 59 rather than an aspiration — the 90% threshold configured in
  `mix.exs` was never run by any job, and was additionally mis-nested:
  `:threshold` must sit under `:summary` or Mix silently keeps its default.

- **Credo thresholds ratcheted** to the tightest values the codebase passes
  today (`max_complexity` 24 → 23, `max_arity` 15 → 14) so they can only move
  down. `max_nesting` was already at its floor.

### Fixed

- **`Nous.Plugins.Summarization` never bounded the context window.** Its trigger
  read `ctx.usage.total_tokens` — the cumulative bill for the run, every input
  and output token of every request summed — instead of the size of the transcript
  about to be sent. That measured the wrong thing in both directions: a long
  conversation of small requests crossed the threshold while its context was still
  tiny and then compacted on *every* subsequent request forever, because a bill
  never decreases; while a run whose context genuinely exploded was not compacted
  at all. Reproduced with no LLM involved: a transcript of ~300,000 estimated
  tokens configured with `max_context_tokens: 5_000` came back byte-identical, 13
  messages in and 13 out, because nothing had been billed yet. The trigger is now
  `Nous.Transcript.estimate_messages_tokens/1` over `ctx.messages`, so the
  threshold means what its name says and matches every other token budget here.

  Found by driving `Nous.ReActAgent` against a local model: with no context
  management it grew one task to a **170,732-token request against a 32,000-token
  window** before the server refused it with a 400, and the earlier symptom was a
  stream of `%Req.TransportError{reason: :timeout}` as each request got slower.
  Enabling the plugin now cuts the peak on that task to 46,809 tokens. It still
  does not fit the window: `:keep_recent` messages are exempt from pruning, so a
  few large recent tool results can exceed any budget by themselves, and
  `Nous.ReActAgent` ships with no context management of its own — a task it cannot
  converge on will still outgrow the context.

  Every existing test in this plugin's suite triggered compaction by supplying a
  large fake `usage.total_tokens` on a *small* transcript, which is why the defect
  survived; a test now drives it from transcript size with `usage` at zero.

- **A tool could not declare its own deadline, so `Nous.Tools.Bash` was killed
  at 30s while documenting and granting 120s.** `%Nous.Tool{}` has always had a
  `:timeout`, but the `tool/3` macro in `Nous.Tool.Schema` accepted no such
  option and `Nous.Tool.from_module/2` hardcoded the 30-second struct default,
  so a schema-defined tool's own budget could never reach the executor.
  Measured: `Nous.Tool.from_module(Nous.Tools.Bash).timeout` was `30_000` while
  the tool passes `120_000` to `NetRunner` and exposes a `timeout` parameter a
  model can set to `120_000` — a legitimate 45-second command died at 30
  seconds, twice (see Security, above), and the documented 2-minute default was
  unreachable. `tool/3` now takes `:timeout`, carried through `metadata/0` into
  `from_module/2` on exactly the path `requires_approval` already uses, with an
  explicit `from_module(mod, timeout: …)` still winning. `Nous.Tools.Bash`
  declares a deadline five seconds *above* the command budget it grants, so its
  own timeout fires first and reports "Command timed out after 120000ms"
  instead of an opaque outer kill; a `timeout` argument may only lower that
  budget, never raise it past the deadline. The other schema-defined built-ins
  keep the 30-second default, which their work cannot plausibly exceed.

- **Structured output silently did nothing on Gemini and Vertex AI.**
  `Nous.OutputSchema.to_provider_settings/2` emits the OpenAI-nested
  `response_format: %{"type" => "json_schema", "json_schema" => %{"schema" => …}}`
  and `resolve_mode(:auto, :gemini)` is `:json_schema`, but
  `Nous.Messages.Gemini` only matched the *flat* `%{"type" => …, "schema" => …}`
  shape. Every `output_type:` agent on `gemini:` / `vertex_ai:` therefore sent
  no `responseMimeType` and no `responseSchema` at all, and relied entirely on
  the model guessing JSON. Both shapes are now accepted.

- **Every `Nous.Eval.Optimizer` objective except `:score` and `:pass_rate`
  raised.** `extract_metric/2` and `extract_all_metrics/1` used
  `get_in(suite_result, [:metrics_summary, :latency, :p50])`; `%SuiteResult{}`
  and `%Metrics.Summary{}` are plain structs with no `Access` implementation,
  so that raised `UndefinedFunctionError` rather than returning nil — and the
  nested `:latency` / `:tokens` / `:cost` keys never existed on the summary
  anyway. They now read the real summary fields, and a suite with no metrics
  summary (every case errored) yields `0.0` instead of crashing the search.

- **`Nous.Agent.Context` dropped the prompt-cache token counters.**
  `add_usage/2`'s map branch, `serialize_usage/1` and `deserialize_usage/1` all
  omitted `cache_creation_input_tokens` and `cache_read_input_tokens`, so
  persisting and resuming a context zeroed them and any cache-aware cost
  calculation under-reported after a restore.

- **`Nous.Agent.Behaviour.call/4` skipped optional callbacks on unloaded
  modules.** It used a bare `function_exported?/3`, which answers false for a
  module that has not been loaded yet — routine under interactive code loading.
  A behaviour module that really did implement `init_context/2` or
  `after_tool/4` silently got the default instead. Now guarded with
  `Code.ensure_loaded?/1`.

- **`Nous.Memory.Store.Hybrid` raised instead of erroring when its optional
  deps are absent.** The deps-unavailable branch defined `init/1` and
  `search/3` but not `search_vector/3`, so the friendly `{:error, _}` path was
  an `UndefinedFunctionError`.

- `Nous.Workflow.run/3`'s `@spec` omitted the `{:suspended, state, info}`
  return the engine can produce, and its `@doc` omitted the `:hooks`, `:trace`,
  `:scratch`, `:pause_ref` and `:on_node_complete` options it forwards.

- **Gemini and Vertex AI tool calls from the agent path shipped a malformed
  payload.** `Nous.AgentRunner` fell through to the OpenAI tool schema for
  `:gemini` / `:vertex_ai`, so the request carried
  `[%{"functionDeclarations" => [%{"type" => "function", "function" => …}]}]`
  — an OpenAI envelope nested inside Gemini's `functionDeclarations`, which
  expects the bare declaration. `Nous.LLM` had a second, *correct* copy of the
  same conversion, which is why one-shot calls worked while agent runs did not.
  The duplicate is deleted and both paths now share
  `RequestDispatch.convert_tools_for_provider/2`, using the Gemini shape. Any
  agent using tools with Gemini or Vertex was affected.

- **`Nous.LLM.generate_text/3` no longer returns `""` for multimodal replies.**
  Its private `extract_text/2` copy returned `""` for any non-binary content;
  it now uses `Nous.Message.extract_text/1`, which walks list content.

- **A hung tool can no longer wedge an entire agent run.** The parallel
  tool-call path passed `timeout: :infinity` with no `on_timeout` to
  `Task.Supervisor.async_stream_nolink/4`, relying on `ToolExecutor` to enforce
  per-tool timeouts — but that timer is only armed when `tool.timeout` is a
  positive integer, and `nil` is permitted. The stream now uses a finite
  ceiling derived from the batch (each tool's own timeout times its retry
  budget, plus headroom; five minutes when a tool declares none) with
  `on_timeout: :kill_task`. A timed-out call returns a per-call tool error and
  its siblings keep their real results.

- **`Nous.Message.ContentPart` accepts whitespace-only text under Ecto 3.14.**
  Ecto 3.14 moved trimming out of `:empty_values` into a separate
  `:trim_values` option defaulting to true, so the `empty_values: [""]`
  override stopped protecting the Gemini/Vertex `"\n\n\n"` case. Empty-content
  rejection is now an explicit check in `validate_content/1`, giving identical
  behaviour across Ecto 3.11-3.14.

- **Transport errors are logged again under Req 0.6.** The error clause in
  `Nous.HTTP.Backend.Req` matched only `%Mint.TransportError{}`; Req 0.6
  surfaces `%Req.TransportError{}`, so the clause went dead and transport
  failures fell through to the generic handler. Both structs are handled.

### Documentation

A full pass over `docs/`, `examples/`, `README.md`, `AGENTS.md` and
`CONTRIBUTING.md`. The rot was semantic, not structural: `mix docs` built with
zero warnings the whole time, because nothing in CI read `examples/` or the
code fences in the guides.

- **New: a regression guard.** `test/docs/api_reference_test.exs` parses every
  `examples/**/*.exs` and every Elixir code fence in the docs, resolves each
  `Nous.*` remote call and struct literal against the loaded beam
  (alias-aware, including `alias Nous.{A, B}`, pipes, captures and default
  arities), and fails on an unknown module, function, arity or struct field.
  It also asserts every fence parses — deliberate fragments are allowlisted by
  `{file, line, reason}` in `test/docs/fixtures/doc_snippet_allowlist.exs`,
  and an allowlist entry that has started parsing fails too — and that every
  relative markdown link and `#anchor` resolves. A `docs` CI job runs
  `mix docs --warnings-as-errors`.

- **14 broken examples fixed** — calls to functions that do not exist
  (`AgentServer.subscribe/1`), fields that do not exist (`usage.iterations`,
  `SuiteResult.test_results`, `Result.test_case.id`), an unsupported
  `"provider:model@base_url"` model string, an EEx block `PromptTemplate`
  deliberately rejects, two LiveView scripts that could not compile, and four
  memory examples that raised `MatchError` instead of naming the optional dep
  to uncomment. `12_pubsub_agent.exs` ran on a hand-rolled stub that delivered
  nothing and cost four 30-second timeouts; it now runs on a real
  `Phoenix.PubSub`.

- **15 misleading examples corrected** — most notably the streaming and
  callback examples, which registered `on_llm_new_delta` without `stream: true`
  and therefore never streamed, and every bare anonymous function passed as a
  tool (which the model sees under a compiler-mangled name with an empty
  parameter schema).

- **Wrong facts corrected across the guides** — README receive-timeouts (60s/
  120s claimed; 180s cloud, 120s local, 300s llamacpp actual), the vLLM
  base_url contract, the `nous:`-prefixed AgentServer topic, `generate/2` vs a
  nonexistent `generate_output/2`, and several snippets that were outright
  syntax errors — including *the* custom-memory-store template, whose five
  callbacks each had a comment where their body should be.

- **Features that shipped undocumented are now documented** —
  `parallel_tool_calls`, `Nous.Hook`'s `fail_closed`, InputGuard's
  `fail_closed` / `strategy_timeout`, the twelve Gemini/Vertex model settings
  from 0.16.0, and the `Nous.Usage` prompt-cache token fields.
  `docs/guides/migration_guide.md` was a rewrite: it described 0.1.x–0.4.x of a
  different library and was ~40% Kubernetes boilerplate.

- **New:** `docs/guides/transcript.md`, three Livebook notebooks under
  `notebooks/` (linked from the README with "Run in Livebook" badges and
  published to hexdocs), and five examples —
  `advanced/distributed_agents.exs` (agents across two nodes, one killed
  mid-run, supervisor restart, persisted context recovered),
  `20_sql_generation.exs`, `advanced/cost_aware_routing.exs`,
  `advanced/rag_documents.exs` and `advanced/streaming_backpressure.exs`.
  All five run offline and exit 0 with no API key.

- **Doctests went from 3 wired modules to 32.** 210 doctests now execute; they
  previously read well and ran never. Several were pseudo-code that could not
  evaluate (whole-struct literals compared against a `created_at` stamped at
  build time, `[...]` placeholders, `File.read` of a path that does not exist)
  and were rewritten to actually run.

### Removed

- **`:inets` dropped from `extra_applications`.** `:httpc` was replaced by Req;
  the entry only forced inets to boot in every downstream release.

## [0.17.0] - 2026-07-18

### Added

- **Opt-in parallel tool-call execution** — `parallel_tool_calls: true` on
  `Nous.Agent.new/2` (default `false`). When a model response contains multiple
  tool calls, approved executions fan out under `Nous.TaskSupervisor` while
  everything order-sensitive stays sequential in call order: `pre_tool_use`
  hooks and approval checks run before the fan-out, and `post_tool_use` hooks,
  `on_tool_response` callbacks, behaviour `:after_tool`, and
  `Context.merge_deps` apply after it, in original call order. Result messages
  keep call order (providers require it). Per-tool timeouts remain
  `ToolExecutor`'s job (no second outer timeout); a crashed task surfaces as a
  per-call tool error instead of sinking the turn. Off by default because tools
  may rely on sequential external side effects within one turn — note that
  tools already cannot observe each other's context updates within a turn (the
  run context is snapshotted before the tool loop).

- **LM Studio live smoke suite** (`test/nous/lmstudio_smoke_test.exs`,
  `:llm`-tagged, excluded by default) — one live test per runner path: plain
  run, sequential tool loop, `parallel_tool_calls`, and the public
  `run_stream/3` (previously uncovered by any live test). Model-agnostic
  assertions safe for thinking models; verified against LM Studio.

### Changed

- **`Nous.AgentRunner` split into a facade + four submodules.** The
  2,188-line / 97-function module is now a 926-line facade delegating to
  internal (`@moduledoc false`) submodules under `Nous.AgentRunner`:
  `PromptAssembly` (prompt/settings assembly), `Streaming` (stream
  wrapping/consumption), `RequestDispatch` (fallback chains, rate limiting,
  provider settings), and `ToolExecution` (sequential/parallel tool
  execution, hooks, approval/policy enforcement).
  Move-only: the public API (`run/2,3`, `run_with_context/2,3`,
  `run_stream/2,3`) and all telemetry events are unchanged.

- **Internal dedup/refactor sweeps** (#66, #67): repeated logic across
  providers, tools, and errors single-sourced; struct references adopt
  `alias __MODULE__`. No behavior change.

### Fixed

- **`run_stream/3` no longer emits a duplicate empty `{:complete, _}`
  event.** OpenAI-compatible streams yield two `{:finish, _}` events (the
  `finish_reason` chunk plus the end-of-stream marker) and the result
  wrapper emitted a `{:complete, _}` for each — the second with empty
  output. Consumers now get exactly one, carrying the accumulated output.

- **`Nous.Message.extract_text/1` no longer crashes on `content: nil`.**
  Thinking models truncated mid-reasoning return assistant messages with
  only `reasoning_content` set; extraction now returns `""` instead of
  raising `FunctionClauseError` and failing the whole run.

- **Optional-dep compile warnings in consumer builds silenced.**
  `Nous.Tools.SearchScrape` is now gated on Floki (like `WebFetch`), and
  `:hackney`/`:hackney_pool` are declared `no_warn_undefined` — apps that
  depend on nous without the optional `floki`/`hackney` packages compile
  without warnings.

- **Audit follow-ups** (#68): atom leaks, secret redaction, and O(n²)
  knowledge-base stats.

## [0.16.6] - 2026-06-27

### Changed

- **Agent-runtime hot-path hardening (behavior-preserving)** (#62). Eliminates
  confirmed super-linear and serialization hot paths in the agent runtime,
  measured with Benchee first; all changes preserve observable behavior. Core
  loop: tool-schema conversion is memoized once per run via a runtime-only
  `Context.tool_schema_cache` and stripped from `Context.serialize/1`.
  Persistence/OTP: `agent_server` context saves on the response/`clear_history`
  paths are now fire-and-forget via `Task.Supervisor` (off the GenServer
  mailbox); `Teams.RateLimiter` uses running-window counters so `rate_limited?/2`
  is O(1); `Teams.SharedState` uses ETS row-per-entry for discoveries/claims.
  Context updates replace O(n²) `++ [item]` appends with prepend + per-key
  reverse. Memory/search: scope/kb_id/type filters are pushed into ETS via
  matchspecs, search is single-pass, and the SQLite cosine L2 norm is hoisted
  out of the loop.

### Documentation

- **Documentation overhaul** (#63). ExDoc structure reorganized after months of
  feature growth: 67 previously-orphaned modules are now grouped, with new module
  groups (Multi-Agent/Teams, Decision Graph, Messages & Streaming, HTTP Backends,
  Structured Output, Utility Tools, Mix Tasks), a completed Providers group, and
  an expanded Evaluation subtree; 0 broken-link warnings. Seven new
  source-grounded subsystem guides (teams, decisions, research, fallback,
  permissions, observability, providers). README/getting-started/indexes updated
  and stale doc indexes regenerated. Numerous broken examples fixed and four new
  advanced examples added (teams, decisions, deep_research, fallback).

## [0.16.5] - 2026-06-12

### Security

- **Permission-policy approval gate was bypassed when a `pre_tool_use` hook
  modified arguments.** In `AgentRunner`, the `{:modify, …}` hook branch ran the
  tool through `check_tool_approval/3` without first applying
  `enforce_policy_approval/2` (unlike the normal path). A tool gated *only* by
  the permission policy (`:strict` mode, an `approval_required` entry, or the
  execute-category gate) — not by its own `requires_approval` flag — therefore
  executed UNGATED whenever any `pre_tool_use` hook rewrote its arguments. The
  modify branch now applies policy approval identically to the allow branch.
- **InputGuard now fails closed on dropped strategies.** Under the default
  `aggregation: :any`, a strategy that errored or timed out was silently dropped;
  if it was the only real detector, flagged input passed as `:safe`. Dropped
  strategies now upgrade an otherwise-`:safe` verdict to `:suspicious`
  (configurable via `fail_closed`, default `true` for `:any`, `false` for
  `:majority`/`:all` which already count drops against the configured
  denominator). Drops emit a `[:nous, :input_guard, :strategy_dropped]` telemetry
  event + a `Logger` warning. New `:strategy_timeout` option (default 30s) bounds
  the parallel path. **Behavior change:** an `:any` guard with a flaky strategy
  may now warn/block where it previously passed — set `fail_closed: false` to
  restore the old behavior.
- **`:permissive` policy no longer auto-approves execute-class tools.**
  `Nous.Permissions.requires_approval?/3` (category-aware) keeps the approval
  gate on `category: :execute` tools (e.g. `bash`) even under `:permissive`,
  unless the policy sets `allow_unattended_execute: true`. Built-in `bash` was
  already self-gated via its own `requires_approval: true`; this closes the gap
  for custom execute-class tools that relied on the policy. **Behavior change:**
  `build_policy(mode: :permissive)` users who want unattended shell execution
  must now pass `allow_unattended_execute: true`.

## [0.16.4] - 2026-06-05

### Changed

- **Audit-pass follow-up: security/OTP/test hardening** (#60). Security
  hardening: PathGuard canonical-path resolution, `web_fetch` fail-closed,
  atom-exhaustion DoS guard, ReDoS cap, additional UrlGuard ranges. Correctness:
  `get_tool_field` fetch, rate-limit TOCTOU fix, async-load reply-on-crash,
  `async_nolink` absorb, O(1) claims, iodata flat accumulation. Documents the
  intentional run-scoped ETS ownership model (KnowledgeBase/Decisions stores)
  and a safer slug-index write order, makes the rate-limiter fail-open
  observable (log + telemetry), and improves test quality (deterministic
  `refute_receive`, `start_supervised!`, unique telemetry handler IDs, encoded-IP
  SSRF cases).

## [0.16.3] - 2026-05-29

### Security

- **RCE approval gate could be silently bypassed.** `Nous.Tool.from_module/2`
  hardcoded `requires_approval: false` instead of reading it from the tool's
  metadata, so `Bash`/`FileWrite` registered via the standard path ran without
  the human-approval gate — one prompt-injected document from RCE. It now falls
  back to metadata like name/description/parameters. (Also fixed:
  `Nous.Tool.Behaviour.implements?/1` ensures the module is loaded before
  checking, and `Nous.Agent.new/2` accepts bare behaviour modules in `:tools`.)
- **FileGrep ripgrep flag injection.** LLM-controlled `pattern`/`glob` reached
  `rg` with no `--` option terminator, so values like `-f/etc/passwd` or
  `--pre=…` read files (or ran a preprocessor) outside the workspace. Pattern is
  now passed via `--regexp`, glob via `--glob`, with `--` before the positional
  path; the pure-Elixir fallback re-validates every matched file (mirrors
  `FileGlob`).
- **PathGuard intermediate-directory symlink escape.** Only the final path
  component was `lstat`'d, so a directory symlink (`link -> /etc`, accessed as
  `link/passwd`) escaped the workspace jail. `Nous.Tools.PathGuard` now resolves
  symlinks across every existing component (realpath) and compares the canonical
  path against the canonical root (also robust to symlinked roots like macOS
  `/tmp`).
- **SSRF hardening in `Nous.Tools.UrlGuard`.** Now blocks IPv4-mapped IPv6
  (`::ffff:169.254.169.254`), NAT64 (`64:ff9b::/96`), link-local `fe80::/10`,
  and `::`, and resolves both A and AAAA records (dual-stack bypass). New
  `validate_pinned/2` returns a validated IP; `Nous.Tools.WebFetch` pins the
  connection to it (preserving Host header, SNI, and cert verification) to close
  the DNS-rebinding TOCTOU. The Req provider backends pass `redirect: false`.
- **Permission policy is now actually enforced.** `Nous.Permissions.Policy`
  (via a new `:permissions` option on `Nous.Agent.new/2`) filters blocked tools out
  of the tool list the model sees and forces the approval gate for
  approval-required tools — previously the engine was never consulted at
  runtime. `blocked?/2` now honors allow lists in every mode (deny-by-default),
  `build_policy/1` rejects unknown modes, and both predicates fail closed on an
  unknown mode.
- **InputGuard no longer bypassed for streaming.** `Nous.AgentRunner.run_stream/3`
  runs the plugin pipeline and short-circuits to a terminal blocked stream
  before any LLM call. The LLMJudge strategy fences untrusted input in a random
  boundary, parses only the first `VERDICT` line, and can fail closed on an
  unparseable response; the Pattern strategy NFKC-normalizes and strips
  zero-width/bidi characters; `:majority`/`:all` aggregation counts the
  configured strategies so killing one can't flip the vote.
- **Secret & data-exposure hygiene.** Credential-shaped `deps` keys
  (`api_key`/`token`/`secret`/…) are no longer written by persistence; Gemini
  sends its key via the `x-goog-api-key` header instead of the URL query string;
  the default telemetry handler logs a bounded status+body summary instead of
  the raw upstream error term; the persistence and workflow-checkpoint ETS
  tables are `:protected` (owner writes, any process reads) instead of `:public`.

### Fixed (critical)

- **Anthropic responses with 2+ text or thinking blocks crashed the turn.**
  `consolidate_content_parts/1` returned a list into the `:string` content
  field, raising `Ecto.InvalidChangesetError` on common multi-block responses
  (text around a tool_use, multi-paragraph answers). Now joins homogeneous
  blocks into a string (mirrors the Gemini path).
- **AgentServer added the user message to the context twice per turn.** The
  message was added in `handle_cast` and again by `AgentRunner.build_context`,
  doubling the prompt sent to the model and corrupting saved history. Now added
  exactly once.
- **`Nous.LLM` streaming-with-tools never reassembled tool-call fragments.**
  It treated each `{:tool_call_delta, _}` as complete — crashing for OpenAI
  (Access on a list) and invoking tools with nil args for Anthropic. Now feeds
  fragments through `Nous.StreamNormalizer.ToolCallAccumulator`.
- **OpenAI `parse_tool_call/1` crashed on a tool_call missing `"function"`.**
  `Map.get(nil, "name")` raised `BadMapError`, aborting the whole response
  parse on non-conformant OpenAI-compatible backends. Defaults to `%{}` now.

### Fixed (important)

- **Team region locking and discovery sharing were silently inert.**
  `Nous.Teams.Supervisor` wires `SharedState` into agent deps as a registered
  atom name, but `Nous.Plugins.TeamTools` gated on `is_pid/1` — false for the
  name — so `claim_region`/`share_discovery` no-op'd for every team built via
  the public API. The guards now resolve a registered name to a live pid.
- **A tool that `throw`s or `exit`s (non-timeout) crashed the whole agent run.**
  `Nous.ToolExecutor` only caught `:exit, {:timeout, _}`; it now catches any
  `throw`/`exit` and converts it to a retryable `ToolError`.
- **Streaming Gemini/Vertex tool calls dropped `thought_signature`.** The
  accumulator rebuilt the call without `metadata`, breaking multi-turn thinking
  parity for 2.5 thinking models. The signature is now carried through.
- **Documented per-run `:model_settings` override was ignored.** `AgentRunner`
  now merges `opts[:model_settings]` over the agent's settings for that run.
- **`Nous.Teams.RateLimiter` was never invoked**, so `budget`/`rpm`/`tpm` had no
  effect. It is now wired into the agent request path (reserve → reconcile →
  release) when a limiter is in deps; rpm/tpm/request limits are enforced (the
  cost budget is reconciled post-hoc — see the moduledoc).
- **Crashed/timed-out parallel workflow branches were attributed to
  `"unknown"`.** `Nous.Workflow.Engine.ParallelExecutor` now uses
  `zip_input_on_exit` so failures keep their branch id / item index.
- **SQLite memory scoped FTS recall was silently broken** (a parameter
  off-by-one bound the scope filter to the wrong columns); the **Hybrid store**
  now over-fetches a larger candidate pool when a scope is applied (so in-scope
  results aren't crowded out); and **memory search normalizes RRF scores to
  0–1** so `min_score` behaves consistently between text-only and hybrid modes.
- **Tool argument validator now recurses** into nested object properties and
  array items (was top-level types only).
- **Eval config robustness.** `NOUS_EVAL_*` integer env vars parse via
  `Integer.parse` (no crash on a bad value) and a partial custom `cost_config`
  deep-merges instead of raising `KeyError`.
- **`Nous.Tools.SearchScrape` processed only the first `concurrency` URLs.**
  It now fetches all URLs (capped and throttled by `max_concurrency`) and clamps
  LLM-supplied `concurrency`/`timeout`.

### Changed

- **`Nous.Agent.new/2` accepts bare tool modules** in `:tools` (e.g.
  `tools: [Nous.Tools.Bash]`), converted via `Nous.Tool.from_module/1`.
- **`Nous.Permissions.blocked?/2` allow-list semantics.** A non-empty
  `allow_names`/`allow_prefixes` is now deny-by-default in every mode (was only
  honored in `:strict`); `build_policy/1` raises on an unknown `:mode`.
- **`Nous.Hook.new/2` accepts `:fail_closed`** so security-gating hooks can opt
  into fail-closed via the documented constructor (not only a struct literal).
- **License metadata corrected** to `Apache-2.0` in `mix.exs` (was `MIT`) to
  match the bundled `LICENSE` and README.
- **Docs:** fixed non-compiling/silently-broken examples — README plugin
  configs now pass `:deps` to `Nous.run/3` (not `Nous.new/2`, which ignores it);
  getting-started uses `Nous.Errors.ProviderError`, the correct
  `AgentDynamicSupervisor.start_agent/3` arity, `Context.deserialize/1`, and
  `%Nous.Message{}` for the chatbot example; AGENTS.md custom-tool example uses
  `@behaviour`/`metadata/0`/`execute(ctx, args)` and corrects the streaming
  backpressure claim (Req is the default; Hackney is the opt-in pull-based
  backend).

### Performance

- **Removed O(n²) list accumulation on hot loops.** `Nous.Teams.RateLimiter`'s
  sliding window and `Nous.Teams.SharedState`'s discovery list now prepend
  (O(1)) instead of `++ [entry]` (O(n)).
- **KnowledgeBase ETS store keeps a `slug -> id` index**, so
  `fetch_entry_by_slug/2` is O(1) instead of a full table scan + struct rebuild
  on every `kb_read`/`kb_backlinks`/`kb_link` call.
- **Decisions ETS store builds an edge adjacency index once per BFS traversal**
  (`descendants`/`ancestors`/`path_between`) instead of scanning the whole edge
  table per visited node — O(V+E) instead of O(V·E).

## [0.16.2] - 2026-05-16

### Fixed (critical)

- **Gemini/Vertex tool-result roundtrip was broken.** `Nous.Messages.Gemini`
  was sending the tool call_id (e.g. `"gemini_abc123"`) as the
  `functionResponse.name`, but Gemini's API requires the original
  `functionCall.name`. Every Gemini tool roundtrip shipped a malformed
  payload. `Message.tool/3` now threads the original name through the
  `:name` field; agent_runner and llm pass it at every call site.
- **OpenAI tool-call malformed JSON used to be passed to the tool as bogus
  args.** `Nous.Messages.OpenAI.decode_arguments/1` now returns
  `{:ok, map()} | {:error, {:invalid_json, raw}}`. Parsers tag the
  tool_call with `"_invalid_arguments"`; AgentRunner short-circuits with a
  proper tool-error result so the LLM can retry.
- **Workflow checkpoint ETS table lost its data when the saving process
  exited.** The `:nous_workflow_checkpoints` table is now owned by a
  supervised `TableOwner` under Nous.Application (mirrors the existing
  `Nous.Persistence.ETS` pattern). Every suspended workflow relying on
  resume is now durable to caller exits.
- **Memory plugin re-initialized its ETS store on every agent run.**
  Nous.Plugins.Memory.init/2 now reuses the existing `store_state` when
  present; per-run defaults are still refreshed. Avoids
  `ets_too_many_tables` under load and the silent loss of memories across
  runs.
- **`Nous.LLM.stream_text_with_tools` silently halted on dispatcher error.**
  Now emits an `{:error, reason}` event before halting so consumers can
  detect LLM failures on the streaming + tools path.
- **AgentServer subscribed to the wrong PubSub topic.** It used
  `"agent:#{session_id}"` while `Nous.PubSub.agent_topic/1` returned
  `"nous:agent:#{session_id}"` — anyone publishing via the helper never
  reached the server. Now uses the helper.
- **AgentServer didn't cancel its in-flight task on shutdown.** Streaming
  LLM calls kept consuming tokens and HTTP connections after the server
  was already gone. `terminate/2` now sets the cancellation atomic and
  calls `Task.shutdown`.
- **Research coordinator crashed on task exit.** `Task.yield` returns
  `{:exit, reason}` on task crash; the `case` only matched `{:ok, _}` /
  `nil` and produced `CaseClauseError`. Now handles `{:exit, _}` with
  `{:error, {:task_exit, _}}`.

### Fixed (important)

- **Anthropic + Gemini usage parsing dropped requests count and cache
  tokens.** Now sets `requests: 1` (was always 0) and captures
  Anthropic's `cache_creation_input_tokens` /
  `cache_read_input_tokens` and Gemini's `cachedContentTokenCount`.
  `Nous.Usage` gained `cache_creation_input_tokens` and
  `cache_read_input_tokens` fields, which propagate through `add/2`.
- **Tool validator dropped the `enum` constraint when `type` was also
  declared.** `Nous.Tool.Validator.validate_types/2` now runs every
  constraint independently — a schema `%{"type" => "string", "enum" =>
  ["a","b"]}` properly rejects values outside the enum.
- **Hooks can now opt into fail-closed semantics.** `Nous.Hook` gains a
  `fail_closed: boolean()` field. When set on a hook bound to a blocking
  event (`:pre_tool_use`, `:pre_request`), runtime errors deny the action
  instead of silently failing open — so a broken security-gating hook
  can't be bypassed. Default `false` keeps existing behavior.
- **Streaming Gemini tool calls had `id: nil`.** Stream and non-stream
  paths now both synthesize a `"gemini_<base64>"` id.
- **Bumblebee embedding serialization removed.** `ServingHolder` no longer
  runs `Nx.Serving.run/2` inside `handle_call`. Concurrent embeddings now
  go through the serving's own batching mechanism instead of serializing
  through one process.
- **Bare `Task.async` migrated to supervised `Task.Supervisor.async_nolink`**
  in `research/coordinator.ex`, `eval/runner.ex`, `tools/search_scrape.ex`,
  `plugins/input_guard.ex`, and `http/stream_backend/req.ex` — so a
  crashed sub-task no longer takes down its caller (and vice-versa), and
  graceful shutdown can signal in-flight work.
- **Default Req streaming backend gains backpressure.** The producing
  Task watches the consumer's `message_queue_len` before each `send/2`;
  past `@backpressure_high_water` it pauses until the queue drops below
  `@backpressure_low_water`, and after `@backpressure_max_wait_ms` it
  emits `{:error, %{reason: :backpressure_overflow}}` and halts. The
  M-12 risk called out in `mix.exs`.
- **AgentRegistry partitioned across schedulers** (was `partitions: 1`).
  High-concurrency LiveView lookups no longer serialize on a single
  partition.
- **AgentServer's persistence load moved to `handle_continue`.** `init/1`
  returns immediately, so `DynamicSupervisor.start_child` (and
  `Teams.Coordinator.spawn_agent`) no longer wedge waiting for slow
  persistence backends.

### Changed

- **Telemetry events reconciled.** The documented-but-never-emitted events
  `[:nous, :agent, :iteration, :start/:stop]`, `[:nous, :context, :update]`,
  and `[:nous, :callback, :execute]` are now actually emitted. The
  unreached `[:nous, :provider, :stream, :chunk]` was removed from the
  docs and default handler (per-chunk telemetry is too hot for the
  streaming path). Existing-but-undocumented events
  (`fallback`, `hook`, `skill`, `workflow`) are now documented in the
  `Nous.Telemetry` moduledoc.

### Deprecated

- `Nous.ToolSchema.to_openai/1` — use `Nous.Tool.to_openai_schema/1`.
- `Nous.Agent.tool/3` — use `Nous.Agent.new/2` with `:tools`, or build a
  `%Nous.Tool{}` directly.
- `Nous.Eval.run!/2` — match `Nous.Eval.run/2`'s
  `{:ok, _} | {:error, _}` result.
- `Nous.Decisions.path_between/4`, `descendants/3`, `ancestors/3` —
  call `store_mod.query(state, ..., ...)` directly.

### Internal / Hygiene

- `mix compile --warnings-as-errors` is clean. Removed unreachable
  `Vertex AI validate_project_id(nil)` clause; tightened
  `Nous.Research.Planner.plan/2` spec to `{:ok, plan()}` and dropped the
  unreachable `{:error, _}` clause in `research/coordinator.ex`.
- `Nous.Workflow.Checkpoint.ETS` and `Nous.Plugins.Memory` now expose
  proper supervised / reusable lifecycle (see Fixed).
- `Nous.Memory.Store.SQLite` FTS5 escape now doubles embedded `"`
  characters per FTS5 syntax — queries containing `"` no longer error.

## [0.16.1] - 2026-05-15

### Changed (breaking)

- **Provider error contracts.** `Nous.Providers.LMStudio`, `Nous.Providers.SGLang`,
  `Nous.Providers.VLLM`, and `Nous.Providers.Custom` now return
  `{:error, {:invalid_config, reason}}` instead of raising `ArgumentError`
  when the resolved `base_url` is missing or fails `Nous.Tools.UrlGuard`
  validation. `Nous.Providers.LlamaCpp` similarly returns
  `{:error, %Nous.Errors.ProviderError{}}` instead of raising when the
  `:llamacpp_model` option is missing.

  Callers that wrapped these calls in `try/rescue ArgumentError` should
  switch to pattern matching on `{:error, _}`. The high-level
  `Nous.run/2`, `Nous.generate_text/3`, and `Nous.Agent.run/3` paths
  already returned result tuples and are unaffected.

- **Vertex AI token resolution prefers Goth over `VERTEX_AI_ACCESS_TOKEN`.**
  When a `:goth` instance is configured (in opts or app config),
  `Nous.Providers.VertexAI` now uses Goth exclusively for that request,
  and surfaces Goth failures as `{:error, %{reason: :goth_error, ...}}`.
  Previously, a Goth failure would silently fall through to the env var,
  producing confusing 401s when the env var was stale or missing.
  If you relied on env-var fallback while Goth was misconfigured, you
  will now see the Goth error directly — that's the intended behavior.

### Fixed

- **Tool args of the wrong type no longer crash `Nous.Tools.StringTools`.**
  `replace_text`, `split_text`, `count_occurrences`, `contains` previously
  chained `Map.get(args, "k1") || Map.get(args, "k2") || ""` to support
  aliased keys. When the LLM handed back a non-string value (e.g.
  `"pattern" => 123`), the value flowed straight into `String.replace/3`
  and crashed the tool call. Args are now extracted via a typed helper
  that falls back to the default when the value isn't a binary.

## [0.16.0] - 2026-05-10

A significant Gemini-on-Vertex upgrade. Most of the new surface lands as
`Nous.Messages.Gemini` helpers + small `build_request_params/3` wiring on
both `Nous.Providers.VertexAI` and `Nous.Providers.Gemini`, so anything new
works against either entry point.

### Added

- **Thinking config (request-side).** New `:thinking_config` setting maps to
  `generationConfig.thinkingConfig`, letting callers set `thinking_budget`
  and `include_thoughts` on Gemini 2.5/3.x. Both Elixir shape
  (`%{thinking_budget: 1024, include_thoughts: true}`) and native Vertex
  shape (`%{"thinkingBudget" => 1024, "includeThoughts" => true}`) are
  accepted.
- **`thoughtSignature` round-trip on tool calls.** `Nous.Messages.Gemini`
  now preserves Vertex's `thoughtSignature` on parsed tool calls (under
  `tool_call["metadata"]["thought_signature"]`) and echoes it back when
  serializing assistant turns. Without this, multi-turn thinking + tool
  loops on Gemini 2.5/3.x degrade or fail because the next turn lacks the
  required signature. The streaming normalizer also propagates the
  signature on `{:tool_call_delta, ...}` events.
- **Structured output (JSON schema).** New `:json_response` and
  `:json_schema` settings wire to `responseMimeType` /  `responseSchema`
  in `generationConfig`. The cross-provider `:response_format` shape
  (`%{type: :json_schema, schema: ...}` and `%{type: :json_object}`) maps
  through too.
- **Safety settings.** `:safety_settings` flows to top-level
  `safetySettings`, with atom-keyed entries auto-stringified.
- **Tool config / tool choice.** `:tool_config` (raw map) and `:tool_choice`
  (friendly form) both flow to top-level `toolConfig`. Friendly forms:
  `:auto`, `:any` / `:required`, `:none`, and `{:any, ["fn_a", ...]}` for
  `allowedFunctionNames`.
- **Function calling on Vertex/Gemini actually works.** Function
  declarations are now serialized in Vertex's `tools[].functionDeclarations`
  format via `Nous.ToolSchema.to_gemini/1` (which strips OpenAI's `strict`
  field and unsupported `additionalProperties` from the parameters
  schema). Previously the high-level `Nous.LLM` path silently dropped
  tools for these providers.
- **Native Vertex tools.** New `:native_tools` setting accepts
  `:google_search`, `:url_context`, `:code_execution` atoms (or
  `{tool, config}` tuples / raw maps) and adds them as additional entries
  in the Vertex `tools` array, alongside any function declarations.
- **Context caching.** `:cached_content` setting maps to top-level
  `cachedContent`. Pass-through only — create caches via the Vertex REST
  API for now.
- **Streaming + tools.** `Nous.LLM.stream_text/3` now honors `:tools`.
  Tool-call deltas are aggregated per turn (preserving any
  `thoughtSignature`), tools execute between turns, and the conversation
  continues until the model stops calling tools or hits
  `@max_tool_iterations`. Text deltas are still yielded to the caller as
  they were produced.
- **More `generationConfig` fields:** `topK` ← `:top_k`, `seed` ← `:seed`,
  `candidateCount` ← `:candidate_count`, `presencePenalty` ←
  `:presence_penalty`, `frequencyPenalty` ← `:frequency_penalty`,
  `responseModalities` ← `:response_modalities`.

### Changed

- **Single timeout source of truth.** Removed the separate
  `@streaming_timeout` constants from `Nous.Providers.VertexAI` (300s) and
  `Nous.Providers.Gemini` (120s). Streaming and non-streaming now share
  the same provider default; the actual timeout used at request time is
  always `model.receive_timeout`, which flows through
  `build_provider_opts/1` as `:timeout`. Override via
  `Model.parse(..., receive_timeout: ms)`.

## [0.15.8] - 2026-05-06

### Fixed

- **Vertex AI / Gemini whitespace text parts no longer crash the
  request pipeline.** Gemini occasionally returns `text` parts whose
  content is only newlines (e.g. `"\n\n\n"`) — typically between tool
  calls or as filler when the model is blocked. Ecto's default
  `:empty_values` for `cast/3` treats whitespace-only strings as
  empty, so `Nous.Message.ContentPart`'s changeset dropped the
  `content` field entirely and then raised
  `%Ecto.InvalidChangesetError{errors: [content: {"content is required",
  []}]}` from `ContentPart.new!/1`, taking down the whole
  Nous.LLM.run_with_tools/6 call. `ContentPart` now overrides
  `:empty_values` to `[""]` so legitimate whitespace content is
  preserved, and Nous.Messages.Gemini.parse_content/1 defensively
  skips whitespace-only text parts to avoid creating useless
  `ContentPart`s. The streaming normalizer (`Nous.StreamNormalizer.Gemini`)
  already had this guard; the non-streaming path is now consistent.
- **Nous.Messages.Gemini.parse_content/1 no longer silently drops
  function calls without `args`.** Nullary tool calls
  (`%{"functionCall" => %{"name" => "get_time"}}`) were falling into
  the catch-all clause and disappearing. Pattern now requires only
  `name` and falls back to `%{}` for `args`, matching the behavior of
  the sibling `parse_parts/1` helper.

### Added

- **`Nous.Errors.RetryInfo`** parses server-suggested retry hints from
  provider error responses. Checks `error.details[]` for
  `google.rpc.RetryInfo` (Vertex AI / Gemini) first, then the
  `Retry-After` HTTP header. Returns delay in milliseconds, or `nil`
  when no hint is available — `nil` is itself meaningful for Google
  APIs, since long-term/daily quota exhaustion deliberately omits
  `RetryInfo` to discourage retry loops.
- **`Nous.Errors.ProviderError` gains `:retry_after_ms`** alongside
  the existing `:status_code`. Nous.Provider.request/3 and
  `request_stream/3` now populate both fields automatically when the
  underlying HTTP layer returns an error tuple, so callers can branch
  on rate-limit hints without parsing provider-specific bodies:

  ```elixir
  case Nous.LLM.run_with_tools(...) do
    {:error, %Nous.Errors.ProviderError{retry_after_ms: ms}} when is_integer(ms) ->
      {:snooze, ms}                     # use server-suggested delay
    {:error, %Nous.Errors.ProviderError{status_code: 429}} ->
      {:snooze, exp_backoff(attempt)}   # rate-limited, no hint
    ...
  end
  ```

- **Gemini/Vertex `finishReason` and `promptFeedback` are surfaced.**
  `Nous.Messages.Gemini.from_response/1` now stores both in
  `message.metadata` (when present) and emits a `Logger.warning` when
  the candidate produced empty content for a non-STOP reason
  (`SAFETY`, `RECITATION`, `MAX_TOKENS`, etc.) or when the prompt was
  blocked. Previously these signals were discarded, so blocked
  generations manifested as silent empty messages with no diagnostic.

### Changed

- **HTTP error tuples now carry response headers.**
  `Nous.HTTP.Backend.Req`, `Nous.HTTP.Backend.Hackney`, and
  `Nous.HTTP.StreamBackend.Req` previously returned
  `{:error, %{status, body}}` and dropped headers entirely, which made
  it impossible to read `Retry-After`. They now return
  `{:error, %{status, body, headers}}` with `headers` as a list of
  `{name, value}` tuples (lowercased per HTTP spec, both string).
  Existing pattern matches on `%{status: _, body: _}` continue to work
  since map matching is non-exhaustive.
- **Gemini tool-call ID generation unified.**
  Nous.Messages.Gemini.parse_content/1 previously used
  `"gemini_#{:rand.uniform(10_000)}"` (~50% birthday-paradox collision
  at ~118 calls) while `parse_parts/1` used
  `"call_#{:rand.uniform(1_000_000)}"` — two formats, two ranges. Both
  now share a `generate_tool_call_id/0` helper using 64 bits of
  `:crypto.strong_rand_bytes/1`, base64url-encoded with the
  `gemini_` prefix preserved.

## [0.15.7] - 2026-05-05

### Changed

- **`hackney` is now an optional dependency.** Req (default for both
  one-shot and streaming) is the primary HTTP backend; `hackney` is only
  used when a consumer opts into `Nous.HTTP.Backend.Hackney` /
  `Nous.HTTP.StreamBackend.Hackney` via `NOUS_HTTP_BACKEND=hackney`
  (or the streaming variant) or app config. Forcing `hackney ~> 4.0` as
  a hard dep (added in 0.15.x) broke downstream apps with any
  transitive constraint of `hackney ~> 1.20` (e.g. `aws ~> 1.0`'s
  optional dep), since the resolver activated the optional constraint
  once hackney 4 entered the graph. Apps that use the hackney backend
  now declare `{:hackney, "~> 4.0"}` in their own `mix.exs`.

## [0.15.6] - 2026-05-05

### Fixed

- **Gemini / Vertex AI multi-part responses no longer crash
  `Message.new!/1`.** When a Gemini candidate contained more than one
  `text` (or `thought`) part — common on long `gemini-2.5-pro` outputs
  such as multi-thousand-token translations — `from_response/1` passed
  the raw list of `ContentPart` structs to `Nous.Message`, whose
  `:content` field is `:string`. Ecto then raised
  `%Ecto.InvalidChangesetError{errors: [content: {"is invalid",
  [type: :string, validation: :cast]}]}`. `consolidate_content_parts/1`
  now joins homogeneous lists of `:text` or `:thinking` parts into a
  single string. Vertex AI is fixed implicitly via the existing
  `:vertex_ai → from_gemini_response/1` delegation in
  `Nous.Messages.from_provider_response/2`.

## [0.15.5] - 2026-05-01

### Fixed

- Both Req-based HTTP backends (`Nous.HTTP.Backend.Req` and
  `Nous.HTTP.StreamBackend.Req`) now actually use the configured
  `Nous.Finch` pool. Previously they ignored the `:finch_name` opt
  built by `Nous.Provider` and let Req spin up its own default Finch
  instance, leaving the supervised `Nous.Finch` pool (started by
  Nous.Application with `size: 10, count: 1`) idle. Both backends
  now read `:finch_name` from per-call opts, falling back to
  `Application.get_env(:nous, :finch, Nous.Finch)`. Net effect:
  `Nous.Finch` becomes the live default for both streaming and
  non-streaming on Req, so pool tuning via app config actually takes
  effect. (Note: Req disallows passing `:finch` together with
  `:connect_options`; connect timeouts are now pool-level — configure
  on the `Nous.Finch` pool itself if a non-default is needed.)

### Changed

- **Default timeouts increased to 3 minutes (180_000 ms) across the
  board.** The previous 60s default routinely tripped on reasoning
  models and longer completions. Affected:
  - `Nous.Model` `receive_timeout` default → 180_000
  - Nous.Model.default_receive_timeout/1 per-provider:
    cloud/custom → 180_000, llamacpp → 300_000 (up from 120_000)
  - Provider `@default_timeout` (OpenAI, Anthropic, Mistral, VertexAI,
    OpenAICompatible) → 180_000
  - Provider `@streaming_timeout` (Anthropic, Mistral, VertexAI,
    OpenAICompatible) → 300_000 (up from 120_000)
  - HTTP backend defaults (Req + Hackney, both streaming and
    non-streaming) → 180_000

  Per-call `:timeout` / `:receive_timeout` opts continue to override.

## [0.15.4] - 2026-05-01

Pluggable streaming HTTP backends + hackney 4 pull-mode bug fix.

### Fixed

- **Hackney 4 streaming was silently in push mode, not pull mode.**
  `lib/nous/providers/http.ex:463-470` (in 0.15.0–0.15.3) passed
  `[:async, :once, ...]` as separate atoms to `:hackney.request/5`.
  Erlang's `proplists` resolves bare atom `:async` as `{:async, true}`,
  which puts hackney into push mode; the bare `:once` atom is silently
  ignored. The architectural intent of M-12 (strict pull-based
  backpressure so a slow consumer cannot grow its mailbox) was
  forfeited — `:hackney.stream_next/1` is a no-op in push mode, so the
  receive loop appeared to work in many cases (chunks arrive in the
  same shape) but the pacing came from the producer, not the consumer.
  The fix is the tuple form `[{:async, :once}, ...]` per
  `deps/hackney/NEWS.md:269-272`. Empirical confirmation: with the
  broken form a benign Bypass server delivers 97 messages to the
  caller's mailbox in 2 s without any `stream_next/1` call; with the
  tuple form the mailbox holds only 2 messages (status + headers) and
  body chunks gate on `stream_next/1`. Reported as part of the same
  bug that caused observable timeouts against cold/slow SSE backends.

### Added

- **`Nous.HTTP.StreamBackend` behaviour** — pluggable streaming HTTP
  layer mirroring the non-streaming `Nous.HTTP.Backend` introduced in
  0.15.1. Two impls ship:
  - `Nous.HTTP.StreamBackend.Req` — the new default. Drives
    `Req.post/1` with the `:into` callback. Simpler stack
    (Req/Finch/Mint), marginally faster TTFB than hackney in
    benchmarks against LMStudio (~130 ms vs ~133 ms mean).
  - `Nous.HTTP.StreamBackend.Hackney` — opt-in. Strict pull-based
    backpressure via `:hackney`'s `[{:async, :once}]` mode (the bug
    above is fixed here). Pick this when downstream consumers can
    block per chunk (LiveView fan-out under load,
    persistence-on-every-chunk, slow IO).
- **`:stream_backend` per-call opt** on `Nous.Providers.HTTP.stream/4`.
- **`NOUS_HTTP_STREAM_BACKEND` env var** (`req` | `hackney` |
  `My.Custom.Backend`). Resolution mirrors `NOUS_HTTP_BACKEND`:
  per-call → env → app config → default.
- **`config :nous, :http_stream_backend, MyBackend`** application
  config knob.

### Changed

- `Nous.Providers.HTTP.stream/4` now dispatches to the configured
  `Nous.HTTP.StreamBackend` instead of inlining hackney plumbing. The
  public API surface (return shape, event types, error tuples) is
  unchanged. Provider stream normalizers (`Nous.StreamNormalizer.*`)
  consume normalized events and need no changes.
- The non-streaming pluggable `Nous.HTTP.Backend` resolver is
  refactored to share its `String.to_existing_atom/1` safety logic with
  the streaming resolver — same C-2 protection on both paths.

### Documentation

- `Nous.Providers.HTTP` moduledoc rewritten around the dual
  pluggable-backend model and the streaming backpressure trade-off.
- `Nous.HTTP.StreamBackend` and the two impl modules carry full
  moduledocs explaining when to pick each.

### Migration

No code changes required for callers — the default behavior is
restored to "streaming works against any healthy SSE backend." Apps
that depend on strict pull-based backpressure should set:

    config :nous, :http_stream_backend, Nous.HTTP.StreamBackend.Hackney

or pass `stream_backend: Nous.HTTP.StreamBackend.Hackney` per call.

## [0.15.3] - 2026-05-01

Streaming + tool execution. The `Nous.Agent.run/3` loop now has a
`stream: true` opt that combines per-token deltas with the regular
tool-call loop. Behavior is identical to non-streaming `run/3` except
for the additional streaming events: same final result, same callbacks,
same fallback chain, same hook/plugin pipeline.

### Added

- **`:stream` option on `Nous.Agent.run/3`** — runs the iteration loop
  with the LLM call streamed. Per-iteration assembly produces a
  `%Nous.Message{}` structurally identical to what the non-streaming
  path returns, so `:on_llm_new_message`, `process_response`,
  `handle_tool_calls`, and the loop continuation are all unchanged.
  Per-token `:on_llm_new_delta` fires for text and the new
  `:on_llm_new_thinking_delta` fires for reasoning. Works across all
  providers (OpenAI-compatible, Anthropic, Gemini, Vertex AI, Mistral)
  and is compatible with `output_type` for streaming structured output.
- **`:on_llm_new_thinking_delta` callback** — cleanly-separated reasoning
  deltas. Pre-existing `Nous.Agent.run_stream/3` keeps emitting
  `[thinking] …` on `:on_llm_new_delta` for backward compatibility — the
  split is opt-in via `stream: true`.
- **`Nous.StreamNormalizer.ToolCallAccumulator`** — polymorphic across
  the three provider chunk shapes (OpenAI list with split JSON args,
  Anthropic `_phase`-tagged fragments, Gemini already-complete
  `functionCall`). Reassembles them into the unified
  `%{"id", "name", "arguments" => decoded_map}` shape that
  `Nous.Messages.extract_tool_calls/1` already understands.
- **`{:usage, %Nous.Usage{}}` stream event** — emitted by
  `Nous.StreamNormalizer.OpenAI` when chunks carry a `usage` field
  (auto-enabled by injecting `stream_options.include_usage: true` on
  the OpenAI-compatible streaming request), by
  `Nous.StreamNormalizer.Anthropic` from `message_start` and
  `message_delta` chunks, and by `Nous.StreamNormalizer.Gemini` from
  `usageMetadata`. The `Nous.Types.stream_event` typespec is updated.
- **Mid-stream cancellation** — `ctx.cancellation_check` is invoked
  between every streamed chunk; a thrown `{:cancelled, reason}` halts
  the run with `Errors.ExecutionCancelled` and discards partial state.
  No tool execution happens on cancellation.
- **`Nous.Messages.OpenAI.decode_arguments/1` and `parse_usage/1`**
  promoted to public helpers (formerly private) so the streaming path
  and the `ToolCallAccumulator` reuse the same JSON-decode-with-fallback
  and usage-parsing logic as the non-streaming path. Anthropic and
  Gemini's `parse_usage/1` are similarly public for the same reason.

### Changed

- Pre-existing `Nous.Agent.run_stream/3` semantics are unchanged. The
  `[thinking] …` prefix on `:on_llm_new_delta` is preserved for that
  legacy path so existing consumers don't break.
- `lib/nous/provider.ex` `build_request_params` allowlist now includes
  `stream_options` (no-op for non-OpenAI providers — silently ignored).

### Documentation

- New "Streaming with Tool Execution" section in `README.md`.
- New "Streaming with Tool Execution (Recommended)" section in
  `docs/guides/liveview-integration.md` with a complete LiveView
  example wiring `:agent_delta`, `:agent_thinking`, `:tool_call`,
  `:tool_result`, `:agent_message`, and `:agent_complete`.
- New "Streaming Structured Output" section in
  `docs/guides/structured_output.md`.
- 0.15.2 → 0.15.3 entry in `docs/guides/migration_guide.md`.
- `AGENTS.md` Quick Start example updated.

## [0.15.2] - 2026-04-27

Documentation-only release. No code changes.

### Added

- **`AGENTS.md`** — quick-reference for AI coding agents (Claude, Cursor,
  Copilot, Codex, etc.) consuming the library. Covers the minimal API,
  provider quick-pick, key opts, custom tools, HTTP backend, security
  rules, common workflows, and what's public vs internal. Conforms to
  <https://agents.md>.

### Changed

- README "Supported Providers" table now lists `vllm:` and `sglang:`
  as first-class named providers (previously only `lmstudio:` was
  mentioned; vLLM and SGLang were buried in the `custom:` section).
- README "Local Servers" section now recommends the dedicated
  `lmstudio:` / `vllm:` / `sglang:` / `ollama:` prefixes over `custom:`
  — they default to the right port, validate `*_BASE_URL` env vars
  through `UrlGuard`, and pick up the OpenAI stream normalizer for free.
- New "HTTP Backend" section in README covering the pluggable
  `Nous.HTTP.Backend` behaviour, env-var selection, and shared hackney
  pool config.
- Cleaned up `mix docs` warnings — replaced backticks around hidden
  module references in CHANGELOG so ExDoc no longer tries to auto-link
  them.

## [0.15.1] - 2026-04-26

Follow-up to 0.15.0. No behavioral changes for existing users — the
default HTTP backend stays Req. Two themes: making the HTTP backend
pluggable, and bringing the local-server providers (LM Studio, vLLM,
SGLang) up to date with the post-0.15.0 hackney streaming rewrite.

### Added

- **Pluggable HTTP backend for non-streaming requests.** New
  `Nous.HTTP.Backend` behaviour with `Nous.HTTP.Backend.Req` (default)
  and `Nous.HTTP.Backend.Hackney` implementations. Configure via:
  - per-call: `HTTP.post(url, body, headers, backend: Nous.HTTP.Backend.Hackney)`
  - env var: `NOUS_HTTP_BACKEND=hackney` (also accepts `req` or any
    fully-qualified custom backend module name)
  - app config: `config :nous, :http_backend, Nous.HTTP.Backend.Hackney`

  Precedence: per-call > env > app config > default. Custom backends
  are resolved via `String.to_existing_atom/1` with rescue (per the
  project-wide C-2 rule from the 0.15.0 review — never `String.to_atom/1`
  on env input). Benchmark script at `bench/http_backend.exs`; results
  in `docs/benchmarks/http_backend.md`.
- **Hackney `:default` pool is now configurable from app config:**
  `config :nous, :hackney_pool, max_connections: 200, timeout: 1_500`.
  Applied at app boot. Used by both the Hackney HTTP backend and the
  streaming pipeline. (Hackney 4 caps the idle keepalive timeout at
  2_000 ms — values above that silently cap.)
- **Per-call `:connect_timeout` and `:pool` opts** added to both HTTP
  backends and `Nous.Providers.HTTP.stream/4`. Default 30_000ms /
  `:default` pool. Lets a single app run different timeouts per
  provider without mutating shared state.
- Test coverage for `lmstudio:`, `vllm:`, `sglang:` providers (12 new
  tests) plus 14 backend contract tests run twice (once per backend)
  and 9 backend-resolution tests.

### Fixed

- Removed dead `finch_name` arg from `lmstudio.ex` / `vllm.ex` /
  `sglang.ex` `chat_stream/2` calls — leftover from the pre-hackney
  streaming code; `HTTP.stream/4` has been ignoring it since 0.15.0.
- `lmstudio:` / `vllm:` / `sglang:` `base_url` is now validated through
  `Nous.Tools.UrlGuard` with `allow_private_hosts: true`. Rejects
  malformed schemes (`file://`, `gopher://`, etc.) from `*_BASE_URL`
  env vars while keeping localhost defaults.

## [0.15.0] - 2026-04-26

Comprehensive security & correctness pass driven by a multi-agent code review of every subsystem. **57 fixes** across 10 Critical, 19 High, 16 Medium, and 12 Low severity findings, plus a streaming pipeline rewrite. The full review report is at `docs/reviews/2026-04-26-comprehensive-review.md`.

Minor version bump (not patch) because of the 9 behavioral changes called out below — most are security defaults moving from open to deny, which existing callers may need to opt back into.

### ⚠ Behavioral / breaking changes

Read these before upgrading.

- **Sub-agent deps no longer auto-forward to children.** The `compute_sub_deps/1` helper in `Nous.Plugins.SubAgent` now defaults to `[]`. The previous default forwarded every parent dep (minus a 6-key denylist) — secrets, repo handles, signed URLs all leaked into LLM-controlled sub-agent contexts. To restore the old behaviour, set `:sub_agent_shared_deps, :all` explicitly. Recommended: list specific keys with `:sub_agent_shared_deps, [:key1, :key2]`.
- **Tools with `requires_approval: true` are now rejected when no `:approval_handler` is wired** (was silently approved). If you use `Nous.Tools.Bash`, `FileWrite`, or `FileEdit`, configure an `approval_handler` on `RunContext` or those tools will refuse to run.
- **File tools (`FileRead/Write/Edit/Glob/Grep`) now enforce a workspace root.** Defaults to `cwd`; override per-agent via `deps: %{workspace_root: "/path"}`. Paths that escape the root (absolute paths outside, `..` traversal, symlink-escape) are rejected with a clear error to the LLM.
- **`PromptTemplate.from_template/2` rejects template bodies containing `<% ... %>` blocks** other than the simple `<%= @ident %>` substitution form. Previously bodies were passed through `EEx.eval_string/2`, which executes arbitrary Elixir — an RCE vector for any caller piping LLM output into a template. Conditionals must now be expressed by composing multiple smaller templates.
- **Workflow `:fallback` error strategy now actually executes the fallback node** (was a silent no-op that returned `{:fallback, id}` as if the primary had succeeded). Workflows that relied on the broken behaviour will now see real fallback execution.
- **Workflow `max_iterations` exhaustion returns `{:error, {:max_iterations_exceeded, node_id, max}}`** instead of silently `{:ok, state}`. Quality-gate loops that saturate now surface as failures rather than passing-looking results.
- **Workflow `:pre_node` hook returning `:deny` aborts the workflow** with `{:error, {:hook_denied, hook_name, node_id}}`. Previously was silently mapped to `{:pause, _}` so safety hooks suspended a checkpoint forever.
- **Permissions `:strict` mode is deny-by-default at the filter layer.** New `:allow_names` / `:allow_prefixes` opts on `Nous.Permissions.build_policy/1`. Previously `strict_policy()` with empty deny lists silently exposed every tool.
- **`PromEx` plugin event names corrected** (`[:nous, :model, ...]` → `[:nous, :provider, ...]`). Anyone using `Nous.PromEx.Plugin` saw zero data on the model/stream metric panels until now. Metric paths still emit as `nous_model_*` for dashboard backward compatibility.
- **`Nous.Tool.Validator` now actually runs.** `tool.validate_args` defaulted to `true` for months but `ToolExecutor` never called the validator. Tools whose params declared `"required": [...]` will now reject calls with missing fields up-front (returning a structured `ToolError` to the LLM with the field name) instead of crashing inside the tool body and reporting a generic `FunctionClauseError`. If you have tools that relied on the lack of validation, set `validate_args: false` on the tool struct.
- **`Nous.Teams.RateLimiter.acquire/3` returns `{:ok, reservation_ref}`** instead of `:ok`. Existing call sites doing `assert :ok = RateLimiter.acquire(...)` need `assert {:ok, _ref} = ...`. This is the contract change that makes concurrent acquires near the cap race-safe (M-9). Pair with `record_usage(reservation: ref, ...)` for atomic reconciliation, or `release/2` to cancel. Bare `record_usage/3` (no `:reservation`) still works for legacy post-hoc callers.

### Added

- **`Nous.Tools.PathGuard`** — workspace-root sandbox for file tools. Rejects path traversal, NUL-byte injection, and symlink escapes. Used by all five built-in file tools.
- **`Nous.Tools.UrlGuard`** — SSRF protection for outbound HTTP. Rejects schemes other than `http`/`https`, blocks RFC1918 / loopback / link-local / CGNAT / IPv6 ULA / cloud-metadata IPs (`169.254.169.254`). Used by `WebFetch` (with redirect re-validation) and the Custom provider's `base_url`. `:allow_private_hosts` opt-in for local dev.
- **Streaming pipeline rewritten on `:hackney 4` `:async, :once` (pull-based)**, replacing the prior spawn + `Finch.stream` + mailbox plumbing. The `Stream.resource` consumer now drives `:hackney.stream_next/1` directly — backpressure is structural, no consumer mailbox can grow unboundedly. Same path picks up hackney 4's HTTP/3 + Alt-Svc auto-upgrade for free. New `:bypass`-driven integration tests exercise the streaming path end-to-end.
- **`link_counts_by_source/1` optional Store callback** for KB backends. ETS implementation provided. Reduces `kb_health_check` from O(E·L) to O(L) — health checks on a 1k-entry / 5k-link KB drop from millions of comparisons to thousands.
- **Workflow fallback validation in `Nous.Workflow.Compiler`** — fallback target nodes are reachable for the purposes of `:unreachable_nodes` validation but excluded from the topo order so they don't double-execute.
- **AgentServer task generation refs** — every spawned agent task carries a monotonic ref; stale `:agent_response_ready` / `:agent_task_completed` messages from cancelled tasks are discarded. Fixes silent message loss when the user types fast or calls `clear_history` mid-stream.
- Seven new test files: `test/nous/json_test.exs`, `test/nous/prompt_template_test.exs`, `test/nous/tools/path_guard_test.exs`, `test/nous/tools/url_guard_test.exs`, plus expanded coverage in `test/nous/workflow/phase2_test.exs`, `test/nous/workflow/phase3_test.exs`, `test/nous/transcript_test.exs`. **Test suite: 1539 → 1543 passing** (`mix test`), plus 0 dialyzer errors and 0 credo issues at `--strict`.

### Fixed (security)

- **Atom-table DoS via `String.to_atom/1` on untrusted input across 7 modules** (Critical). Adopted a project-wide rule — never `String.to_atom/1` on data that didn't originate from a literal in this repo. Audited and fixed: `Agent.Context.safe_to_atom`, skill loader frontmatter parser, LlamaCpp provider message-key conversion, `PromptTemplate.extract_variables`, `Eval.TestCase` YAML key conversion, and the `--tags` / `--exclude` parsers in `mix nous.eval` / `mix nous.optimize`.
- **EEx code-execution from template bodies** (Critical, see breaking changes above) — `PromptTemplate` now rejects non-`<%= @var %>` markers.
- **`Nous.Hook` `:command` type now requires a `[program | args]` list**, not a raw string. Previous string handler was passed to `NetRunner.run(["sh", "-c", str], ...)` — RCE class if `handler` ever came from config or user input.
- **`Bash` and `FileGrep` tools scrub the env before shelling out** — whitelists `PATH/HOME/LANG/LC_ALL/TZ/USER/SHELL/TERM`, drops `*_API_KEY`, `*_TOKEN`, `*_SECRET`, `LD_PRELOAD`, etc. `FileGrep` now resolves `rg` via `System.find_executable/1` (no `which` PATH-shadowing). `Bash` uses absolute `/bin/sh`.
- **`HumanInTheLoop` plugin matches tool names case-insensitively** — was raw equality; a tool registered as `"Send_Email"` bypassed approval if config said `"send_email"`.
- **`Nous.Plugins.Memory` wraps auto-injected memories in `<retrieved_memory>` tags with provenance metadata** and an explicit "USER-SUPPLIED DATA, not instructions" framing — defense-in-depth against stored prompt injection through the LLM-callable `remember` tool.
- **`extra_body` blocked-keys list** — drops `messages`, `model`, `stream`, `system`, `tools`, `tool_choice` with a logged warning. Prevents `extra_body` from being a back-door for rewriting the conversation, model, or safe-tool whitelist.
- **`BraveSearch` migrated from raw `:httpc` (no TLS verify by default) to `Req` with explicit `verify: :verify_peer`.** Previous code path leaked the API key to any MITM on the wire.
- **`Custom` provider validates `base_url` through `UrlGuard`** at startup — SSRF prevention for the user-supplied endpoint URL.
- **Skill loader caps file count (1000) and individual file size (5MB), and skips symlinks** — prevents loading `/etc/passwd` via a symlink in a skills directory.

### Fixed (correctness)

- **Streaming normalizers (OpenAI / LlamaCpp) no longer drop `tool_calls` or `finish_reason`** when both arrive in the same chunk. Previously the `cond` returned a single event and silently dropped the others; tool-calling agents misclassified termination and the OpenAI complete-response path lost tool calls entirely.
- **Anthropic streaming `input_json_delta` fragments** are now tagged with content-block `_index` and `_phase` (`:start | :partial | :stop`) so a stateful consumer can reassemble the full tool call. The non-streaming `convert_complete_response/1` path was already correct.
- **Transcript compaction preserves `tool_call`/`tool_result` pairs** across the compaction boundary. Previously the naive `Enum.split` could orphan a `:tool` message from its assistant prelude — Anthropic and OpenAI 400 in that shape.
- **AgentServer task generation refs (C-5/H-16/L-7)** prevent silent message loss in three races: stale `:agent_response_ready` overwriting a cancelled context, `clear_history` un-clearing itself, and the wildcard `:DOWN` handler clearing the wrong task.
- **Workflow scratch ETS leak** — `maybe_cleanup_scratch/1` now runs on every non-suspended terminal path (was only the `:ok` arm). Failed workflows under retry no longer accumulate orphan ETS tables.
- **Memory backends (Hybrid/Muninn/Zvec) use unnamed ETS tables** — named tables are global per BEAM, so a second concurrent agent crashed `init/1` with "table already exists".
- **Memory backends roll back on NIF errors** — `:ok = NIF.call(...)` pattern-matches replaced with `with` chains; ETS insert/delete only happens after the index op succeeds, leaving consistent (entry-absent) state on failure.
- **SQLite memory store wraps multi-statement ops in `BEGIN ... COMMIT`** — a crash mid-write would have left a row in `memories` without its `memories_fts` row, silently invisible to `recall` but visible to `list`.
- **SQLite/DuckDB metadata `atomize_keys` survives unknown keys** — was raising `ArgumentError` on a single new key in user-supplied metadata, breaking `recall`/`list` for the entire process.
- **`parallel_map` handler `{:error, _}` returns are collected as failures** — `safely_run_handler/3` previously wrapped any return value in `:ok`, so user error returns silently landed in `successful_results`.
- **`AgentRunner` no longer mutates `agent.model` mid-run** when fallback fires. Active model is tracked on `ctx.deps[:active_model]` and surfaced in stop telemetry as `:active_model_provider` / `:active_model_name` / `:fallback_used`. Sticky-fallback is preserved across iterations. New `[:nous, :agent, :fallback, :used]` event when the chain advances.
- **`Persistence.ETS` table is owned by a dedicated `TableOwner` GenServer** under the application supervisor — was dying with whichever transient process happened to call `save/load` first. `save/2` now returns `{:error, _}` on insert failure (was unconditional `:ok`).
- **`Decisions.supersede/5` docstring corrected** — flagged as best-effort, not atomic. The Store behaviour has no transaction primitive yet.
- **Coordinator `Process.demonitor/2` on agent removal** — was leaking monitor refs and could fire spurious `{:agent_crashed, name, _}` for healthy agents after rapid stop+respawn.
- **Workflow `:workflow_end` hook payload now reflects failure-time state**, not initial state, so post-mortems see the actual state at failure.
- **AgentServer `load_context` runs in a `Task.Supervisor.start_child` task** with `GenServer.reply/2` — slow persistence backends no longer block concurrent `get_context` / `cancel_execution` calls.
- **AgentDynamicSupervisor + Application supervisor restart limits** tuned to `max_restarts: 100, max_seconds: 10` (was the default 3-in-5) so one bad user's crash loop doesn't take down every other tenant.
- **`Nous.Teams.RateLimiter` is now race-safe under concurrent acquires (M-9 final).** `acquire/3` now returns `{:ok, reservation_ref} | {:error, _}` and atomically reserves the estimated tokens + 1 request slot. `record_usage/3` accepts `:reservation` to reconcile actual vs estimated; missing reconciliations are auto-refunded after `:reservation_ttl_ms` (default 5 min) with a `Logger.warning/1`. `release/2` cancels a reservation when the call errored before completing. Legacy `record_usage/3` without `:reservation` still works for callers that don't go through `acquire`. Added `:open_reservations` to `get_status/1`.
- **`Nous.Memory.Embedding.Bumblebee` uses a Registry + DynamicSupervisor (M-7 final).** Each model_name is owned by exactly one `ServingHolder` GenServer registered by name. Replaces the `:persistent_term` cache (which forced a node-wide GC pause per new model). The application supervisor conditionally adds the Registry + ServingSupervisor children when Bumblebee is loaded.

### Fixed (UX / minor)

- `clean_tool_name/1` tolerates `nil` and non-binary input (some providers emit malformed function-call responses).
- OpenAI `reasoning_model?/1` matches the full `o[1-9]` family via regex (catches new `o4`, `o3-pro`, etc.); also strips `presence_penalty` and `frequency_penalty` for reasoning models.
- `Tool.from_function/2` no longer fakes a hardcoded `query` parameter schema when no `@doc` is found — falls back to the empty additional-properties schema with a debug log.
- KB `Entry.slugify/1` NFD-normalises and strips combining marks so `"Café"` → `"cafe"` instead of being entirely stripped.
- `kb_health_check` `coherence_score` weighted by issue severity (`:high 0.2, :medium 0.1, :low 0.05`), clamped to `[0.0, 1.0]`.
- ParallelExecutor sorts branch results by `branch_id` before merging — deterministic instead of completion-order-dependent.
- Transcript `summarize/1` redacts `:tool` message content (replaced with a structural marker) so secrets / PII pulled from MCP don't bake into the permanent summary.
- All compile warnings cleared (unused aliases, unused vars, dialyzer "clause never matches" on test stubs, "incompatible types" on intentional `assert_raise` constructions).

### Known limitations (documented in code, not silently glossed)

- **9 modules carry `@dialyzer :no_opaque`** for `MapSet` capture-syntax false positives — Elixir community standard, each suppression has a one-line justification at the top of its module. Specs were tried first and verified not to help; this isn't a code bug, it's a known dialyzer/Elixir interaction with opaque types and capture syntax (`&MapSet.member?(set, &1)` inside `Enum.*`).

### Dependencies

- Added `{:hackney, "~> 4.0"}` (production) for pull-based streaming, replacing `Finch.stream/5` for the streaming path. `Finch` / `Req` are still used for non-streaming requests.
- Added `{:bypass, "~> 2.1", only: :test}` for in-test HTTP server fixtures driving the new streaming integration tests.

## [0.14.3] - 2026-04-25

### Added

- **`:extra_body` setting for arbitrary request body params** — pass vendor-specific top-level JSON keys (e.g. `top_k`, `chat_template_kwargs`, `repetition_penalty`, `min_p`, `best_of`, `ignore_eos`) to OpenAI-compatible providers (`vllm:`, `sglang:`, `custom:`, `lmstudio:`, `ollama:`). Mirrors the OpenAI Python SDK's `extra_body=` argument. Works in `default_settings`, `Nous.LLM` calls, and agent `model_settings`. Atom keys are stringified at request build time; nested values pass through verbatim. `extra_body` wins on collision with whitelisted keys (escape-hatch semantics). Also forwarded by Gemini and Vertex AI overrides.

  Example — disable Qwen3 thinking and tune sampling on a vLLM endpoint:

      Nous.new("custom:qwen3-vl",
        base_url: "http://localhost:8000/v1",
        default_settings: %{
          extra_body: %{
            top_k: 20,
            chat_template_kwargs: %{enable_thinking: false}
          }
        })

  Example — interleaved thinking (preserve thinking blocks across turns):

      Nous.new("custom:qwen3-vl",
        base_url: "http://localhost:8000/v1",
        default_settings: %{
          extra_body: %{
            chat_template_kwargs: %{preserve_thinking: true}
          }
        })

## [0.14.2] - 2026-04-13

### Fixed

- **SubAgent deps propagation** — parent deps now flow to sub-agents by default (excluding plugin-internal keys like templates, PubSub, concurrency config). Use `sub_agent_shared_deps: [:key1, :key2]` in deps to restrict which keys are shared.

## [0.14.0] - 2026-04-11

### Added

- **`Nous.KnowledgeBase` — LLM-compiled personal knowledge base system** inspired by Karpathy's vision. Raw documents are ingested and compiled by an LLM into a structured markdown wiki with summaries, backlinks, cross-references, and semantic search.

  - **Core data types**:
    - `Nous.KnowledgeBase.Document` — raw ingested source material (markdown, text, URL, PDF, HTML) with status tracking and checksums
    - `Nous.KnowledgeBase.Entry` — compiled wiki entries with titles, slugs, `[[wiki-links]]`, summaries, concepts, tags, confidence scores, and optional embeddings
    - `Nous.KnowledgeBase.Link` — typed directional links between entries (related, subtopic, prerequisite, contradicts, extends, references)
    - `Nous.KnowledgeBase.HealthReport` — audit results with statistics, coverage/freshness/coherence scores, and categorized issues

  - **Storage**:
    - `Nous.KnowledgeBase.Store` — behaviour with 15 callbacks for document, entry, and link CRUD plus search and graph traversal
    - `Nous.KnowledgeBase.Store.ETS` — zero-dependency in-memory backend with Jaro-distance text search and optional embedding vector search

  - **9 agent tools** via `Nous.KnowledgeBase.Tools`: `kb_search`, `kb_read`, `kb_list`, `kb_ingest`, `kb_add_entry`, `kb_link`, `kb_backlinks`, `kb_health_check`, `kb_generate`

  - **`Nous.Plugins.KnowledgeBase`** — plugin that auto-injects KB tools and system prompt guidance. Composes with `Nous.Plugins.Memory`. Configurable via `deps[:kb_config]` with optional embedding support for semantic search.

  - **`Nous.Agents.KnowledgeBaseAgent`** — specialized agent behaviour for KB curation. Adds 4 reasoning tools on top of standard KB tools: `kb_plan_compilation`, `kb_verify_entry`, `kb_suggest_links`, `kb_summarize_topic`. Tracks KB operations for reporting.

  - **`Nous.KnowledgeBase.Workflows`** — pre-built DAG pipelines using the workflow engine:
    - Ingest pipeline: raw documents → concept extraction → entry compilation → link generation → embedding → persistence
    - Incremental update: detect changes via checksums and recompile affected entries
    - Health check: audit for stale, orphan, inconsistent, and duplicate entries
    - Output generation: produce reports, summaries, or slides from KB content

  - **`Nous.KnowledgeBase.Prompts`** — LLM prompt templates for extraction, compilation, linking, auditing, and output generation

  - 1,159 lines of test coverage across 6 test files (document, entry, link, ETS store, tools, plugin)

## [0.13.1] - 2026-04-03

### Added

- **`Nous.Transcript` — Lightweight conversation compaction** without LLM calls.
  - `compact/2` — keep last N messages, summarize older ones into a system message
  - `maybe_compact/2` — auto-compact based on message count (`:every`), token budget (`:token_budget`), or percentage threshold (`:threshold`)
  - `compact_async/2` and `compact_async/3` — background compaction via `Nous.TaskSupervisor`
  - `maybe_compact_async/3` — background auto-compact with `{:compacted, msgs}` / `{:unchanged, msgs}` callbacks
  - `estimate_tokens/1` and `estimate_messages_tokens/1` — word-count-based token estimation

- **Built-in Coding Tools** — 6 tools implementing `Nous.Tool.Behaviour` for coding agents:
  - `Nous.Tools.Bash` — shell execution via NetRunner with timeout and output limits
  - `Nous.Tools.FileRead` — file reading with line numbers, offset, and limit
  - `Nous.Tools.FileWrite` — file writing with auto parent directory creation
  - `Nous.Tools.FileEdit` — string replacement with uniqueness check and `replace_all`
  - `Nous.Tools.FileGlob` — file pattern matching sorted by modification time
  - `Nous.Tools.FileGrep` — content search with ripgrep fallback to pure Elixir regex

- **`Nous.Permissions` — Tool-level permission policy engine** complementing InputGuard:
  - Three presets: `default_policy/0`, `permissive_policy/0`, `strict_policy/0`
  - `build_policy/1` — custom policies with `:deny`, `:deny_prefixes`, `:approval_required`
  - `blocked?/2`, `requires_approval?/2` — case-insensitive tool name checking
  - `filter_tools/2`, `partition_tools/2` — filter tool lists through policies

- **`Nous.Session.Config` and `Nous.Session.Guardrails`** — session-level turn limits and token budgets:
  - `Config` struct with `max_turns`, `max_budget_tokens`, `compact_after_turns`
  - `Guardrails.check_limits/4` — returns `:ok` or `{:error, :max_turns_reached | :max_budget_reached}`
  - `Guardrails.remaining/4`, `Guardrails.summary/4` — budget tracking and reporting

### Fixed

- **Empty stream silent failure**: `run_stream` now emits `{:error, :empty_stream}` + warning when a provider returns zero events (e.g. minimax), instead of silently yielding `{:complete, %{output: ""}}`.
- **`Memory.Search` crash on vector search error**: `{:ok, results} = store_mod.search_vector(...)` pattern match replaced with `case` — logs warning and returns empty list on error.
- **Atom table exhaustion in skill loader**: `String.to_atom/1` replaced with `String.to_existing_atom/1` + rescue fallback with debug logging.
- **Context deserialization crash on unknown roles**: `String.to_existing_atom/1` replaced with explicit role whitelist (`:system`, `:user`, `:assistant`, `:tool`), defaults to `:user` with warning.
- **Unbounded inspect in stream normalizer**: `inspect(chunk, limit: :infinity)` capped to `limit: 500, printable_limit: 1000`.
- **SQLite embedding decode crash**: `JSON.decode!/1` wrapped in rescue, returns `nil` with warning on malformed data.
- **Muninn bare rescue**: `rescue _ ->` replaced with specific exception types (`MatchError`, `File.Error`, `ErlangError`, `RuntimeError`).

### Documentation

- **Memory System Guide** (`docs/guides/memory.md`) — 630+ line walkthrough covering all 6 store backends, search/scoring, BM25, agent integration, and cross-agent memory sharing.
- **Context & Dependencies Guide** (`docs/guides/context.md`) — RunContext, ContextUpdate operations, stateful agent walkthrough, multi-user patterns.
- **Skills Guide enhanced** — added 400+ lines: module-based and file-based skill walkthroughs, skill groups, activation modes, plugin configuration.
- **LiveView examples** — chat interface (`liveview_chat.exs`) and multi-agent dashboard (`liveview_multi_agent.exs`) reference implementations.
- **PostgreSQL memory example** (`postgresql_full.exs`) — end-to-end Store implementation with tsvector + pgvector, BM25 search, hybrid RRF search.
- **Coding agent example** (`19_coding_agent.exs`) — permissions, tools, guardrails, and transcript compaction.
- **Tool permissions example** (`tool_permissions.exs`) — policy presets, custom deny lists, tool filtering.

## [0.13.0] - 2026-03-28

### Added

- **`Nous.Workflow` — DAG/graph-based workflow engine** for orchestrating agents, tools, and control flow as executable directed graphs. Complements Decisions (reasoning tracking) and Teams (persistent agent groups).
  - **Builder API**: `Ecto.Multi`-style pipes — `Workflow.new/1 |> add_node/4 |> connect/3 |> chain/2 |> run/2`
  - **8 node types**: `:agent_step`, `:tool_step`, `:transform`, `:branch`, `:parallel`, `:parallel_map`, `:human_checkpoint`, `:subworkflow`
  - **Hand-rolled graph**: dual adjacency maps, Kahn's algorithm for topological sort + cycle detection + parallel execution levels in one O(V+E) pass
  - **Static parallel**: named branches fan-out concurrently via `Task.Supervisor`
  - **Dynamic `parallel_map`**: runtime fan-out over data lists with `max_concurrency` throttling — the scatter-gather pattern
  - **Cycle support**: edge-following execution with per-node max-iteration guards for retry/quality-gate loops
  - **Workflow hooks**: `:pre_node`, `:post_node`, `:workflow_start`, `:workflow_end` — integrates with existing `Nous.Hook` struct
  - **Pause/resume**: via hook (`{:pause, reason}`), `:atomics` external signal, or `:human_checkpoint` auto-suspend
  - **Error strategies**: `:fail_fast`, `:skip`, `{:retry, max, delay}`, `{:fallback, node_id}` per node
  - **Telemetry**: `[:nous, :workflow, :run|:node, :start|:stop|:exception]` events
  - **Execution tracing**: opt-in per-node timing and status recording (`trace: true`)
  - **Checkpointing**: `Checkpoint` struct + `Store` behaviour + ETS backend
  - **Subworkflows**: nested workflow invocation with `input_mapper`/`output_mapper` for data isolation
  - **Runtime graph mutation**: `on_node_complete` callback, `Graph.insert_after/6`, `Graph.remove_node/2`
  - **Mermaid visualization**: `Workflow.to_mermaid/1` generates flowchart diagrams with type-specific node shapes
  - **Scratch ETS**: optional per-workflow ETS table for large/binary data exchange between steps
  - **113 new tests** covering all workflow features

## [0.12.17] - 2026-03-28

### Removed

- **Dead module `Nous.Decisions.Tools`**: 4 tool functions never used by any plugin or code path.
- **Dead module `Nous.StreamNormalizer.Mistral`**: Mistral provider uses the default OpenAI-compatible normalizer.
- **Dead function** `emit_fallback_exhausted/3` in Fallback module: Defined but never called.
- **Dead config `enable_telemetry`**: Set in config files but never read — telemetry is always on.
- **Dead config `log_level`**: Set in dev/test configs but never read by Nous.
- **Unused test fixtures**: `NousTest.Fixtures.LLMResponses` and its generator script (generated Oct 2025, never imported).

### Fixed

- **Compiler warning in `output_schema.ex`**: Removed always-truthy conditional around `to_json_schema/1` return value.

### Changed

- All JSON encoding/decoding uses built-in `JSON` module instead of `Jason`. Jason removed from direct dependencies.
- Added `pretty_encode!/1` helper to internal JSON module for pretty-printed JSON output (used in LLM prompts and eval reports).
- Updated README with Elixir 1.18+ / OTP 27+ requirements.

## [0.12.16] - 2026-03-28

### Fixed

- **Anthropic multimodal messages silently lost image data**: `message_to_anthropic/1` matched on `content` being a list, but `Message.user/2` stores content parts in `metadata.content_parts` as a string. Multimodal messages were sent as plain text, losing all image data. Now reads from metadata like the OpenAI formatter.
- **Gemini multimodal messages had the same issue**: Same pattern match bug caused all image content to be dropped.
- **Anthropic image format incorrect**: The `data` field contained the full data URL prefix (`data:image/jpeg;base64,...`) instead of raw base64; `media_type` was hardcoded to `"image/jpeg"` regardless of actual format; HTTP URLs were incorrectly wrapped as base64 source instead of `"type": "url"`.
- **Gemini had no image support**: All non-text content parts fell through to a `[Image: ...]` text representation. Now uses `inlineData` for base64 images and `fileData` for HTTP URLs.
- **Anthropic duplicate thinking block**: Assistant messages with reasoning content emitted the `thinking` block twice.

### Added

- `ContentPart.parse_data_url/1` — extract MIME type and raw base64 data from a data URL string.
- `ContentPart.data_url?/1` and `ContentPart.http_url?/1` — URL type predicates.
- OpenAI formatter: `:image` content type support (converts to data URL) and `detail` option passthrough for `image_url` parts.
- Comprehensive vision test pipeline (`test/nous/vision_pipeline_test.exs`) with 19 unit tests covering format conversion across all providers and 4 LLM integration tests.
- Test fixture images: `test_square.png` (100x100 red), `test_tiny.webp` (minimal WebP).

## [0.12.15] - 2026-03-26

### Fixed

- **`receive_timeout` silently dropped in `Nous.LLM`**: `generate_text/3` and `stream_text/3` with a string model only passed `[:base_url, :api_key, :llamacpp_model]` to `Model.parse`, so `receive_timeout` was silently ignored. Now correctly forwarded.

### Removed

- **Dead timeout config**: Removed unused `default_timeout` and `stream_timeout` from `config/config.exs`. Timeouts are determined by per-provider defaults in `Model.default_receive_timeout/1` and each provider module's `@default_timeout`/`@streaming_timeout` constants.

### Documentation

- Added "Timeouts" section to README documenting `receive_timeout` option and default timeouts per provider.

## [0.12.14] - 2026-03-21

### Added

- **Hooks system**: Granular lifecycle interceptors for tool execution and request/response flow.
  - 6 lifecycle events: `pre_tool_use`, `post_tool_use`, `pre_request`, `post_response`, `session_start`, `session_end`
  - 3 handler types: `:function` (inline), `:module` (behaviour), `:command` (shell via NetRunner)
  - Matcher-based dispatch: string (exact tool name), regex, or predicate function
  - Blocking semantics for `pre_tool_use` and `pre_request` — hooks can deny or modify tool calls
  - Priority-based execution ordering (lower = earlier)
  - Telemetry events: `[:nous, :hook, :execute, :start | :stop]`, `[:nous, :hook, :denied]`
  - `Nous.Hook`, `Nous.Hook.Registry`, `Nous.Hook.Runner`
  - New option on `Nous.Agent.new/2`: `:hooks`
  - New example: `examples/16_hooks.exs`

- **Skills system**: Reusable instruction/capability packages for agents.
  - Module-based skills with `use Nous.Skill` macro and behaviour callbacks
  - File-based skills: markdown files with YAML frontmatter, loaded from directories
  - 5 activation modes: `:manual`, `:auto`, `{:on_match, fn}`, `{:on_tag, tags}`, `{:on_glob, patterns}`
  - Skill groups: `:coding`, `:review`, `:testing`, `:debug`, `:git`, `:docs`, `:planning`
  - Registry with load/unload, activate/deactivate, group operations, and input matching
  - `Nous.Plugins.Skills` — auto-included plugin bridging skills into the agent lifecycle
  - Directory scanning: `skill_dirs:` option and `Nous.Skill.Registry.register_directory/2`
  - Telemetry events: `[:nous, :skill, :activate | :deactivate | :load | :match]`
  - New options on `Nous.Agent.new/2`: `:skills`, `:skill_dirs`
  - New example: `examples/17_skills.exs`
  - New guides: `docs/guides/skills.md`, `docs/guides/hooks.md`

- **21 built-in skills**:
  - Language-agnostic (10): CodeReview, TestGen, Debug, Refactor, ExplainCode, CommitMessage, DocGen, SecurityScan, Architect, TaskBreakdown
  - Elixir-specific (5): PhoenixLiveView, EctoPatterns, OtpPatterns, ElixirTesting, ElixirIdioms
  - Python-specific (6): PythonFastAPI, PythonTesting, PythonTyping, PythonDataScience, PythonSecurity, PythonUv

- **NetRunner dependency** (`~> 1.0.4`): Zero-zombie-process OS command execution for command hooks with SIGTERM→SIGKILL timeout escalation.

- 76 new tests for hooks and skills systems.

## [0.12.13] - 2026-03-20

### Added

- **`custom:` provider** (`Nous.Providers.Custom`): first-class prefix for any OpenAI-compatible endpoint, with `CUSTOM_API_KEY` / `CUSTOM_BASE_URL` environment-variable support. This is now the documented/recommended approach for custom endpoints.
  - Configuration precedence (highest to lowest): direct options to `Nous.new/2` → environment variables → application config (`config :nous, :custom, ...`) → defaults.
- Custom Providers guide (`docs/guides/custom_providers.md`) and `examples/providers/custom_providers.exs`.

### Changed

- `Model.parse/2` accepts the `openai_compatible:` prefix as a backward-compatible alias for `custom:` (both route to the `:custom` provider); `ModelDispatcher` gained an explicit `:custom` clause.
- Expanded documentation across `Model`, `OpenAICompatible`, and the README; `vllm_sglang.exs` now points to `custom:` as the recommended approach.

## [0.12.12] - 2026-03-19

### Fixed

- **Unbounded atom creation in `atomize_keys/1`** (security): untrusted keys no longer create atoms dynamically.
- ETS table race condition in `Persistence.ETS.ensure_table/0`.
- Double recency penalization in memory search scoring.
- `clear_history` now stays in sync with the persistence backend.

### Added

- `{:error, reason}` handling in `recall/2` and `Search.search`.
- `Nous.Memory.Scope` — shared scope logic extracted from the memory modules.
- AgentServer tests (16) and Summarization plugin tests (8).

### Removed

- Dead code in `do_memory_reflection`.

## [0.12.11] - 2026-03-19

### Added

- **Per-run structured output override**: Pass `output_type:` and `structured_output:` as options to `Nous.Agent.run/3` and `Nous.Agent.run_stream/3` to override the agent's defaults per call. The same agent can return raw text or structured data depending on the request.
- **Multi-schema selection (`{:one_of, [SchemaA, SchemaB]}`)**: New output_type variant where the LLM dynamically chooses which schema to use per response. Each schema becomes a synthetic tool — the LLM's tool choice acts as schema selection. Includes automatic retry and validation against the selected schema.
  - `OutputSchema.schema_name/1` — public helper to get snake_case name for a schema module
  - `OutputSchema.tool_name_for_schema/1` — build synthetic tool name from schema module
  - `OutputSchema.find_schema_for_tool_name/2` — reverse-map tool name to schema module
  - `OutputSchema.synthetic_tool_name?/1` — predicate for synthetic tool call detection
  - `OutputSchema.extract_response_for_one_of/2` — extract text and identify matched schema from tool call
  - New example: Example 6 (per-run override) and Example 7 (multi-schema) in `examples/14_structured_output.exs`
  - New sections in `docs/guides/structured_output.md`

### Fixed

- **Synthetic tool call handling**: Structured output tool calls (`__structured_output__`) in `:tool_call` mode are now correctly filtered from the tool execution loop. Previously, these synthetic calls would produce "Tool not found" errors and cause an unnecessary extra LLM round-trip. Now they terminate the loop immediately and the structured output is extracted directly.

## [0.12.10] - 2026-03-19

### Added

- **Fallback model/provider support**: Automatic failover to alternative models when the primary model fails with a `ProviderError` or `ModelError` (rate limit, server error, timeout, auth issue).
  - `Nous.Fallback` — core fallback logic: eligibility checks, recursive model chain traversal, model string/struct parsing
  - `:fallback` option on `Nous.Agent.new/2` — ordered list of fallback model strings or `Model` structs
  - `:fallback` option on `Nous.generate_text/3` and `Nous.stream_text/3`
  - Tool schemas are automatically re-converted when falling back across providers (e.g., OpenAI → Anthropic)
  - Structured output settings are re-injected for the target provider on cross-provider fallback
  - Agent model is swapped on successful fallback so remaining iterations use the working model
  - Streaming fallback retries stream initialization only, not mid-stream failures
  - New telemetry events: `[:nous, :fallback, :activated]` and `[:nous, :fallback, :exhausted]`
  - Only `ProviderError` and `ModelError` trigger fallback; application-level errors (`ValidationError`, `MaxIterationsExceeded`, `ExecutionCancelled`, `ToolError`) are returned immediately
  - 52 new tests across `test/nous/fallback_test.exs` and `test/nous/agent_fallback_test.exs`

### Changed

- `Nous.Agent` struct gains `fallback: [Model.t()]` field (default: `[]`)
- `Nous.LLM` now uses injectable dispatcher (`get_dispatcher/0`) for testability, consistent with `AgentRunner`

## [0.12.9] - 2026-03-12

### Added

- **InputGuard plugin**: Modular malicious input classifier with pluggable strategy pattern. Detects prompt injection, jailbreak attempts, and other malicious inputs before they reach the LLM.
  - `Nous.Plugins.InputGuard` — Main plugin with configurable aggregation (`:any`/`:majority`/`:all`), short-circuit mode, and violation callbacks
  - `Nous.Plugins.InputGuard.Strategy` — Behaviour for custom detection strategies
  - `Nous.Plugins.InputGuard.Strategies.Pattern` — Built-in regex patterns for instruction override, role reassignment, DAN jailbreaks, prompt extraction, and encoding evasion. Supports `:extra_patterns` (additive) and `:patterns` (full override)
  - `Nous.Plugins.InputGuard.Strategies.LLMJudge` — Secondary LLM classification with fail-open/fail-closed modes
  - `Nous.Plugins.InputGuard.Strategies.Semantic` — Embedding cosine similarity against pre-computed attack vectors
  - `Nous.Plugins.InputGuard.Policy` — Severity-to-action resolution (`:block`, `:warn`, `:log`, `:callback`, custom `fun/2`)
  - Tracks checked message index to prevent re-triggering on tool-call loop iterations
  - New example: `examples/15_input_guard.exs`

### Fixed

- **AgentRunner**: `before_request` plugin hook now short-circuits the LLM call when a plugin sets `needs_response: false` (e.g., InputGuard blocking). Previously the current iteration would still call the LLM before the block took effect on the next iteration.

## [0.12.8] - 2026-03-12

### Fixed

- **Vertex AI v1/v1beta1 bug**: `Model.parse("vertex_ai:gemini-2.5-pro-preview-06-05")` with `GOOGLE_CLOUD_PROJECT` set was storing a hardcoded `v1` URL in `model.base_url`, causing the provider's `v1beta1` selection logic to be bypassed. Preview models now correctly use `v1beta1` at request time.

### Added

- **Vertex AI input validation**: Project ID and region from environment variables are now validated with helpful error messages instead of producing opaque DNS/HTTP errors.
- **`GOOGLE_CLOUD_LOCATION` support**: Added as a fallback for `GOOGLE_CLOUD_REGION`, consistent with other Google Cloud libraries and tooling.
- Multi-region example script: `examples/providers/vertex_ai_multi_region.exs`

## [0.12.7] - 2026-03-10

### Fixed

- **Vertex AI model routing**: Fixed `build_request_params/3` not including the `"model"` key in the params map, causing `chat/2` and `chat_stream/2` to always fall back to `"gemini-2.0-flash"` regardless of the requested model.
- **Vertex AI 404 on preview models**: Use `v1beta1` API version for preview and experimental models (e.g., `gemini-3.1-pro-preview`). The `v1` endpoint returns 404 for these models.

### Added

- `Nous.Providers.VertexAI.api_version_for_model/1` — returns `"v1beta1"` for preview/experimental models, `"v1"` for stable models.
- `Nous.Providers.VertexAI.endpoint/3` now accepts an optional model name to select the correct API version.
- Debug logging for Vertex AI request URLs.

## [0.12.6] - 2026-03-07

### Added

- **Auto-update memory**: `Nous.Plugins.Memory` can now automatically reflect on conversations and update memories after each run — no explicit tool calls needed. Enable with `auto_update_memory: true` in `memory_config`. Configurable reflection model, frequency, and context limits.
  - New `after_run/3` callback in `Nous.Plugin` behaviour — runs once after the entire agent run completes. Wired into both `AgentRunner.run/3` and `run_with_context/3`.
  - `Nous.Plugin.run_after_run/4` helper for executing the hook across all plugins
  - New config options: `:auto_update_memory`, `:auto_update_every`, `:reflection_model`, `:reflection_max_tokens`, `:reflection_max_messages`, `:reflection_max_memories`
  - New example: `examples/memory/auto_update.exs`

## [0.12.5] - 2026-03-06

### Added

- **Vertex AI provider**: `Nous.Providers.VertexAI` for accessing Gemini models through Google Cloud Vertex AI. Supports enterprise features (VPC-SC, CMEK, regional endpoints, IAM).
  - Three auth modes: app config Goth (`config :nous, :vertex_ai, goth: MyApp.Goth`), per-model Goth (`default_settings: %{goth: MyApp.Goth}`), or direct access token (`api_key` / `VERTEX_AI_ACCESS_TOKEN`)
  - Bearer token auth via `api_key` option, `VERTEX_AI_ACCESS_TOKEN` env var, or Goth integration
  - Goth integration (`{:goth, "~> 1.4", optional: true}`) for automatic service account token management — reuse existing Goth processes from PubSub, etc.
  - URL auto-construction from `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_REGION` env vars
  - `Nous.Providers.VertexAI.endpoint/2` helper to build endpoint URLs
  - Reuses existing Gemini message format, response parsing, and stream normalization
  - Model string: `"vertex_ai:gemini-2.0-flash"`

## [0.12.2] - 2026-03-04

### Fixed

- **Gemini streaming**: Fixed streaming responses returning 0 events. The Gemini `streamGenerateContent` endpoint returns a JSON array (`application/json`) by default, not Server-Sent Events. Instead of forcing SSE via `alt=sse` query parameter, added a pluggable stream parser to `Nous.Providers.HTTP`.

### Added

- `Nous.Providers.HTTP.JSONArrayParser` — stream buffer parser for JSON array responses. Extracts complete JSON objects from a streaming `[{...},{...},...]` response by tracking `{}` nesting depth while respecting string literals and escape sequences.
- `:stream_parser` option on `HTTP.stream/4` — accepts any module implementing `parse_buffer/1` with the same `{events, remaining_buffer}` contract as SSE parsing. Defaults to the existing SSE parser. Enables any provider with a non-SSE streaming format to plug in a custom parser.

## [0.12.0] - 2026-02-28

### Added

- **Memory System**: Persistent memory for agents with hybrid text + vector search, temporal decay, importance weighting, and flexible scoping.
  - `Nous.Memory.Entry` — memory entry struct with type (semantic/episodic/procedural), importance, evergreen flag, and scoping fields (agent_id, session_id, user_id, namespace)
  - `Nous.Memory.Store` — storage behaviour with 8 callbacks (init, store, fetch, delete, update, search_text, search_vector, list)
  - `Nous.Memory.Store.ETS` — zero-dep in-memory backend with Jaro-distance text search
  - `Nous.Memory.Store.SQLite` — SQLite + FTS5 backend (requires `exqlite`)
  - `Nous.Memory.Store.DuckDB` — DuckDB + FTS + vector backend (requires `duckdbex`)
  - `Nous.Memory.Store.Muninn` — Tantivy BM25 text search backend (requires `muninn`)
  - `Nous.Memory.Store.Zvec` — HNSW vector search backend (requires `zvec`)
  - `Nous.Memory.Store.Hybrid` — combines Muninn + Zvec for maximum retrieval quality
  - `Nous.Memory.Scoring` — pure functions for Reciprocal Rank Fusion, temporal decay, composite scoring
  - `Nous.Memory.Search` — hybrid search orchestrator (text + vector → RRF merge → decay → composite score)
  - `Nous.Memory.Embedding` — embedding provider behaviour with pluggable implementations
  - `Nous.Memory.Embedding.Bumblebee` — local on-device embeddings via Bumblebee + EXLA (Qwen 0.6B default)
  - `Nous.Memory.Embedding.OpenAI` — OpenAI text-embedding-3-small provider
  - `Nous.Memory.Embedding.Local` — generic local endpoint (Ollama, vLLM, LMStudio)
  - `Nous.Memory.Tools` — agent tools: `remember`, `recall`, `forget`
  - `Nous.Plugins.Memory` — plugin with auto-injection of relevant memories, configurable search scope and injection strategy
  - 6 example scripts in `examples/memory/` (basic ETS, Bumblebee, SQLite, DuckDB, Hybrid, cross-agent)
  - 62 new tests across 6 test files

- **Graceful degradation**: No embedding provider = keyword-only search. No optional deps = `Store.ETS` with Jaro matching. The core memory system has zero additional dependencies.

## [0.11.3] - 2026-02-26

### Fixed

- **Anthropic and Gemini streaming**: Added missing `Nous.StreamNormalizer.Anthropic` and `Nous.StreamNormalizer.Gemini` modules. These were referenced in `Provider.default_stream_normalizer/0` but never created, causing runtime crashes when streaming with Anthropic or Gemini providers.

### Added

- `Nous.StreamNormalizer.Anthropic` — normalizes Anthropic SSE events (`content_block_delta`, `message_delta`, `content_block_start` for tool use, thinking deltas, error events)
- `Nous.StreamNormalizer.Gemini` — normalizes Gemini SSE events (`candidates` array with text parts, `functionCall`, `finishReason` mapping)
- 42 tests for both new stream normalizers

## [0.11.0] - 2026-02-20

### Added

- **Structured Output Mode**: Agents return validated, typed data instead of raw strings. Inspired by [instructor_ex](https://github.com/thmsmlr/instructor_ex).
  - `Nous.OutputSchema` core module: JSON schema generation, provider settings dispatch, parsing and validation
  - `use Nous.OutputSchema` macro with `@llm_doc` attribute for schema-level LLM documentation
  - `validate_changeset/1` optional callback for custom Ecto validation rules
  - Validation retry loop: failed outputs are sent back to the LLM with error details (`max_retries` option)
  - System prompt augmentation with schema instructions

- **Output Type Variants**:
  - Ecto schema modules — full JSON schema + changeset validation
  - Schemaless Ecto types (`%{name: :string, age: :integer}`) — lightweight, no module needed
  - Raw JSON schema maps (string keys) — passed through as-is
  - `{:regex, pattern}` — regex-constrained output (vLLM/SGLang)
  - `{:grammar, ebnf}` — EBNF grammar-constrained output (vLLM)
  - `{:choice, choices}` — choice-constrained output (vLLM/SGLang)

- **Provider Modes**: Controls how structured output is enforced per-provider
  - `:auto` (default) — picks best mode for the provider
  - `:json_schema` — `response_format` with strict JSON schema (OpenAI, vLLM, SGLang, Gemini)
  - `:tool_call` — synthetic tool with tool_choice (Anthropic default)
  - `:json` — `response_format: json_object` (OpenAI-compatible)
  - `:md_json` — prompt-only enforcement with markdown fence + stop token (all providers)

- **Provider Passthrough**: `response_format`, `guided_json`, `guided_regex`, `guided_grammar`, `guided_choice`, `json_schema`, `regex`, `generationConfig` now passed through in `build_request_params`

- **New Files**:
  - `lib/nous/output_schema.ex` — core module
  - `lib/nous/output_schema/validator.ex` — behaviour definition
  - `lib/nous/output_schema/use_macro.ex` — `use Nous.OutputSchema` macro
  - `docs/guides/structured_output.md` — comprehensive guide
  - `examples/14_structured_output.exs` — example script with 5 patterns
  - `test/nous/output_schema_test.exs` — 42 unit tests
  - `test/nous/structured_output_integration_test.exs` — 16 integration tests
  - `test/eval/agents/structured_output_test.exs` — 3 LLM integration tests

### Changed

- `Nous.Agent` struct gains `structured_output` keyword list field (mode, max_retries)
- `Nous.Types.output_type` expanded with schemaless, raw JSON schema, and guided mode tuples
- `Nous.AgentRunner` injects structured output settings, augments system prompt, handles validation retries
- `Nous.Agents.BasicAgent.extract_output/2` routes through `OutputSchema.parse_and_validate/2`
- `Nous.Agents.ReActAgent.extract_output/2` validates `final_answer` against output_type
- Provider `build_request_params/3` passes through structured output parameters

## [0.10.1] - 2026-02-14

### Changed

- **Sub-Agent plugin unified**: Merged `ParallelSubAgent` into `Nous.Plugins.SubAgent`
  - Single plugin now provides both `delegate_task` (single) and `spawn_agents` (parallel) tools
  - `system_prompt/2` callback injects orchestration guidance including available templates
  - Templates accept `%Nous.Agent{}` structs (recommended) or config maps (legacy)
  - Parallel execution via `Task.Supervisor.async_stream_nolink`
  - Configurable concurrency (`parallel_max_concurrency`, default: 5) and timeout (`parallel_timeout`, default: 120s)
  - Graceful partial failure: crashed/timed-out sub-agents don't block others

- **New Example**: `examples/13_sub_agents.exs`
  - Template-based sub-agents using `Nous.Agent.new/2` structs
  - Parallel execution with inline model config
  - Direct programmatic invocation bypassing the LLM

## [0.10.0] - 2026-02-14

### Added

- **Plugin System**: Composable agent extensions via `Nous.Plugin` behaviour
  - Callbacks: `init/2`, `tools/2`, `system_prompt/2`, `before_request/3`, `after_response/3`
  - Add `plugins: [MyPlugin]` to any agent for cross-cutting concerns
  - AgentRunner iterates plugins at each stage of the execution loop

- **Human-in-the-Loop (HITL)**: Approval workflows for sensitive tool calls
  - `requires_approval: true` on `Nous.Tool` struct
  - `approval_handler` on `Nous.Agent.Context` for approve/edit/reject decisions
  - `Nous.Plugins.HumanInTheLoop` for per-tool configuration via deps

- **Sub-Agent System**: Enable agents to delegate tasks to specialized child agents
  - `Nous.Plugins.SubAgent` provides `delegate_task` tool
  - Pre-configured agent templates via `deps[:sub_agent_templates]`
  - Isolated context per sub-agent with shared deps support

- **Conversation Summarization**: Automatic context window management
  - `Nous.Plugins.Summarization` monitors token usage against configurable threshold
  - LLM-powered summarization with safe split points (never separates tool_call/tool_result pairs)
  - Error-resilient: keeps all messages if summarization fails

- **State Persistence**: Save and restore agent conversation state
  - `Nous.Agent.Context.serialize/1` and `deserialize/1` for JSON-safe round-trips
  - `Nous.Persistence` behaviour with `save/load/delete/list` callbacks
  - `Nous.Persistence.ETS` reference implementation
  - Auto-save hooks on `Nous.AgentServer`

- **Enhanced Supervision**: Production lifecycle management for agents
  - `Nous.AgentRegistry` for session-based process lookup via Registry
  - `Nous.AgentDynamicSupervisor` for on-demand agent creation/destruction
  - Configurable inactivity timeout on `AgentServer` (default: 5 minutes)
  - Added to application supervision tree

- **Dangling Tool Call Recovery**: Resilient session resumption
  - `Nous.Agent.Context.patch_dangling_tool_calls/1` injects synthetic results for interrupted tool calls
  - Called automatically when continuing from an existing context

- **PubSub Abstraction Layer**: Unified `Nous.PubSub` module for all PubSub usage
  - `Nous.PubSub` wraps Phoenix.PubSub with graceful no-op fallback when unavailable
  - Application-level configuration via `config :nous, pubsub: MyApp.PubSub`
  - Topic builders: `agent_topic/1`, `research_topic/1`, `approval_topic/1`
  - `Nous.Agent.Context` gains `pubsub` and `pubsub_topic` fields (runtime-only, never serialized)
  - `Nous.Agent.Callbacks.execute/3` now broadcasts via PubSub as a third channel alongside callbacks and `notify_pid`
  - `AgentServer` refactored to use `Nous.PubSub` — removes ad-hoc `setup_pubsub_functions/0` and `subscribe_fn`/`broadcast_fn` from state
  - Research Coordinator broadcasts progress via PubSub when `:session_id` is provided
  - SubAgent plugin propagates parent's PubSub context to child agents

- **Async HITL Approval via PubSub**: `Nous.PubSub.Approval` module
  - `handler/1` builds an approval handler compatible with `Nous.Plugins.HumanInTheLoop`
  - Broadcasts `{:approval_required, info}` and blocks via `receive` for response
  - `respond/4` sends approval decisions from external processes (e.g., LiveView)
  - Configurable timeout with `:reject` as default on expiry
  - Enables async approval workflows without synchronous I/O

- **Deep Research Agent**: Autonomous multi-step research with citations
  - `Nous.Research.run/2` public API with HITL checkpoints between iterations
  - Five-phase loop: plan → search → synthesize → evaluate → report
  - `Nous.Research.Planner` decomposes queries into searchable sub-questions
  - `Nous.Research.Searcher` runs parallel search agents per sub-question
  - `Nous.Research.Synthesizer` for deduplication, contradiction detection, gap analysis
  - `Nous.Research.Reporter` generates markdown reports with inline citations
  - Progress broadcasting via callbacks, `notify_pid`, and PubSub

- **New Research Tools**:
  - `Nous.Tools.WebFetch` — URL content extraction with Floki HTML parsing
  - `Nous.Tools.Summarize` — LLM-powered text summarization focused on research queries
  - `Nous.Tools.SearchScrape` — Parallel fetch + summarize for multiple URLs
  - `Nous.Tools.TavilySearch` — Tavily AI search API integration
  - `Nous.Tools.ResearchNotes` — Structured finding/gap/contradiction tracking via ContextUpdate

- **New Dependencies**:
  - `floki ~> 0.36` (optional, for HTML content extraction)
  - `phoenix_pubsub ~> 2.1` (test-only, for PubSub integration tests)

### Changed

- `Nous.Agent` struct now accepts `plugins: [module()]` option
- `Nous.Tool` struct now accepts `requires_approval: boolean()` option
- `Nous.Agent.Context` now includes `approval_handler`, `pubsub`, and `pubsub_topic` fields
- `Nous.AgentServer` supports optional `:name` registration, `:persistence` backend, and uses `Nous.PubSub` (removed ad-hoc `setup_pubsub_functions/0`)
- `Nous.AgentServer` `:pubsub` option now defaults to `Nous.PubSub.configured_pubsub()` instead of `MyApp.PubSub`
- `Nous.AgentRunner` accepts `:pubsub` and `:pubsub_topic` options when building context
- Application supervision tree includes AgentRegistry and AgentDynamicSupervisor

## [0.9.0] - 2026-01-04

### Added

- **Evaluation Framework**: Production-grade testing and benchmarking for AI agents
  - `Nous.Eval` module for defining and running test suites
  - `Nous.Eval.Suite` for test suite management with YAML support
  - `Nous.Eval.TestCase` for individual test case definitions
  - `Nous.Eval.Runner` for sequential and parallel test execution
  - `Nous.Eval.Metrics` for collecting latency, token usage, and cost metrics
  - `Nous.Eval.Reporter` for console and JSON result reporting
  - A/B testing support with `Nous.Eval.run_ab/2`

- **Six Built-in Evaluators**:
  - `:exact_match` - Strict string equality matching
  - `:fuzzy_match` - Jaro-Winkler similarity with configurable thresholds
  - `:contains` - Substring and regex pattern matching
  - `:tool_usage` - Tool call verification with argument validation
  - `:schema` - Ecto schema validation for structured outputs
  - `:llm_judge` - LLM-based quality assessment with custom rubrics

- **Optimization Engine**: Automated parameter tuning for agents
  - `Nous.Eval.Optimizer` with three strategies: grid search, random search, Bayesian optimization
  - Support for float, integer, choice, and boolean parameter types
  - Early stopping on threshold achievement
  - Detailed trial history and best configuration reporting

- **New Mix Tasks**:
  - `mix nous.eval` - Run evaluation suites with filtering, parallelism, and multiple output formats
  - `mix nous.optimize` - Parameter optimization with configurable strategies and metrics

- **New Dependency**: `yaml_elixir ~> 2.9` for YAML test suite parsing

### Documentation

- New comprehensive evaluation framework guide (`docs/guides/evaluation.md`)
- Five new example scripts in `examples/eval/`:
  - `01_basic_evaluation.exs` - Simple test execution
  - `02_yaml_suite.exs` - Loading and running YAML suites
  - `03_optimization.exs` - Parameter optimization workflows
  - `04_custom_evaluator.exs` - Implementing custom evaluators
  - `05_ab_testing.exs` - A/B testing configurations

## [0.8.1] - 2025-12-31

### Fixed

- Fixed `Usage` struct not implementing Access behaviour for telemetry metrics
- Fixed `Task.shutdown/2` nil return case in `AgentServer` cancellation
- Fixed tool call field access for OpenAI-compatible APIs (string vs atom keys)

### Added

- Vision/multimodal test suite with image fixtures (`test/nous/vision_test.exs`)
- ContentPart test suite for image conversion utilities (`test/nous/content_part_test.exs`)
- Multimodal message examples in conversation demo (`examples/04_conversation.exs`)

### Changed

- Updated docs to link examples to GitHub source files
- Improved sidebar grouping in hexdocs

## [0.8.0] - 2025-12-31

### Added

- **Context Management**: New `Nous.Agent.Context` struct for immutable conversation state, message history, and dependency injection. Supports context continuation between runs:
  ```elixir
  {:ok, result1} = Nous.run(agent, "My name is Alice")
  {:ok, result2} = Nous.run(agent, "What's my name?", context: result1.context)
  ```

- **Agent Behaviour**: New `Nous.Agent.Behaviour` for implementing custom agents with lifecycle callbacks (`init_context/2`, `build_messages/2`, `process_response/3`, `extract_output/2`).

- **Dual Callback System**: New `Nous.Agent.Callbacks` supporting both map-based callbacks and process messages:
  ```elixir
  # Map callbacks
  Nous.run(agent, "Hello", callbacks: %{
    on_llm_new_delta: fn _event, delta -> IO.write(delta) end
  })

  # Process messages (for LiveView)
  Nous.run(agent, "Hello", notify_pid: self())
  ```

- **Module-Based Tools**: New `Nous.Tool.Behaviour` for defining tools as modules with `metadata/0` and `execute/2` callbacks. Use `Nous.Tool.from_module/2` to create tools from modules.

- **Tool Context Updates**: New `Nous.Tool.ContextUpdate` struct allowing tools to modify context state:
  ```elixir
  def my_tool(ctx, args) do
    {:ok, result, ContextUpdate.new() |> ContextUpdate.set(:key, value)}
  end
  ```

- **Tool Testing Helpers**: New `Nous.Tool.Testing` module with `mock_tool/2`, `spy_tool/1`, and `test_context/1` for testing tool interactions.

- **Tool Validation**: New `Nous.Tool.Validator` for JSON Schema validation of tool arguments.

- **Prompt Templates**: New `Nous.PromptTemplate` for EEx-based prompt templates with variable substitution.

- **Built-in Agent Implementations**: `Nous.Agents.BasicAgent` (default) and `Nous.Agents.ReActAgent` (reasoning with planning tools).

- **Structured Errors**: New `Nous.Errors` module with `MaxIterationsReached`, `ToolExecutionError`, and `ExecutionCancelled` error types.

- **Enhanced Telemetry**: New events for iterations (`:iteration`), tool timeouts (`:tool_timeout`), and context updates (`:context_update`).

### Changed

- **Result Structure**: `Nous.run/3` now returns `%{output: _, context: _, usage: _}` instead of just output string.

- **Tool Function Signature**: Tools now receive `(ctx, args)` instead of `(args)`. The context provides access to `ctx.deps` for dependency injection.

- **Examples Modernized**: Reduced from ~95 files to 21 files. Flattened directory structure from 4 levels to 2 levels. All examples updated to v0.8.0 API.

### Removed

- Removed deprecated provider modules: `Nous.Providers.Gemini`, `Nous.Providers.Mistral`, `Nous.Providers.VLLM`, `Nous.Providers.SGLang`.

- Removed built-in tools: `Nous.Tools.BraveSearch`, `Nous.Tools.DateTimeTools`, `Nous.Tools.StringTools`, `Nous.Tools.TodoTools`. These can be implemented as custom tools.

- Removed `Nous.RunContext` (replaced by `Nous.Agent.Context`).

- Removed `Nous.PromEx.Plugin` (users can implement custom Prometheus metrics using telemetry events).

## [0.7.2] - 2025-12-29

### Fixed

- **Stream completion events**: The `[DONE]` SSE event now properly emits a `{:finish, "stop"}` event instead of being silently discarded. This ensures stream consumers always receive a completion signal.

- **Documentation links**: Fixed broken links in hexdocs documentation. Relative links to `.exs` example files now use absolute GitHub URLs so they work correctly on hexdocs.pm.

## [0.7.1] - 2025-12-29

### Changed

- **Make all provider dependencies optional**: `openai_ex`, `anthropix`, and `gemini_ex` are now truly optional dependencies. Users only need to install the dependencies for the providers they use.

- **Runtime dependency checks**: Provider modules now check for dependency availability at runtime instead of compile-time, allowing the library to compile without any provider-specific dependencies.

- **OpenAI message format**: Messages are now returned as plain maps with string keys (`%{"role" => "user", "content" => "Hi"}`) instead of `OpenaiEx.ChatMessage` structs. This removes the compile-time dependency on `openai_ex` for message formatting.

### Fixed

- Fixed "anthropix dependency not available" errors that occurred when using the library in applications without `anthropix` installed.

- Fixed compile-time errors that occurred when `openai_ex` was not present in the consuming application.

## [0.7.0] - 2025-12-27

Initial public release with multi-provider LLM support:

- OpenAI-compatible providers (OpenAI, Groq, OpenRouter, Ollama, LM Studio, vLLM)
- Native Anthropic Claude support with extended thinking
- Google Gemini support
- Mistral AI support
- Tool/function calling
- Streaming support
- ReAct agent implementation

<!-- Version comparison links -->
[Unreleased]: https://github.com/nyo16/nous/compare/v0.17.0...HEAD
[0.17.0]: https://github.com/nyo16/nous/compare/v0.16.6...v0.17.0
[0.16.6]: https://github.com/nyo16/nous/compare/v0.16.5...v0.16.6
[0.16.5]: https://github.com/nyo16/nous/compare/v0.16.4...v0.16.5
[0.16.4]: https://github.com/nyo16/nous/compare/v0.16.3...v0.16.4
[0.16.3]: https://github.com/nyo16/nous/compare/v0.16.2...v0.16.3
[0.16.2]: https://github.com/nyo16/nous/compare/v0.16.1...v0.16.2
[0.16.1]: https://github.com/nyo16/nous/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/nyo16/nous/compare/v0.15.8...v0.16.0
[0.15.8]: https://github.com/nyo16/nous/compare/v0.15.7...v0.15.8
[0.15.7]: https://github.com/nyo16/nous/compare/v0.15.6...v0.15.7
[0.15.6]: https://github.com/nyo16/nous/compare/v0.15.5...v0.15.6
[0.15.5]: https://github.com/nyo16/nous/compare/v0.15.4...v0.15.5
[0.15.4]: https://github.com/nyo16/nous/compare/v0.15.3...v0.15.4
[0.15.3]: https://github.com/nyo16/nous/compare/v0.15.2...v0.15.3
[0.15.2]: https://github.com/nyo16/nous/compare/v0.15.1...v0.15.2
[0.15.1]: https://github.com/nyo16/nous/compare/v0.15.0...v0.15.1
[0.15.0]: https://github.com/nyo16/nous/compare/v0.14.3...v0.15.0
[0.14.3]: https://github.com/nyo16/nous/compare/v0.14.2...v0.14.3
[0.14.2]: https://github.com/nyo16/nous/compare/v0.14.0...v0.14.2
[0.14.0]: https://github.com/nyo16/nous/compare/v0.13.1...v0.14.0
[0.13.1]: https://github.com/nyo16/nous/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/nyo16/nous/compare/v0.12.17...v0.13.0
[0.12.17]: https://github.com/nyo16/nous/compare/v0.12.16...v0.12.17
[0.12.16]: https://github.com/nyo16/nous/compare/v0.12.15...v0.12.16
[0.12.15]: https://github.com/nyo16/nous/compare/v0.12.14...v0.12.15
[0.12.14]: https://github.com/nyo16/nous/compare/v0.12.13...v0.12.14
[0.12.13]: https://github.com/nyo16/nous/compare/v0.12.12...v0.12.13
[0.12.12]: https://github.com/nyo16/nous/compare/v0.12.11...v0.12.12
[0.12.11]: https://github.com/nyo16/nous/compare/v0.12.10...v0.12.11
[0.12.10]: https://github.com/nyo16/nous/compare/v0.12.9...v0.12.10
[0.12.9]: https://github.com/nyo16/nous/compare/v0.12.8...v0.12.9
[0.12.8]: https://github.com/nyo16/nous/compare/v0.12.7...v0.12.8
[0.12.7]: https://github.com/nyo16/nous/compare/v0.12.6...v0.12.7
[0.12.6]: https://github.com/nyo16/nous/compare/v0.12.5...v0.12.6
[0.12.5]: https://github.com/nyo16/nous/compare/v0.12.2...v0.12.5
[0.12.2]: https://github.com/nyo16/nous/compare/v0.12.0...v0.12.2
[0.12.0]: https://github.com/nyo16/nous/compare/v0.11.3...v0.12.0
[0.11.3]: https://github.com/nyo16/nous/compare/v0.11.0...v0.11.3
[0.11.0]: https://github.com/nyo16/nous/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/nyo16/nous/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/nyo16/nous/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/nyo16/nous/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/nyo16/nous/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/nyo16/nous/compare/v0.7.2...v0.8.0
[0.7.2]: https://github.com/nyo16/nous/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/nyo16/nous/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/nyo16/nous/releases/tag/v0.7.0
