<!-- SPDX-License-Identifier: MIT -->
# Architecture

The active product is one native Apple app with shared behavior on iPhone and
Mac.

```text
native/HobAppFoundation/
  HobAppCore/             tasks, dates, scheduling, undo, contracts
  HobAppleIntelligence/   Foundation Models adapter
  HobAppStorage/          durable local state
  HobCloudSync/           bounded private iCloud journal
  HobCalendar/            EventKit reads and writes
  HobNotifications/       local reminders and actions
  HobAppExperience/       shared controller and SwiftUI workspace
native/HobAppleApps/      iPhone shell
native/HobMacApp/         Mac shell and menu bar
```

## Interpretation

Foundation Models converts free text into typed actions. The runtime validates
operation, target, date intent, clock time, bounds, duplicates, and destructive
scope before changing state. Invalid output changes nothing.

Meaning stays in the model. Phrase lists and keyword routers cannot choose an
action. Deterministic code validates typed output, resolves dates, and grounds
closed values such as weekdays against model-cited evidence.

## Scheduling

Tasks carry a work date, optional fixed time, deadline, duration, priority, and
optional recurrence. Completing recurring work advances its occurrence in
place, so undo and iCloud keep one history.
The scheduler applies working days, hours, transition time, and optional opaque
busy intervals from selected Apple calendars. Free and cancelled events are
ignored; all-day blocking is optional. A proposal remains separate from local
adoption. Calendar events are never added or changed. Start reminders are separate.

Capacity, placement, and what-if analysis reuses the scheduler on a temporary
task copy. It cannot write task or schedule state.

## Persistence and sync

Typed tasks, proposals, adopted schedules, cleanup work, and undo state survive
restart. iPhone and Mac exchange bounded, validated per-device operations
through the customer's private iCloud key-value store. Offline edits converge
after reconnecting. Bad remote data fails closed.

## Privacy

Prompts and Calendar details remain on the device. EventKit exposes only the busy
times selected for planning. The active app needs no Hob
server, Telegram bot, or downloaded Ollama model.

## Legacy edition

`core/`, `adapters/`, and `app.py` implement the retired Open Local edition.
They remain for migration, historical releases, and regression coverage. Its
architecture and evidence are preserved in `docs/audits/`.
