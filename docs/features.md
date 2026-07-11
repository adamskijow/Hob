<!-- SPDX-License-Identifier: MIT -->
# Everything Hob understands

The full tour of the loop and the plain-language features. The
[front page](../README.md) has the short version.

## The loop

1. **Capture.** Throughout the day you send short messages to a Telegram bot
   ("call the pool guy", "review the SR audit before standup"). Tasks too small
   to put on a calendar.
2. **EOD report.** At end of day you message what you got done. This closes items.
3. **Morning digest.** Each morning the bot sends one organized message: today's
   items plus anything undone that rolled forward from prior days.
4. **Reply to correct.** The morning digest will often be wrong, because the EOD
   report is easy to forget. You fix it in plain language ("already did the prez
   one", "drop the pool call, not happening", "push the audit to Wednesday",
   "what's on for tomorrow?") and Hob updates the list. Every inbound message
   flows through one interpreter that decides what you meant and turns it into
   concrete actions.

Feature 4 is the reason Hob exists rather than a standard to-do app. The
interpreter is the load-bearing component; everything else is plumbing.

## Onboarding and explicit work style

A fresh private `/start` pairs the owner and begins five short setup steps:
planning hours, planning days, protected daily time, the estimate for tasks
without a duration, and transition minutes between commitments. Setup state and
its pending question are transactional local metadata, so the flow resumes after
a restart. Every step can be skipped, the whole flow can be paused, and `/setup`
resumes it later.
`/settings` shows setup progress, Calendar readiness, every resulting value, and
whether the first plan has actually been adopted.

These preferences are explicit rather than inferred from private behavior.
Natural-language changes use the normal validated setting and action-log path,
so they are undoable and included in backup/export. Calendar permission remains
an explicit command on the Mac; Telegram setup reports the state but cannot
grant private-data access remotely.

An upgraded owner gets one concise note in the existing morning digest for a
new release. Fresh installs suppress it because `/start` already owns activation;
successful delivery records the version so the note does not become a recurring
nag.

## Asking instead of guessing

When a message is ambiguous (two possible dates, an unclear reference) Hob asks
instead of guessing, and it remembers the question or proposed mutation: your
next message is read as the answer. So "lunch with sam thursday or friday"
followed by "thursday"
captures it for Thursday, rather than the reply being misread on its own. The
context Hob keeps is deliberately small (the one open question), not a running
chat transcript; the task list itself carries the rest. You can also act on many
items at once in plain language ("did everything today", "did everything but the
slides", "clear my whole list", "drop all of friday").

## Reminders

A task with a time ("call the vet at 3pm") also gets a one-off reminder ping a
short lead before it (10 minutes by default, set with `HOB_REMINDER_LEAD`), so
it is a heads-up rather than a line in the morning digest or a ping at the exact
moment. Rescheduling it re-arms the reminder for the new time. You can reply
directly to a reminder: "done" completes that task, "snooze 20" puts the ping
off, "push it to friday" moves it, all anchored to the message you replied to.
Reminder messages also have Done, Snooze 10, and Drop buttons. Slow local-model
turns show Telegram's typing state, and long lists are split safely across
Telegram's message limit.

## Conversational focus and edits

Hob keeps a short conversational focus: right after "got it: call the vet
tomorrow", a bare follow-up like "make it 4pm", "actually thursday", or "that's
urgent" applies to that task. Editing an earlier Telegram message works the way
you'd hope too: Hob reverts what the original said and applies the corrected
text, so fixing a typo fixes the task.

## Evening recap and stale tasks

The loop closes in the evening: at `HOB_EOD_TIME` (20:30 by default, or "do the
evening check-in at 9" in chat; empty disables it) Hob asks "what got done
today?" and your free-text answer checks items off. And a task that keeps
rolling over is marked in the digest ("day 4") with a gentle question about
whether it is still real, so the list does not silently rot. Undated tasks age
too; reply `keep`, `tomorrow`, or `drop` to the digest. A keep decision resets
the nudge clock without moving the task.

## Telegram-native moves

Forward any message to Hob (a "grab milk?" text from someone) and it becomes a
task credited to the sender; react to a reminder with a thumbs-up to complete it
(thumbs-down drops it); and each morning's digest is pinned in the chat,
replacing yesterday's pin.

## Notes and waiting-on

Tasks can carry notes ("add a note to the vet one: gate code is 4412"), which
show up on the reminder when it fires. A task blocked on someone else ("the
contract is waiting on jerry") parks as waiting: it leaves the daily list and
reminders, stays visible as [waiting], answers "what am I waiting on", and
resurfaces in the digest after a few days ("still waiting: ... (4d). worth a
nudge?"). "jerry got back to me" puts it back on deck.

## Recurring tasks

A recurring task ("take out the trash every monday", "water the plants daily",
"standup every weekday") reappears each occurrence: completing it advances to the
next one and stays on the list rather than closing. Dropping it ends the series.
Multiple weekdays, a numbered day each month, month/day yearly rules, and plain
intervals such as every 2 weeks are supported as well.

## Planning and recall

"Plan my day", "plan tomorrow", and constraints such as "I have 40 minutes and
low energy" trigger a separate read-only planning pass. A pure,
deterministic engine fits work into the remaining day without overlaps. It
respects opaque Calendar busy periods, working hours, protected breaks, fixed
times, durations, deadlines, dependencies, earliest starts, preferred windows,
splitting permission, and literal time budgets. Unknown durations are shown as
30-minute estimates rather than hidden assumptions. Work that cannot fit is
named with a reason, deadline risk is called out, and fixed conflicts are shown
without silently moving the commitment.

The model sees only the feasible task timeline, then supplies a concise headline
and reasons. It cannot change times or add work. Hob persists the prior proposal
so "my afternoon is gone" can show a small plan diff. Nothing moves until you
explicitly request a change. Calendar event titles never cross the Swift
EventKit adapter boundary. Without permission or a bridge, the same planner
falls back to working hours and breaks. A named future day uses that day's full
window and Calendar snapshot; it never silently falls back to today.

Unknown task durations use the visible default estimate. A transition buffer
expands busy periods only for feasibility math, leaving fixed commitments at
their stated times and warning when a fixed time cannot honor the buffer. Plan
order is stored as conversational focus, so "start the second one" resolves to
the displayed plan rather than a different list order. Starting focuses the task
and explicitly does not mark it complete.

"Use this plan" explicitly adopts the proposal as local plan sessions,
preserving every split segment without changing task dates or writing Calendar
events. `/plan` and natural plan-status questions show the active version. A
replan is another proposal and cannot replace active sessions until the user
says "replace my plan with this"; cancellation and undo restore plan state
atomically. Task completion, dropping, waiting, recurrence rollover, and
stale-day expiry update sessions deterministically. One durable nudge may fire
at an adopted session's start; replies remain anchored to the task and retries
cannot duplicate delivery.

Search is semantic across task wording, the original capture, notes, and project
tags, with literal search as the failure fallback.

## Dates, priorities, tags, settings

Dates can be vague: "this weekend", "next week", "end of the month", "in a couple
days" all resolve to concrete days (the core owns the math, never the model). A
task can carry a priority ("call the plumber, it's urgent", "the audit can wait")
that floats it up or down the digest, and a project tag ("for the wedding: book
the caterer, order flowers") you can later query ("what's left for the wedding").
You can change settings by chat too ("send the morning digest at 6:30", "plan
work from 9 to 5", "plan flexible work weekdays", "protect lunch noon to 1").

The weekly outlook applies the same deterministic planning rules across up to
seven days. It counts each task's effort once, reserves adopted sessions and
opaque Calendar busy periods, simulates prerequisites only on later forecast
days, and reports deadline risk, leftovers, conflicts, and default-estimate
assumptions. It is a load test, not a schedule: it changes no tasks, plans,
reminders, or Calendar data.

## Commands and queries

- `/today` lists only today's on-deck items.
- `/list` lists every open item, including future and waiting tasks.
- `/settings` shows timezone, digest/recap times, planning profile, Calendar,
  and setup progress.
- `/setup` starts or resumes the guided planning-profile setup.
- `/plan` shows the explicitly adopted plan and its next session.
- `/outlook` or `/capacity` shows the read-only seven-day capacity outlook.
- `/undo` reverts your last change (one inbound message is one undoable batch;
  repeat to walk further back).
- `/help` shows a one-liner.

Everything else is just plain language. You can ask ("what's on today", "what's
overdue", "am I overloaded this week", "what will not fit by Friday", "anything
about the audit", "what did I finish today"), move many at once ("push
everything to tomorrow"), and undo
conversationally ("scratch that") as well as with `/undo`.

## Ownership and portability

The first private `/start` pairs Hob to one Telegram user unless
`HOB_ALLOWED_TELEGRAM_USER_ID` sets the owner explicitly. Other users and group
chats cannot read or mutate the shared task store or redirect its digest.
`python app.py backup` creates a consistent SQLite backup; `python app.py export`
writes portable JSON containing tasks, history, digests, and settings. If a
legacy checkout database and the app-data database both exist, recovery commands
refuse to guess until `HOB_DB_PATH` explicitly selects one.

The Telegram token can live in macOS Keychain (`python app.py token set`) rather
than plaintext deployment configuration. `python app.py status` reports local
database, queue, pairing, digest, and model health without exposing task text or
secrets. Verified `restore` and `import` commands safety-backup current data
before an atomic replacement.

Every Telegram update is durable before its polling offset advances. One user
turn (including mutations, settings, undo history, clarification state, and its
reply) commits atomically. Temporary model failures retry the original inbox row;
delivery failures retry a deduplicated outbox without applying the task twice.

## Scheduling constraints

`due_date` is Hob's do/scheduled date; a hard deadline is separate. Captures and
existing tasks can carry duration plus estimate confidence, fixed/flexible
status, whether work may split, an earliest start, a preferred part of day or
clock window, a parent task, dependency ids, and several reminder offsets. Hob
rejects impossible date combinations and dependency cycles. Undo and portable
export/import preserve every constraint.

Structured recurrence stores frequency, interval, weekdays or month date,
fixed versus completion-relative anchoring, the original cadence anchor, end
date/count, completed count, and exception dates. Moving the current occurrence
does not rewrite the fixed cadence. Skipping, stopping, or changing the series
is an explicit operation.
