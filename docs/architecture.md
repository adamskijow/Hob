<!-- SPDX-License-Identifier: MIT -->
# Architecture

Hob separates pure task logic from I/O.

```text
core/         models, interpretation, dates, planning, recurrence, undo
adapters/     SQLite, Ollama, Telegram, Keychain, clock, scheduler, EventKit
native/       Calendar bridge, menu-bar apps, App Store foundation
app.py        composition root and service orchestration
config.py     environment parsing and validation
```

`core/` has no network, database, Telegram, or wall-clock access. Protocols in
`core/ports.py` inject the model, clock, and store. Tests replace them with
fakes.

## Interpretation boundary

Free-form language belongs to the model. It emits typed actions and typed date
intent. The core then:

- resolves calendar arithmetic;
- validates task IDs, references, ordinals, and prompt context;
- checks bounds, exclusions, dates, dependencies, and destructive scope;
- requests clarification or confirmation when required;
- commits one atomic change and records undo state.

Phrase lists and keyword routers cannot synthesize meaning from free text.
Slash commands, callbacks, reactions, IDs, and ordinals are closed protocols
and stay code-owned.

The model proposes; the core validates and commits.

## Planning and analysis

The feasibility engine subtracts protected breaks and opaque Calendar busy
periods from work hours, locks fixed commitments, validates dependencies and
earliest starts, then places flexible or splittable work. The model explains the
result from known facts and cannot alter its times or capacity.

Planning preferences use typed setting actions, action logging, backup/export,
and `/undo`. A plan proposal remains separate from adoption. Schema 11 stores
plan runs and sessions, including split blocks, order, state, and supersession.
Adopt, replace, and cancel actions require explicit intent.

The weekly outlook composes up to seven daily feasibility passes in memory. It
carries remaining effort and simulated prerequisites while reserving adopted
sessions and Calendar busy time. Forecast allocations never enter task, plan,
reminder, or Calendar state.

Plan and outlook results keep a bounded 24-hour fact snapshot. Explanation may
select known fact and suggestion IDs. A what-if clones task state, applies
temporary inputs, and reruns feasibility. Durable state changes only through a
normal task edit, setting action, or plan adoption.

Semantic search follows the same ID boundary: the model selects from known
tasks, code validates every ID, and literal search handles failure.

## Conversation context

Hob stores small, typed contexts for:

- clarification and confirmation;
- recent task focus;
- digest and recap lists;
- stale-task and waiting prompts;
- setup questions;
- plan order and explanation facts.

Each context carries provenance, age, and allowed effects. Newer work can
supersede stale prompts. Free text still passes through the model before code
applies a contextual choice.

## Calendar boundary

The signed Swift EventKit bridge owns Calendar permission. It exposes status,
authorization, and event queries. Results contain start, end, and all-day state.
Titles, calendar names, and event IDs stay inside the bridge. Denial, timeout,
missing bridge, and non-macOS development hosts fall back to work hours and
breaks.

## Transaction and delivery boundary

All Telegram updates cross one private-owner authorization gate. Authorized
content enters `inbox` before the polling offset advances. Unauthorized and
Telegram service updates advance the offset without content retention.

Processing one inbox row wraps task mutations, settings, action log,
conversation context, and reply outbox in one SQLite transaction. A failure
rolls back the whole turn. Outbox delivery runs after commit and retries in
order. Stable keys deduplicate replies, digests, recaps, reminders, and session
nudges.

Telegram has no idempotency key. A process killed after Telegram accepts a send
but before Hob records the response may send that message twice. The task
mutation still applies once.

Completed inbox, outbox, and reply-reference history is retained for 30 days
and capped at 1,000 rows per table. Pending work is exempt. Reply anchors use
`(chat_id, message_id)`.

A process lease blocks duplicate daemons on one database and blocks live
restore/import. Backup and export remain safe while Hob runs.

## Temporal model

`due_date` is the scheduled work date. A hard deadline is separate. Tasks can
also store duration and confidence, fixed/flexible state, split permission,
earliest start, preferred window, parent, dependencies, and reminder offsets.

Recurrence becomes a structured `RecurrenceRule` with frequency, interval,
weekdays or month date, cadence anchor, completion-relative option, end date or
count, and exception dates. Moving one fixed occurrence preserves the series
anchor.

## Privacy boundary

Ollama and task storage are local by default. Telegram messages transit
Telegram. Remote Ollama requires explicit HTTPS consent. The Telegram adapter
is replaceable without changing the core.
