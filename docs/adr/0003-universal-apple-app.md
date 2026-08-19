<!-- SPDX-License-Identifier: MIT -->
# ADR 0003: one local Apple app on iPhone and Mac

Status: accepted, 2026-08-16.

## Decision

Hob will ship a native iPhone and Mac app with one Swift behavior core. Apple
Foundation Models interpret language on-device. Tested code owns dates,
identity, scheduling, persistence, sync, and undo.

The Apple app does not require Telegram, Ollama, a daemon, or Terminal. Open
Local remains available during migration.

Private iCloud key-value storage syncs a bounded, per-device operation journal.
EventKit supplies opaque busy intervals and receives only user-adopted Hob
blocks. Model output never writes tasks, Calendar, or sync state directly.

## Delivery

Vertical slices must finish a customer journey across model, core, storage,
UI, restart, and tests. The order is planning, Calendar adoption, execution,
replanning, sync, migration, then Store release.

The Apple app reaches 1.0 only after iPhone and Mac pass the same acceptance
corpus and remain consistent through offline edits and restart.
