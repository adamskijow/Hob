<!-- SPDX-License-Identifier: MIT -->
# App Store runtime-contract increment audit

Date: 2026-07-11. Parent: merged model-readiness PR #10.

## Customer outcome

This increment does not expose an unfinished scheduler to customers. It creates
the first tested path for the Store edition to preserve Hob's defining safety
rule: the model proposes typed actions, while deterministic code resolves dates,
validates targets and confidence, applies one turn, and makes it undoable.

## Increment audit

| Criterion | Evidence | Assessment |
| --- | --- | --- |
| User onboarding | No new setup checkbox or ready state is exposed. Background delivery remains locked while the native core is in-memory and incomplete | Honest. A customer cannot mistake contract progress for a usable task service. |
| Usability | The contract preserves the original message for future literal backstops and distinguishes applied, clarification, confirmation, rejected, and no-change outcomes | Strong semantic foundation. Customer wording and confirmation-resume UI are not connected yet. |
| Customer experience | Capture, exact correction, multi-action turns, and repeated undo share expected task state across Python and Swift | This starts the familiar Hob loop instead of shipping a separate conventional scheduler. It is not yet a customer journey. |
| LLM differentiation | Model actions remain proposals. Swift owns tomorrow and weekday arithmetic, target existence, confidence thresholds, mutation ordering, and undo | Preserves the product doctrine. The model cannot mark an ambiguous or low-confidence request as completed work. |
| Bugs and feature robustness | Requests are protocol-versioned and correlated; messages, actions, labels, raw text, ids, timezone, and time formats are bounded or validated. Unsupported versions/actions, mixed undo, ambiguous dates, invalid timezone/time, low confidence, and missing targets change nothing | Safe first slice. One turn is prepared fully before mutations apply. The in-memory undo history is bounded to 100 batches. |
| Privacy | Fixtures are synthetic. Runtime requests are value types with no I/O or logging. No Telegram token, Calendar title, live task, or database enters the corpus | Appropriate. Persistence and diagnostic redaction need separate audits when added. |
| Accessibility | No new customer control is introduced | No regression surface, but also no accessibility evidence for task interaction. |
| Operations | The pure Swift core compiles in both `Hob.app` and `HobAgent.app`; Python and Swift read the same fixture in CI | Drift is now visible for the covered slice. The helper remains health-only. |

## Covered shared behavior

1. Capture with deterministic tomorrow resolution.
2. Multiple captures followed by repeated batch undo.
3. One atomic turn that completes, drops, and reschedules exact task ids.
4. Deterministic next-weekday resolution.
5. Ambiguous date clarification without mutation.
6. Low-confidence reference confirmation without mutation.
7. Missing target clarification without mutation.

## Known gaps and release blockers

1. Task state and undo history are in-memory. There is no App Group SQLite
   transaction, schema migration, crash recovery, action log, inbox, or outbox.
2. The model bridge, runtime contract, Telegram edge, and helper lifecycle are
   not connected. No real Store task can be captured yet.
3. The fixture does not cover recurrence, scheduling constraints, deadlines,
   dependencies, notes, waiting, reminders, queries, settings, planning,
   adoption, Calendar, pending confirmations, or recovery.
4. Exact-id and list-position references are the only native references. Fuzzy
   target resolution and every literal safety backstop remain Python-only.
5. Mixed valid and ambiguous action batches need an explicit shared policy.
   Swift currently fails the entire turn closed; parity must be decided and
   fixture-tested before activation.
6. Undo is bounded and memory-only. Restart persistence and multi-year storage
   behavior remain unproven.
7. The fixture validates state and safety disposition, not customer-facing copy,
   VoiceOver output, Telegram buttons, timing, or background delivery.

## Decision

Accept this as a safe parity seed. Do not activate the Store helper or describe
the Store edition as functional. The next increment should add durable App
Group storage with atomic turn and undo persistence, then expand fixtures around
restart, corruption, migration, and failed-turn recovery before connecting the
model or Telegram edges.
