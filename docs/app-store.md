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
- Invalid inputs and stale proposals fail closed.
- The reviewer scenario—multiple tasks with effort, priority, deadlines, and a
  busy period—has an end-to-end regression.

## Next

1. Notify at block start and offer done, snooze, or replan.
2. Show a proposed diff when reality changes.
3. Sync an operation journal through private CloudKit.
4. Add migration, onboarding, accessibility, and Store submission evidence.

## Release gate

A customer can install Hob on iPhone and Mac, describe work once, receive a
feasible plan, adopt it into Calendar, act on reminders, replan naturally, and
see the same state on both devices without Terminal or another app.

Architecture: [ADR 0003](adr/0003-universal-apple-app.md).
