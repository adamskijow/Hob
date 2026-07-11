<!-- SPDX-License-Identifier: MIT -->
# Architecture

Pure core, adapters at the edges. All logic lives in `core/` with zero I/O: no
network, no `sqlite3`, no Telegram library, no wall-clock reads. The LLM call,
the clock, and the store are injected as protocols (`core/ports.py`). This makes
the core fully unit-testable headless with a fake clock, an in-memory store, and
a fake LLM that returns canned JSON, and it makes the design portable: the
capture channel and the storage are swappable without touching the logic.

```
core/         pure, zero I/O, fully tested, time injected
  models.py       Item, Action variants, Digest, etc.
  ports.py        Protocols: Store, Llm, Clock
  interpreter.py  builds the prompt; parses + validates JSON into Actions
  dates.py        date-intent resolution + day-word backstops
  planner.py      Actions + context -> concrete mutations (no I/O)
  digest.py       owed-decision, digest selection + rollover, rendering
  feasibility.py  deterministic time-grid planning and plan diffs
  recurrence.py   recurring-rule parsing + next-occurrence math
  undo.py         action-log replay / revert (operates on snapshots)
adapters/     all I/O lives here
  store_sqlite.py SQLite Store, transactions, durable inbox/outbox
  data_files.py   verified backup restore and JSON import
  keychain.py     macOS Keychain credential storage
  llm_ollama.py   Ollama structured-output client
  telegram_bot.py long-poll loop, durable ingestion and delivery
  clock.py        real clock
  scheduler.py    morning-digest timer + catch-up-on-wake
  calendar_eventkit.py read-only subprocess edge for opaque busy times
native/
  HobCalendarBridge/ signed Swift EventKit bridge; no event writes or titles
app.py        composition root: wire adapters into core, run the daemon
config.py     env config + validation
```

Two correctness rules the core never breaks:

- **The model never does date math.** It classifies a date phrase into a typed
  intent ("next friday" becomes weekday/next/fri); the core (`dates.py`) does
  the calendar arithmetic, exactly and testably. Day words named in the message
  ("monday", "tomorrow") deterministically win over a misclassified intent, and
  on ambiguity ("thursday or friday") Hob asks rather than guesses.
- **Fuzzy language never silently mutates state.** An unresolved reference or a
  low-confidence guess produces a clarifying question, not an edit, and Hob
  remembers that question so your next message can answer it. Sweeping deletes
  and implausibly far dates are held for a yes/no. The action log plus `/undo`
  backs everything that does get applied.

## Caveat: not fully local

The model and the store run locally, but Telegram messages transit Telegram's
servers, so this is not an end-to-end local pipeline. The capture channel is the
swappable part: anyone who needs fully local can replace the Telegram adapter
(`adapters/telegram_bot.py`) without touching the core.

## Read-only intelligence

Planning and semantic recall deliberately sit outside the mutation path. The
feasibility core owns all time arithmetic: it subtracts opaque Calendar busy
periods and protected breaks from working hours, locks stated times, validates
dependencies and earliest starts, then packs flexible or explicitly splittable
work. The model only explains the resulting timeline. It cannot change a time,
create capacity, complete, move, or delete through this pass. The last proposal
is stored as meta state so a replan can retain still-valid blocks and render a
minimal diff.

The planning profile is also meta state, but changes flow through typed Setting
actions and the ordinary action log so `/undo`, backup, and export preserve the
same contract as task edits. Feasibility receives validated default-duration and
transition-buffer values plus explicit working days. Upgraded profiles with no
working-day choice retain the old all-days behavior and label that assumption
until the owner chooses. Generated plan order becomes typed conversational
focus for 15 minutes; deterministic reference resolution uses that visible order
for ordinal follow-ups. A `start` action changes focus only and states that the
task was not completed.

Adoption is separate from proposal. Schema 10 stores `plan_runs` and
`plan_sessions`; every split block retains its task, time, segment, and state.
Typed plan actions adopt, replace, or cancel only after explicit language and
write an action-log state snapshot so undo and edited-message recovery remain
atomic. Task lifecycle changes synchronize active sessions, while recurring
completion closes only the occurrence-day session and preserves a future one.
Adopted order becomes fallback conversational focus after the ordinary
15-minute focus expires.

Session-start nudges use the durable outbox with a stable session key, but not
the due-time reminder buttons. The sent message is anchored to its task after
delivery, so a reply such as "done" stays deterministic without promising a
snooze that an undated session cannot honor. Plan state is included in portable
export/import and status without exposing task text.

First-run onboarding is a small persisted state machine at the edge. Each step
sets the normal pending Setting question, so model outages, invalid answers, and
restarts retain the question without creating a parallel interpretation path.

The pure weekly forecast composes up to seven daily feasibility passes without
a new database model. It carries remaining effort and simulated prerequisite
state in memory, reserves adopted sessions and opaque Calendar periods, and
returns typed days, risks, leftovers, and assumptions. The edge renders that
result as a read-only capacity answer. No forecast allocation enters plan,
task, action, reminder, or Calendar state. Named boundaries such as "by Friday"
are resolved by the deterministic date core.

The Swift EventKit bridge is a signed background app because Calendar permission
belongs to a stable macOS bundle identity. Apple exposes reads through a full-
access permission tier, but the bridge implements only status, permission, and
event-query commands. It emits only start, end, and all-day state; titles,
calendar names, and event identifiers never cross the adapter boundary. Denial, a missing
bridge, or a non-macOS development host degrades to working-hours-only planning.

Semantic search still asks the model for known ids, validates every id against
the current store, and falls back deterministically on malformed output or an
outage. Requested changes use the interpreter, planner, action log, and undo
path above.

## Transaction and delivery boundary

Telegram updates first become normalized rows in `inbox`; only after that
commit does Hob advance the polling offset. Processing a row nests the entire
message service inside one SQLite transaction. Item mutations, setting changes,
the action log, pending clarification/confirmation, focus, and the reply's
`outbox` row therefore commit or roll back together.

Outbox delivery happens after commit. A failed send remains pending and is
retried in order. Stable keys deduplicate digests, recaps, reminders, and
message replies. Like every system built on a remote API without an idempotency
key, there is one unavoidable at-least-once edge: a process killed after
Telegram accepts a send but before Hob records Telegram's response can produce
a duplicate message. It cannot duplicate the underlying task mutation.

A process-lifetime advisory lease prevents two Hob daemons from opening the
same data path and makes restore/import refuse to replace a database while its
daemon is live. Backup and export remain safe against a running database.

## Temporal model

Schema 9 retains `due_date` as the backward-compatible scheduled/do date and
adds a distinct hard deadline, duration and confidence, flexibility, splitting,
earliest start, preferred window, hierarchy, dependencies, and reminder-offset
state. The planner resolves literal dates and validates references; the store
persists flat scalar columns plus JSON lists.

The model still emits a compact recurrence shorthand at the edge, but the core
immediately converts it to a `RecurrenceRule`. Occurrence arithmetic uses that
structured rule, including a stable anchor date, end conditions, completion
count, and exceptions. This prevents a one-off move from silently changing a
fixed series.
