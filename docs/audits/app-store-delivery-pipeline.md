<!-- SPDX-License-Identifier: MIT -->
# App Store delivery-pipeline increment audit

Date: 2026-07-12. Parent: merged durable-state PR #12.

## Customer outcome

The Store runtime can now record a typed inbound turn before applying it, commit
the task mutation and compact outbound receipt together, replay an interrupted
turn after restart, and recognize a repeated request without applying it twice.
Settings and first-run setup expose content-free storage and queue health. If the
primary state is corrupt and the previous copy verifies, the owner can restore
it through an explicit confirmation instead of Terminal.

Background activation remains locked. No Telegram edge calls this coordinator
yet, so this increment does not claim that the Store edition can deliver a real
message.

## Increment audit

| Criterion | Evidence | Assessment |
| --- | --- | --- |
| User onboarding | Setup includes Local task safety; Settings has a Storage tab with plain-language status, waiting-to-process and waiting-to-send counts, verified-copy status, refresh, and confirmed recovery | The first-run promise is more inspectable and recovery no longer requires Terminal. It still needs the complete Telegram pairing journey and a fresh-install usability rehearsal. |
| Usability | Stable messages distinguish healthy, new, recoverable, update-required, and unavailable state. Recovery is offered only when the primary failure category is recoverable and the previous copy verifies | Actionable without exposing paths or task text. A future increment must add export and a recovery preview. |
| Customer experience | A repeated request returns the existing turn result and never repeats its mutation. Pending turns and replies retain arrival order across restart | Strong local behavior. The Telegram transport is not connected, and a send-success/process-crash window can still produce a repeated chat reply because Telegram does not provide Hob an atomic send-and-mark operation. |
| Bugs and feature robustness | State v2 validates queue relationships, ids, sequence monotonicity, timestamps, retry metadata, action bounds, status transitions, and delivery summaries. Version 1 migrates explicitly; future versions fail closed | Covers duplicate delivery, conflicting envelopes, crash replay, order, poison quarantine, retry, idempotent delivery marking, migration, privacy-safe status, and unsafe recovery regressions. Queue compaction and long-run sizing remain unproven. |
| LLM-native differentiation | Model output remains a typed proposal; the deterministic coordinator owns idempotency, exact mutation, confidence holds, ordering, replay, and delivery state | This is the reliability boundary that lets conversational replanning behave like a durable assistant instead of a text-generating scheduler. Broader planning parity remains incomplete. |
| Privacy and safety | The inbox retains the original typed request only in private local App Group state for replay. The outbox stores correlation, disposition, mutation kinds, and affected ids rather than another copy of all task or chat text. UI status contains counts only | Appropriate local retention for this stage. Retention limits, deletion, export, privacy manifest, and Store disclosure evidence remain release blockers. |
| Recovery | Mutation, completed receipt, and pending outbound record share one atomic state replacement. A receipt committed before a crash replays; a completed turn is never applied again. Poison records can be explicitly quarantined without blocking later turns | Good deterministic recovery. Live kill, sleep/wake, disk-full, and multi-process exercises remain. |
| Accessibility | Storage state uses native labels, buttons, alert roles, and an explicit recovery accessibility hint. No status relies on color alone | Structurally sound, but manual VoiceOver, keyboard-only, text-size, and contrast evidence is still required. |

## Verified paths

1. A pending receipt survives runtime reconstruction, applies once, creates one
   compact outbound record, and becomes a no-op on duplicate receipt.
2. A conflicting payload with the same request id fails closed without another
   task or reply.
3. Two interrupted turns replay and enter the outbox in original sequence.
4. An explicitly quarantined poison turn does not mutate tasks or block the next
   pending turn.
5. Delivery failures persist a bounded stable code and attempt count. Delivery
   marking is idempotent and clears the active retry warning.
6. A v1 task document migrates to v2. Future state, broken relationships,
   corruption, oversize data, and unsafe paths continue to fail closed.
7. Storage inspection and encoded pipeline status reveal counts and conditions,
   not messages, labels, ids, or filesystem paths.
8. Swift Package tests compile both app and helper paths, and the Xcode-owned
   app builds with the Storage settings and recovery controller included.

## Gate evidence

- 364 Python tests passed.
- 29 Swift Package tests passed.
- The Xcode-owned Hob app, embedded helper, and model tool built unsigned.
- The signed EventKit bridge build passed.
- Python syntax and the locked dependency graph passed verification.
- The complete real-model corpus passed 74/74 on
  `qwen2.5:14b-instruct` after running against the local Ollama service.

## Known gaps and release blockers

1. Exactly-once applies to local task mutation, not Telegram presentation. If a
   reply reaches Telegram and the helper dies before marking it delivered, the
   reply can be sent again. Copy must be safe and recognizable when repeated.
2. The typed inbound record starts after model interpretation. The Telegram
   update/offset edge still needs its own durable receipt so a crash before
   interpretation cannot lose an update.
3. The 10 MB document and 10,000-record queue caps fail closed but do not yet
   compact completed history. A measured retention and migration design is
   required before background activation.
4. Recovery replaces the unreadable primary with one previous local copy. It is
   not backup, export, rollback history, or cross-edition migration.
5. The native behavior surface still lacks full planning, recurrence, reminders,
   Calendar, pending confirmation, settings, query, and explanation parity.
6. UI accessibility has compile evidence only, not human assistive-technology
   evidence.

## Decision

Accept the typed-turn transaction and visible recovery boundary. Keep background
registration locked. The next increment should put a durable Telegram update
receipt ahead of interpretation, render compact outbound receipts into
repeat-safe customer messages, and exercise process-kill and retry behavior
before expanding the native behavior corpus.
