<!-- SPDX-License-Identifier: MIT -->
# App Store delivery-pipeline audit

Date: 2026-07-12. Parent: PR #12.

## Result

State v2 adds a durable typed-turn inbox and compact reply outbox. An inbound
receipt persists before mutation. Mutation, completed receipt, and pending reply
then commit together. Restart replay and duplicate IDs cannot repeat mutation.

Setup and Settings show content-free storage and queue health. A verified
previous copy can be restored after explicit confirmation.

## Covered

- Interrupted-turn replay and duplicate no-op
- Conflict rejection for reused request IDs
- Ordered replay and outbox sequence
- Explicit poison-turn quarantine
- Bounded delivery failure code and attempt count
- Idempotent delivery marking
- v1 to v2 migration
- Relationship, timestamp, sequence, status, size, and path validation
- Private count-only status

## Evidence

- 364 Python tests
- 29 Swift tests
- Unsigned Xcode app, helper, and model-tool build
- Signed EventKit bridge
- Locked dependency and syntax checks
- 74/74 real-model cases on `qwen2.5:14b-instruct`

## Open gates at this increment

1. Persist Telegram updates before interpretation.
2. Render and deliver repeat-safe Telegram replies.
3. Add completed-history retention and long-run sizing.
4. Add export and cross-edition migration.
5. Complete planning, recurrence, reminders, Calendar, settings, query, and
   explanation parity.
6. Run kill, sleep/wake, disk-full, multi-process, and accessibility tests.

Background registration remained locked.
