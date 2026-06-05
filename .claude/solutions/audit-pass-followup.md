---
title: Audit-pass follow-up — security/OTP/test hardening patterns
date: 2026-06-05
tags: [security, ssrf, path-traversal, ets, otp, rate-limiting, atom-dos, testing, telemetry]
area: lib/nous
branch: fix/audit-pass-followup
status: solved
---

# Audit-pass follow-up: reusable solutions

Patterns captured while fixing review findings on commit #59. Each is generic enough to reapply.

## 1. Return the canonical (symlink-resolved) path from a path guard
**Problem:** A path guard that validates then returns the *unresolved* arg lets callers re-traverse an attacker-swappable symlink (TOCTOU).
**Solution:** Have `validate/2` return the fully symlink-resolved `real_path` (`PathGuard.ensure_no_symlink_escape/2` now returns `{:ok, real_path}`); callers open *that*.
**Gotcha — idempotency:** Re-validating an already-resolved path (e.g. `file_glob`/`file_grep` re-checking wildcard results) breaks the lexical `ensure_within` check on systems where the workspace root is itself symlinked (macOS `/var`→`/private/var`). Fix: `ensure_within` accepts the path if it's within the raw root **or** the resolved root.
**Residual:** Elixir's `:file` API has no `O_NOFOLLOW`, so a swap between validate-and-open isn't fully closed — document it; mitigate with a dedicated per-session `workspace_root`.
**Test gotcha:** assert the returned path *points at the right file* (`File.read!/1`, `Path.basename/1`), not exact string equality — the canonical form differs from `Path.join(root, _)` under symlinked tmp dirs.

## 2. Atom-exhaustion DoS from user/YAML input
**Problem:** `String.to_atom/1` on YAML-derived field/key names is an unbounded-atom DoS (atoms are never GC'd).
**Solution:** `String.to_existing_atom/1` with `rescue ArgumentError ->` falling back to the binary (lookup misses → treated as absent) or dropping the key. Mirror the existing `eval/test_case.ex` `atom_key_or_binary/1` pattern. The plugin's `iron-law-verifier` PostToolUse hook catches stray `String.to_atom` automatically.

## 3. TOCTOU on a resolved-then-called process (rate limiter)
**Problem:** `Process.alive?(pid)` then `GenServer.call(pid, ...)` races — a `{:noproc,_}`/timeout exit crashes the caller.
**Solution:** Drop the `alive?` pre-check (it only narrows the race); wrap the call in `try ... catch :exit, _ -> {:error, :unavailable}` and **fail open** (proceed without the limiter). Make fail-open observable: `Logger.warning` + `:telemetry.execute([:nous, :rate_limiter, :unavailable], ...)` — a silent fail-open hides a dead dependency until cost metrics spike.

## 4. async_nolink fire-and-forget: absorb the `{ref, result}` reply
**Problem:** `Task.Supervisor.async_nolink` delivers the task's return value as `{ref, result}`; if the task communicates via explicit `send/2` instead, that message falls through to the GenServer catch-all.
**Solution:** Add `handle_info({ref, _result}, %{current_task: %Task{ref: ref}} = state) when is_reference(ref)` → `Process.demonitor(ref, [:flush])` + clear the task slot. This clause handles *normal* completion; the `:DOWN` clause then only fires on *abnormal* exit (the `[:flush]` purges the normal-exit `:DOWN`).

## 5. Always-reply from an async GenServer.reply task
**Problem:** A task spawned to answer a `GenServer.call` (via `start_child` + `GenServer.reply/2`) wedges the caller until timeout if `backend.load`/deserialize **raises** instead of returning `{:error, _}`.
**Solution:** Wrap the task body in `try/rescue/catch` and `GenServer.reply(from, {:error, ...})` on every failure path. (Residual: a `Process.exit(pid, :kill)` bypasses rescue — would need `async_nolink` + monitored reply to fully close.)

## 6. Run-scoped ETS ownership is a valid design — document it
`:public` unnamed ETS tables threaded through `ctx` (KB / Decisions stores) are **intentionally** per-run/ephemeral and shared across the agent loop + tool-execution processes. `:public` (not `:protected`) is required for cross-process writes; access is gated by *possession of the table ref*, not ETS mode. Before "fixing" such tables to `:protected`/supervised, confirm the intended lifetime — document the model instead. For multi-op writes, order so a torn write degrades to a miss (write entry → point new slug → delete old slug), never a wrong result.

## 7. Deterministic ExUnit waits (kill the `Process.sleep`)
- `send`/`cast` then a `GenServer.call` (e.g. `get_context`): the call already serializes via FIFO mailbox — **delete the sleep**.
- Cross-process side effect (e.g. async handler does a synchronous persistence call): flush with a `call` to the same server, then read the external store.
- "Stays alive" assertions: `Process.monitor` + `refute_receive {:DOWN, ...}, t` beats `sleep + alive?`.
- Genuinely cross-process async convergence with no PubSub (disabled in tests): a bounded poll **is** the correct tool — the bound only sets the failure deadline.
- Telemetry handlers in `async: true`: unique IDs (`System.unique_integer`) + `:telemetry.detach` in `terminate/2` (trap exits) to avoid collisions/leaks.
- Named test helper Agents: `start_supervised!` (auto-torn-down) over bare `start_link` (leaks the name on crash → `{:already_started, _}`).

## 8. SSRF encoded-IP coverage
The BEAM resolver expands decimal (`2130706433`), hex (`0x7f000001`), and octal (`0177.0.0.1`) integer hosts to their real address, so an IP-range blocklist (`address_blocked?/1`) catches them — add them as regression tests asserting `{:error, _}`. Also block `198.18.0.0/15` (benchmarking) + RFC 5737 test-nets.
