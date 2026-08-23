<!-- SPDX-License-Identifier: MIT -->
# Features

## Capture

Describe several tasks naturally, including dates, times, deadlines, priority,
and effort. Hob creates typed tasks only after the local Apple model returns a
valid action set. Ambiguous or unsafe output changes nothing.

## Planning

Hob builds a timeline from:

- working days and hours;
- default task length and transition time;
- stated dates, fixed times, deadlines, priority, and effort;
- opaque Calendar busy intervals.

The proposal shows scheduled and unscheduled work. Calendar remains unchanged
until **Add to Calendar** is selected.

The Today tab keeps the current day's plan visible as a living morning digest.
It refreshes after captures, replans, completions, and iCloud sync. Detailed
proposals and the task inventory live in the Schedule tab.

## Execution and replanning

Accepted blocks can create local start reminders. Reminder actions support
Done, Snooze, and Replan. Hob can compare an adopted schedule with a new
proposal before updating Calendar. Cancellation removes Hob's Calendar events
and reminders durably.

The iPhone can also send the current digest each morning. It is on by default
at 7:00 AM; the gear menu can change the time or turn it off. Hob refreshes the
next seven notifications whenever the app updates its plan. The Mac shows the
same Today view without sending a second alert.

## State and sync

Tasks, proposals, adopted schedules, undo, notification actions, and cleanup
survive restart. Private iCloud sync keeps the iPhone and Mac task journal
aligned, including offline edits.

## Setup

First run checks Apple Intelligence and offers iCloud, Calendar, reminders,
working days, working hours, task length, and transition time. Connection state
and manual sync live in the gear menu.

## Current limits

- Local development installs only; no TestFlight or Store build exists.
- Sync and accessibility still need final two-device manual rehearsals.
- The latest `230` screenshot exposed a possible loss of fixed time between
  interpretation and proposal rendering; see [Handoff](../HANDOFF.md).

The previous Telegram feature set remains documented in historical release
audits.
