# Plan — Audit-Pass Review Follow-up

**Source:** `.claude/plans/review/reviews/review-triage.md` (from commit #59 review)
**Type:** Bug-fix / hardening set · **Depth:** standard · **Scope:** single plan
**Verdict carried in:** PASS WITH WARNINGS (unchanged — both verify-gates cleared as non-issues)

> Every triage finding appears below as a task or as a ✅ verified-non-issue. Nothing is silently dropped.

## Verified non-issues (closed during planning — no code change)
- ✅ **Hook double-fire** — `run_stream` calls `run_before_request` once (L312); does not delegate to `run_iteration` (L592). Not a bug.
- ✅ **`:system` message at tail** (`plugins/memory.ex:540`) — providers extract/accept system messages position-independently. Not a bug.
- ✅ **`zip_input_on_exit` version** — project is Elixir `~> 1.18`; option available. No action.

## Verification (run after EACH phase)
```
mix compile --warnings-as-errors && \
mix format --check-formatted && \
mix credo --strict && \
mix test
```
Baseline is currently green (1806 tests pass). Keep it green per phase.

---

## Phase 1 — Security hardening `[security]`

- [ ] **1.1 PathGuard TOCTOU** `lib/nous/tools/path_guard.ex:103-157`
  Callers must operate on the canonical `real_path` PathGuard resolves, not the raw arg. Audit each file tool (`web_fetch`/grep/read/write paths) to ensure the validated path is the one opened; prefer `:file.open` on the realpath or `O_NOFOLLOW`. Add a regression test: validated path swapped to a symlink → read is refused.

- [ ] **1.2 web_fetch unpinned `nil` fallback** `lib/nous/tools/web_fetch.ex:128`
  `pin_connection(_, _, nil)` currently fetches with no IP pin / raw hostname. Return `{:error, :unpinned_host}` (or equivalent) unless `allow_private_hosts` was explicitly set, so a future flag flip can't silently reopen DNS-rebind. Test both branches.

- [ ] **1.3 Pattern guard is best-effort (doc)** `lib/nous/plugins/input_guard/strategies/pattern.ex:38-72`
  Add `@moduledoc`/inline doc: regex/NFKC matching is defense-in-depth, NOT authorization; `:safe` must never gate a security decision. No behavior change.

- [ ] **1.4 Atom-exhaustion DoS** `lib/nous/eval/runner.ex:234`, `lib/nous/eval/evaluators/schema.ex:234,255` *(pre-existing, out of original diff)*
  Replace `String.to_atom/1` on YAML-sourced values with `String.to_existing_atom/1` + `ArgumentError`→keep-binary fallback, mirroring `lib/nous/eval/test_case.ex:208`. Add a test feeding a novel YAML key/field → no new atom created.

### Phase 1 suggestions
- [ ] **1.5 file_grep ReDoS cap** `lib/nous/tools/file_grep.ex:114-123` — enforce tool timeout / file-size cap on the Elixir-fallback regex path (rg path already safe).
- [ ] **1.6 Telemetry secret redaction** `lib/nous/tool_executor.ex:170-181,306-317` — scrub/`truncate_for_log` `reason`/`stacktrace` before emitting so a tool error carrying a secret doesn't reach subscribers.
- [ ] **1.7 UrlGuard ranges** `lib/nous/tools/url_guard.ex:33-52` — add `198.18.0.0/15` + IETF test nets to the blocklist; cover with tests.

---

## Phase 2 — Correctness fixes `[elixir]` `[otp]`

- [ ] **2.1 `get_tool_field/2` falsy `||`** `lib/nous/agent_runner.ex:1276`
  Replace `Map.get(call, field) || Map.get(call, to_string(field))` with `Map.fetch/2` then string-key fallback, so a legit `false`/`0`/`""` atom-keyed arg isn't overwritten. First grep call sites to confirm none rely on the coalescing.

- [ ] **2.2 async load caller block** `lib/nous/agent_server.ex:543`
  Ensure `GenServer.reply(from, …)` always runs even if the load task raises (wrap the task body so an error path still replies with `{:error, reason}`); otherwise the caller blocks until `GenServer.call` timeout.

- [ ] **2.3 rate-limit acquire TOCTOU** `lib/nous/agent_runner.ex:1206-1217`
  Drop the `Process.alive?/1` pre-check; wrap `RateLimiter.acquire/3` in `try/catch :exit, _` → return `nil`/proceed-unlimited if the limiter is gone, instead of letting `{:noproc,…}`/timeout propagate into the agent loop.

- [ ] **2.4 `claims ++ [new_claim]` O(n)** `lib/nous/teams/shared_state.ex:190`
  Prepend the claim and reverse on read (`get_claims`), matching the discoveries fix already at L149.

### Phase 2 suggestions
- [ ] **2.5 `async_nolink` `{ref, result}` fall-through** `lib/nous/agent_server.ex:404` — switch to `Task.Supervisor.start_child/2` (results already flow via explicit `send/2`), or add a dedicated `handle_info({ref, _}, %{current_task: %Task{ref: ref}} = s)` clause. Keep `Task.shutdown` semantics intact.
- [ ] **2.6 Right-leaning iodata** `lib/nous/agent_runner.ex:1411,1413` — accumulate with `[chunk | acc]` then `Enum.reverse |> IO.iodata_to_binary`.
- [ ] **2.7 No-op `Stream.map(& &1)`** `lib/nous/agent_runner.ex:374` — remove.
- [ ] **2.8 11-arg `run_tool_with_hooks/11`** `lib/nous/agent_runner.ex:866` — bundle related args into a struct/map (Credo tolerates it now, maintainability hazard).
- [ ] **2.9 Drop needless `:ets.insert` `try/rescue`** `lib/nous/persistence/ets.ex:56-65` — let a genuinely bad table reference crash + restart rather than masking as `{:error, {:ets_insert_failed, …}}`.

---

## Phase 3 — ETS table ownership `[otp]` (DESIGN DECISION FIRST)

> **Gate:** Confirm whether KB/Decisions store data is meant to survive across agent runs.
> - If **ephemeral by design** → reduce to: doc the lifetime + switch `:public`→`:protected`, close out S-1 by serializing writes only if races matter. Skip the GenServer rework.
> - If **meant to persist** → implement a supervised owner.

- [ ] **3.1 KB/Decisions `:public` table ownership** `lib/nous/knowledge_base/store/ets.ex:24-29`, `lib/nous/decisions/store/ets.ex:30-31`
  Tables are owned by the transient per-run process (no `heir`, no supervision) and `:public`. Per the gate: either a supervised owner GenServer (reads/writes routed through it, or `:heir` hand-off) **or** documented-ephemeral + `:protected`.
- [ ] **3.2 Non-atomic KB slug index** `lib/nous/knowledge_base/store/ets.ex:92-103`
  `store_entry/2` does 4 separate ETS ops (fetch → delete old slug → insert entry → insert slug); a crash/concurrent write leaves the index inconsistent. Serialize through the owner from 3.1 (folds in). If gate → ephemeral, at minimum reorder so the entry insert precedes slug-index mutation.

---

## Phase 4 — Test quality `[test]`

- [ ] **4.1 Flaky `Process.sleep`** `test/nous/agent_runtime_fixes_test.exs:84-93`, `test/nous/agent_server_test.exs:134,141,169,176,202,210,353,392,421`
  Replace sleep/poll with a synchronous `GenServer.call(pid, :noop)` after `send`, or have the server message the test so `assert_receive _, 2000` serializes deterministically.
- [ ] **4.2 Tautological assertion** `test/nous/tools/coding_tools_test.exs:315-322`
  `assert match?({:ok,_},r) or match?({:error,_},r)` passes for any value. Assert specific safe behavior (e.g. injected `--debug` is treated as a pattern, not a flag).
- [ ] **4.3 `refute_received` vacuous** `test/nous/permissions_enforcement_test.exs:130-132`
  Change to `refute_receive :tool_ran, 200` so an async `send` that lands late isn't missed.
- [ ] **4.4 Unsupervised named Agent** `test/nous/permissions_enforcement_test.exs:86`, `test/nous/agent_runtime_fixes_test.exs:37`
  Use `start_supervised!` so a crash before `on_exit` doesn't leak the named Agent → `{:already_started, _}` next run.
- [ ] **4.5 DNS-rebind coverage gap** `test/nous/tools/url_guard_test.exs`
  Add the hostname-safe-at-validation / private-at-request case via a mock resolver, exercising `validate_pinned/2`'s hostname contract (today only literal IPs are tested).

### Phase 4 suggestions
- [ ] **4.6** Drop needless `async: false` `test/nous/tools/path_guard_test.exs:2` (unique tmp dir per run).
- [ ] **4.7** Unique telemetry handler IDs + `:telemetry.detach` in `on_exit` `test/nous/tool_executor_test.exs:113-121` (async-safe).
- [ ] **4.8** Membership asserts instead of exact-list on singleton ETS `test/nous/persistence/ets_test.exs:53-60`.
- [ ] **4.9** Add encoded/decimal SSRF cases to `url_guard_test.exs` (`0x7f000001`, `2130706433`, `169.254.169.254%2F`).

---

## Risks / self-check
- **What could break?** Phase 1.1 (PathGuard realpath) and 2.2 (reply-on-crash) touch hot paths — rely on the full test suite + the new regression tests per task. Phase 3 is the only structural change; the design gate keeps it from ballooning.
- **What's uncertain?** KB/Decisions intended lifetime (Phase 3 gate) and whether any `get_tool_field` caller depends on falsy coalescing (2.1 grep). Resolve both before editing.
- **What's explicitly out?** Dialyzer (PLT not rebuilt during review) — optionally run `mix dialyzer` once after Phase 2.

## Suggested sequencing
Phases are independent; recommended order **1 → 2 → 4 → 3** (do the structural ETS work last, after the gate is answered). Suggestions within each phase are optional and can be skipped per-item.
