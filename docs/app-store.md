<!-- SPDX-License-Identifier: MIT -->
# Apple app

Status: native vertical slice builds for iPhone and Mac. No Store build ships yet.

## Product

The Apple app is a local planning assistant:

- type several tasks in ordinary language;
- extract dates, deadlines, priority, and effort with Foundation Models;
- fit the work into a feasible timeline;
- show conflicts and assumptions;
- adopt the proposal with one action.

Telegram and Ollama remain part of Open Local. The Apple app needs neither.

## Built

- `native/HobAppleApps` builds the iPhone app.
- `native/HobMacApp` builds the menu-bar Mac app and workspace.
- Both use the same Swift task runtime, scheduler, storage, model adapter, and UI.
- Typed tasks, proposals, adoption, undo, and delivery state survive restart.
- Plans avoid title-free EventKit busy intervals. Adoption writes all Calendar
  blocks transactionally and cancellation removes them.
- Optional start reminders offer Done, Snooze, and Replan. Actions and cleanup
  survive relaunch before changing task state.
- Hob compares adopted and proposed plans when the day changes. Calendar stays
  untouched until the customer accepts the diff.
- Tasks converge across iPhone and Mac through a validated operation journal in
  the customer's private iCloud database. Offline edits sync after reconnecting.
- First run checks Apple Intelligence, offers iCloud, Calendar, and reminders,
  and saves working days, hours, task length, and transition time as real planner
  constraints.
- Open Local exports from its teapot menu. The Apple app validates the whole
  file before importing into an empty task list, preserves advanced task fields,
  and leaves Open Local untouched.
- Invalid inputs and stale proposals fail closed.
- The reviewer scenario—multiple tasks with effort, priority, deadlines, and a
  busy period—has an end-to-end regression.

## Next

1. Finish accessibility and signed local-device rehearsals.
2. Validate the archive and prepare Store submission evidence.

## Release gate

A customer can install Hob on iPhone and Mac, describe work once, receive a
feasible plan, adopt it into Calendar, act on reminders, replan naturally, and
see the same state on both devices without Terminal or another app.

Before release, deploy the `HobTaskOperation` production CloudKit schema and
pass a signed two-device offline-edit rehearsal.

Architecture: [ADR 0003](adr/0003-universal-apple-app.md).
