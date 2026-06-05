# Progress — Audit-Pass Follow-up (/phx:full)

Branch: `fix/audit-pass-followup` (off master)
State: COMPLETED (implemented, verified, reviewed, compounded)

## Review result
- security-analyzer: all 5 areas CORRECT, no BLOCKER/WARNING (1 low SUGGESTION = documented TOCTOU residual).
- elixir-reviewer: both initial "BLOCKERs" self-reclassified to CORRECT; net 1 WARNING (fail-open observability) + 1 comment fix — both applied (commit: review fixes).
- Solutions captured: .claude/solutions/audit-pass-followup.md

## Verification (final, all green)
- compile --warnings-as-errors: PASS
- format --check-formatted: PASS
- credo --strict: PASS (no issues)
- test: PASS (1810 passed, 0 failed, 101 excluded; +4 new tests)

## Commits
1. Phase 1 — security hardening (`0b9a3ea`)
2. Phase 2 — correctness fixes (`6d32178`)
3. Phase 4 — test quality (`5636700`)
4. Phase 3 — ETS ownership docs + slug order (committed)

## Verify-first gate results (resolved as NON-ISSUES during planning)
- Hook double-fire: FALSE POSITIVE (run_stream calls run_before_request once; doesn't enter run_iteration).
- :system message at tail: FALSE POSITIVE (providers extract system position-independently).
- zip_input_on_exit: RESOLVED (Elixir ~> 1.18).

## Done
Phase 1: PathGuard canonical real_path + TOCTOU doc; web_fetch fail-closed; pattern best-effort doc;
  atom-DoS (eval/runner + evaluators/schema) + regression test; file_grep ReDoS timeout;
  tool_executor telemetry-redaction doc; UrlGuard 198.18/15 + RFC5737 ranges.
Phase 2: get_tool_field Map.fetch; rate-limit safe_acquire (catch exit, fail open) + drop Process.alive?;
  agent_server load reply-on-crash; async_nolink {ref,_} absorb clause; claims O(1) prepend+reverse;
  flat iodata accumulation; drop needless persistence ets try/rescue.
Phase 4: removed redundant sleeps (FIFO/flush), refute_receive, start_supervised!, non-tautological glob
  assertion, unique telemetry handler IDs + detach, membership asserts, encoded-IP SSRF cases, async path_guard.
Phase 3: documented intentional run-scoped ETS ownership (KB + Decisions); safer slug-index write order.

## Deferred (with reason — NOT silently dropped)
- 2.8 bundle 11-arg run_tool_with_hooks/11: pure-readability refactor, broad internal edit surface,
  zero behavioral gain, Credo already passes. Deferred to avoid param-swap risk in autonomous mode.
- 4.5 DNS-rebind mock-resolver test: full rebind scenario needs UrlGuard.resolve_host to be injectable
  (a production change for testability). The pin CONTRACT (validate_pinned returns the IP to connect to)
  is already covered by existing tests; deferred the deeper mock-resolver integration test.

## Open decision baked in
- Phase 3 gate answered: KB/Decisions ETS is ephemeral-by-design; :public required for cross-process
  tool execution. Documented rather than switched to :protected (would break cross-process writes).
