<!-- SPDX-License-Identifier: MIT -->
# Features

## Capture

Describe several tasks naturally, including dates, times, deadlines, priority,
and effort. Hob creates typed tasks only after the local Apple model returns a
valid action set. Ambiguous or unsafe output changes nothing.

Dates can be relative, named, or absolute. Hob confirms dates more than two
years away before saving them.

Tasks can repeat daily, weekly, monthly, or yearly. Completing an occurrence
advances the same task. Today actions can skip one occurrence or stop repeating.

## Planning

Fixed appointments keep their stated times. Untimed work stays on deck until
the user asks Hob to schedule it. An explicit planning request builds a proposal
from:

- stated dates, fixed times, deadlines, priority, and effort;
- optional opaque Calendar busy intervals.

The proposal shows scheduled and unscheduled work. Calendar integration defaults
off. When enabled, its settings choose which calendars protect time and where
approved blocks are added. Shared and subscribed calendars work through Apple
Calendar. All-day blocking is optional.

Natural questions such as “Will this week fit?”, “Why is this here?”, and “What
if this takes two hours?” return a read-only planning check. The answer shows
its time window and any missing-effort estimates.

The Today tab keeps the current day's plan visible as a living morning digest.
It refreshes after captures, replans, completions, and iCloud sync. Detailed
proposals and the task inventory live in the Schedule tab. Select a Today item
to edit its name or mark it done; the plan, notification digest, and synced task
state update together.

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

First run checks Apple Intelligence and offers iCloud, Calendar, and reminders.
Connection state and manual sync live in the gear menu.

## Current limits

- Local development installs only; no TestFlight or Store build exists.
- Sync and accessibility still need final two-device manual rehearsals.

The previous Telegram feature set remains documented in historical release
audits.
