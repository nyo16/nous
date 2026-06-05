# Scratchpad — Audit-Pass Review Follow-up Plan

## Source
- Review: `.claude/plans/review/reviews/audit-pass-review.md`
- Triage: `.claude/plans/review/reviews/review-triage.md`
- Planning from review/triage → per Iron Law #7, NO research agents spawned; findings are the research.

## Verification-gate results (resolved during planning — NOT bugs)
- **Hook double-fire (OTP W-4): FALSE POSITIVE.** `agent_runner.ex` `run_stream/3` (L293) calls `Plugin.run_before_request` once at L312, then goes straight to `stream_with_fallback`. It does NOT call `run_iteration` (the L592 call lives on the separate non-streaming `run` path). No double-fire. → Verdict PASS holds.
- **`:system` message at tail (Elixir W-5): FALSE POSITIVE.** `memory.ex:540` appends a `:system` message. Anthropic (`messages/anthropic.ex:26` `Enum.split_with(&is_system?/1)`) and Gemini extract ALL system messages position-independently; OpenAI (`messages/openai.ex:28`) maps each inline and the API accepts system role at any position. Safe.
- **`zip_input_on_exit` Elixir 1.17 (OTP S-3): RESOLVED.** `mix.exs:11` requires `~> 1.18`. Option is available. No action.

## Decisions
- Single plan (not split): all items are small, independent, mostly localized fixes within one library. No cross-context coordination needed.
- Atom-DoS (eval/runner.ex, eval/evaluators/schema.ex) kept IN scope per user, though outside the original commit diff — it's a genuine Iron Law #10 DoS and cheap to fix.
- ETS ownership (KB/Decisions :public tables) flagged as needs-design-decision: confirm whether per-run ephemerality is INTENDED before reworking into a supervised owner. The non-atomic slug index (S-1) folds into the same fix.

## Open questions for implementation
- KB/Decisions store lifetime: is data meant to survive across agent runs? If intentionally per-run/ephemeral, downgrade Phase 3 to a doc + `:protected` access change only.
- get_tool_field: confirm no caller relies on the current `||` coalescing of legit-falsy values (search call sites).

## Dead ends / notes
- N/A
