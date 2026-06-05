# Code Review — Commit #59 "Security, bug, performance & docs audit pass"

**Scope:** `HEAD~1..HEAD` (67 files, +2392/−455). Reviewed because local `master` == `origin/master` with no uncommitted work, so the last merged commit is the natural target.
**Agents:** security, elixir-idioms, otp, testing, iron-laws, verification (run directly).
**Date:** 2026-06-04

## Verdict: ✅ PASS WITH WARNINGS

The diff compiles clean, all tests pass, Credo strict is silent, and the headline security controls (SSRF/path-traversal/RCE gate) are genuinely well-built and verified. No confirmed BLOCKER was found in **new** code. There are a handful of warnings worth addressing, one unconfirmed possible regression to verify (double `before_request` hook), and real **pre-existing** atom-exhaustion DoS issues the audit missed.

## Verification (run directly — all green)

| Check | Result |
|-------|--------|
| `mix compile --warnings-as-errors` | ✅ PASS |
| `mix format --check-formatted` | ✅ PASS |
| `mix credo --strict` | ✅ PASS (3589 mods/funs, no issues) |
| `mix test` | ✅ PASS (1806 passed, 0 failed, 101 excluded) |
| `mix dialyzer` | ⏭️ SKIP (PLT stale; not rebuilt) |

---

## Highest-priority items

### ⚠️ Verify: double `Plugin.run_before_request` in streaming path (OTP W-4)
`lib/nous/agent_runner.ex` — `run_before_request` appears in the new streaming top-level **and** in `run_iteration` (~line 591). If both fire per streaming request, plugin side-effects (memory writes, telemetry, tool filtering) double up. Unconfirmed — needs call-tree tracing. **If confirmed, this is a functional regression and escalates the verdict.**

### 🔴 PRE-EXISTING (outside diff) — atom-exhaustion DoS from YAML eval input
Real node-wide DoS (atoms never GC'd), flagged for completeness even though not in this commit:
- `lib/nous/eval/runner.ex:234` — `String.to_atom(k)` on YAML `agent_config` keys.
- `lib/nous/eval/evaluators/schema.ex:234,255` — `String.to_atom(field)` on YAML `expected.required_fields`.
- Contrast `lib/nous/eval/test_case.ex:208` which explicitly comments *"NEVER use String.to_atom/1 here."*
- **Fix:** `String.to_existing_atom/1` with an `ArgumentError` rescue→keep-binary fallback, matching `test_case.ex`.

---

## Security (no blockers; controls verified sound)

**Verified correct:** dual-stack A+AAAA resolution, v4-mapped/NAT64 normalization, `redirect: false` in both HTTP backends, web_fetch per-hop re-validate+pin with SNI preserved, file_grep `--regexp`/`--` flag-injection guard + absolute `rg` path, LLMJudge fail-closed + `to_existing_atom`, Permissions deny-by-default allowlist fix.

- **WARNING — PathGuard TOCTOU** `tools/path_guard.ex:103-157`: validates then the tool opens the raw arg independently; an earlier in-run FileWrite could swap a component for a symlink to `/etc`. Fix: tools must open the canonical `real_path` PathGuard computed (or `O_NOFOLLOW`), never the raw arg.
- **WARNING — web_fetch unpinned fallback** `tools/web_fetch.ex:128`: `pin_connection(_,_,nil)` fetches with no IP pin / raw hostname. Safe only because `nil` can't occur without `allow_private_hosts`. Fix: return `{:error,…}` on `nil` unless private hosts explicitly allowed, so a future flag flip can't silently reopen DNS-rebind.
- **WARNING — pattern guard is bypassable** `plugins/input_guard/strategies/pattern.ex:38-72`: regex/NFKC matching evades trivially (synonyms, leetspeak, splitting). Fix: document as best-effort; never treat `:safe` as authorization.
- **SUGGESTION — ReDoS** `tools/file_grep.ex:114-123`: LLM-controlled regex run per-line with no timeout in the Elixir fallback. rg path is safe. Cap file size / enforce tool timeout.
- **SUGGESTION — telemetry leakage** `tool_executor.ex:170-181,306-317`: emits full `reason`/`stacktrace`; a tool error carrying a secret reaches subscribers. Redact like `truncate_for_log`.
- **SUGGESTION — UrlGuard ranges** `tools/url_guard.ex:33-52`: add `198.18.0.0/15` + IETF test nets.

## Elixir idioms / correctness

- **WARNING — `get_tool_field/2` falsy-unsafe `||`** `agent_runner.ex:1277`: a legit `false`/`0`/`""` atom-keyed arg falls through to the string-key lookup. Use `Map.fetch/2` then fall back.
- **WARNING — async load task can block caller** `agent_server.ex:543`: unsupervised `start_child` holds a `from`; a raise before `GenServer.reply/2` blocks the caller until call timeout. Wrap so `reply` always runs.
- **WARNING — system message appended at tail** `plugins/memory.ex:539`: `ctx.messages ++ [memory_msg]` puts a `:system` msg last; some providers expect system at position 0. Insert after existing system msgs instead. *(Verify how provider serialization handles system extraction before acting.)*
- **SUGGESTION — `async_nolink` `{ref, result}` falls through to catch-all** `agent_server.ex:404`: benign today (results go via explicit `send/2`), but noise + fragile. Prefer `start_child/2`, or add a dedicated `handle_info({ref, _}, …)` clause.
- **SUGGESTION — right-leaning iodata accumulation** `agent_runner.ex:1411,1413`: `[acc.text | text]` is valid iodata but depth-proportional. Prefer `[text | acc.text]` + reverse.
- **SUGGESTION — no-op `Stream.map(& &1)`** `agent_runner.ex:374`: remove.
- **SUGGESTION — 11-arg `run_tool_with_hooks/11`** `agent_runner.ex:866`: bundle related args (Credo passed, so config-tolerated, but a maintainability hazard).

## OTP / ETS / process

- **WARNING (was reported BLOCKER) — ad-hoc TableOwner start** `persistence/ets.ex:122-132` & `workflow/checkpoint.ex:172`: `owner/0` does `whereis → start_link` outside supervision when the app supervisor isn't up (tests). *Note: the "leaked process" claim is overstated — `start_link` returning `{:error, {:already_started, _}}` does not leave a process.* Guard the ad-hoc path to test-only or raise when the supervised instance is absent.
- **WARNING — KB/Decisions `:public` tables owned by transient process** `knowledge_base/store/ets.ex:24-29`, `decisions/store/ets.ex:30-31`: tables die with the per-run process (no `heir`, no supervision), silently dropping data across runs; `:public` allows any process to overwrite. **Largely PRE-EXISTING** — only the new `slugs` table extends the pattern. Real fix: a supervised owner GenServer (or `:heir`). Confirm whether per-run ephemerality is intended.
- **WARNING — rate-limit acquire TOCTOU** `agent_runner.ex:1206-1217`: `Process.alive?/1` then `acquire/3` can hit `{:noproc,…}`/timeout that isn't caught. Drop the alive check; `try/catch :exit` → proceed unlimited if limiter gone.
- **WARNING — `claims ++ [new_claim]` O(n)** `teams/shared_state.ex:190`: discoveries were fixed to prepend; claims weren't. Make consistent.
- **SUGGESTION — non-atomic KB slug index update** `knowledge_base/store/ets.ex:92-103`: 4 separate ETS ops; same root fix as above (serialize through a GenServer).
- **SUGGESTION — unnecessary `try/rescue` around `:ets.insert`** `persistence/ets.ex:56-65`: hides real bugs; let it crash and supervisor restart.
- **SUGGESTION — `zip_input_on_exit` is Elixir 1.17+** `workflow/engine/parallel_executor.ex:67`: verify min Elixir in mix.exs (silently ignored on older).

## Tests

- **WARNING — flaky `Process.sleep` patterns** `agent_runtime_fixes_test.exs:84-93` (poll loop) and `agent_server_test.exs:134,141,169,176,202,210,353,392,421` (`send` then sleep). Replace with a synchronous `GenServer.call`/`assert_receive` to serialize deterministically.
- **WARNING — tautological assertion** `coding_tools_test.exs:315-322`: `assert match?({:ok,_},r) or match?({:error,_},r)` passes for any value — would pass even if the glob-flag-injection fix were reverted. Assert specific safe behavior.
- **WARNING — `refute_received` vacuous** `permissions_enforcement_test.exs:130-132`: checks mailbox instantly; async `send` may not have landed. Use `refute_receive :tool_ran, 200`.
- **WARNING — unsupervised named Agent** `permissions_enforcement_test.exs:86`, `agent_runtime_fixes_test.exs:37`: `Agent.start_link(name: …)` without `start_supervised!` leaks on crash → `{:already_started,_}` next run.
- **WARNING — DNS-rebind path untested** `url_guard_test.exs`: `validate_pinned/2` only tested with literal IPs; the safe-at-validation/private-at-request case is unexercised (needs a mock resolver).
- **SUGGESTION — `async: false` likely unneeded** `path_guard_test.exs:2` (unique tmp dir per run); telemetry handler-ID collisions `tool_executor_test.exs:113-121` (use `unique_integer` + detach); fragile exact-list assert on singleton ETS `persistence/ets_test.exs:53-60` (assert membership); add URL-encoded/decimal SSRF cases (`0x7f000001`, `2130706433`, `169.254.169.254%2F`).

---

## Notes on filtering
- Two reported "BLOCKERs" from the elixir agent (`async_nolink` fall-through, iodata accumulation) were downgraded — both are valid-iodata / benign by the agent's own analysis.
- Three reported "BLOCKERs" from the OTP agent were downgraded: one overstated (`start_link` leak), two are pre-existing `:public`-table patterns.
- The iron-law atom-DoS BLOCKERs are real but live **outside** this commit's diff → marked PRE-EXISTING.
