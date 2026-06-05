# Triage — Commit #59 Audit Pass Review

**Source review:** `.claude/plans/review/reviews/audit-pass-review.md`
**Decision:** Verify-then-fix the two uncertain items; fix all others directly. Atom-DoS kept in scope (not deferred).
**Date:** 2026-06-04

## Fix Queue

### 🔍 Verify first, fix only if confirmed
- [ ] **Hook double-fire** `lib/nous/agent_runner.ex` — trace streaming path; confirm whether `Plugin.run_before_request` fires in both the streaming top-level and `run_iteration` (~L591). Fix only if real (would otherwise double memory writes/telemetry/tool-filtering). *If confirmed → escalates overall verdict.*
- [ ] **`:system` message placement** `lib/nous/plugins/memory.ex:539` — confirm provider serialization actually requires system at position 0 before changing `ctx.messages ++ [memory_msg]` to insert-after-system. Fix only if a provider rejects/misroutes tail system msgs.

### 🔴 Security (in-diff)
- [ ] **PathGuard TOCTOU** `lib/nous/tools/path_guard.ex:103-157` — file tools must open the canonical `real_path` (or `O_NOFOLLOW`), never the raw arg.
- [ ] **web_fetch unpinned fallback** `lib/nous/tools/web_fetch.ex:128` — return `{:error,…}` on `nil` pin unless `allow_private_hosts` explicitly set.
- [ ] **Pattern guard best-effort doc** `lib/nous/plugins/input_guard/strategies/pattern.ex:38-72` — document as non-authoritative; never treat `:safe` as authorization.

### 🔴 Security — pre-existing (OUT OF DIFF, scope expansion, kept in)
- [ ] **Atom-exhaustion DoS** `lib/nous/eval/runner.ex:234`, `lib/nous/eval/evaluators/schema.ex:234,255` — replace `String.to_atom/1` on YAML input with `String.to_existing_atom/1` + `ArgumentError`→keep-binary fallback (match `eval/test_case.ex:208` pattern).

### 🟠 Elixir / OTP correctness (in-diff)
- [ ] **`get_tool_field/2` falsy `||`** `lib/nous/agent_runner.ex:1277` — use `Map.fetch/2` then fall back to string key.
- [ ] **async load caller block** `lib/nous/agent_server.ex:543` — ensure `GenServer.reply/2` runs even if the load task raises.
- [ ] **rate-limit acquire TOCTOU** `lib/nous/agent_runner.ex:1206-1217` — drop `Process.alive?/1`; `try/catch :exit` around `acquire/3`, proceed unlimited if limiter gone.
- [ ] **KB/Decisions `:public` table ownership** `lib/nous/knowledge_base/store/ets.ex:24-29`, `lib/nous/decisions/store/ets.ex:30-31` — supervised owner GenServer or `:heir`; confirm whether per-run ephemerality is intended first.
- [ ] **`claims ++ [new_claim]` O(n)** `lib/nous/teams/shared_state.ex:190` — prepend + reverse on read, matching the discoveries fix.

### 🟠 Tests
- [ ] **Flaky `Process.sleep`** `test/nous/agent_runtime_fixes_test.exs:84-93`, `test/nous/agent_server_test.exs:134,141,169,176,202,210,353,392,421` — replace with synchronous `GenServer.call`/`assert_receive`.
- [ ] **Tautological assertion** `test/nous/tools/coding_tools_test.exs:315-322` — assert specific safe behavior, not `{:ok,_} or {:error,_}`.
- [ ] **`refute_received` vacuous** `test/nous/permissions_enforcement_test.exs:130-132` — `refute_receive :tool_ran, 200`.
- [ ] **Unsupervised named Agent** `test/nous/permissions_enforcement_test.exs:86`, `test/nous/agent_runtime_fixes_test.exs:37` — `start_supervised!`.
- [ ] **DNS-rebind gap** `test/nous/tools/url_guard_test.exs` — add hostname safe-at-validation/private-at-request case via mock resolver.

### 🔵 Suggestions
- [ ] **Security:** file_grep ReDoS timeout/size cap (`tools/file_grep.ex:114-123`); tool_executor telemetry secret redaction (`tool_executor.ex:170-181,306-317`); UrlGuard add `198.18.0.0/15` + IETF test nets (`tools/url_guard.ex:33-52`).
- [ ] **Elixir:** `async_nolink`→`start_child` or absorb `{ref,_}` (`agent_server.ex:404`); iodata prepend+reverse (`agent_runner.ex:1411,1413`); remove no-op `Stream.map(& &1)` (`agent_runner.ex:374`); bundle 11-arg `run_tool_with_hooks/11` (`agent_runner.ex:866`).
- [ ] **OTP:** non-atomic KB slug index (`knowledge_base/store/ets.ex:92-103`, same fix as table ownership); drop needless `:ets.insert` `try/rescue` (`persistence/ets.ex:56-65`); verify Elixir 1.17 for `zip_input_on_exit` (`workflow/engine/parallel_executor.ex:67`).
- [ ] **Tests:** drop needless `async: false` (`path_guard_test.exs:2`); unique telemetry handler IDs + detach (`tool_executor_test.exs:113-121`); membership asserts on singleton ETS (`persistence/ets_test.exs:53-60`); encoded/decimal SSRF cases (`url_guard_test.exs`).

## Skipped
_(none — all findings accepted)_

## Deferred
_(none)_
