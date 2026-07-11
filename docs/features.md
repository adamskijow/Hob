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

"Plan my day", "what should I do next?", and constraints such as "I have 40
minutes and low energy" trigger a separate read-only planning pass. It chooses
up to three real on-deck ids and explains why; invented ids are discarded and
nothing moves until you explicitly request a change. Search is semantic across
task wording, the original capture, notes, and project tags, with literal search
as the failure fallback.

## Dates, priorities, tags, settings

Dates can be vague: "this weekend", "next week", "end of the month", "in a couple
days" all resolve to concrete days (the core owns the math, never the model). A
task can carry a priority ("call the plumber, it's urgent", "the audit can wait")
that floats it up or down the digest, and a project tag ("for the wedding: book
the caterer, order flowers") you can later query ("what's left for the wedding").
You can change settings by chat too ("send the morning digest at 6:30").

## Commands and queries

- `/today` lists only today's on-deck items.
- `/list` lists every open item, including future and waiting tasks.
- `/settings` shows the configured timezone and live digest/recap times.
- `/undo` reverts your last change (one inbound message is one undoable batch;
  repeat to walk further back).
- `/help` shows a one-liner.

Everything else is just plain language. You can ask ("what's on today", "what's
overdue", "what do I have this week", "anything about the audit", "what did I
finish today"), move many at once ("push everything to tomorrow"), and undo
conversationally ("scratch that") as well as with `/undo`.

## Ownership and portability

The first private `/start` pairs Hob to one Telegram user unless
`HOB_ALLOWED_TELEGRAM_USER_ID` sets the owner explicitly. Other users and group
chats cannot read or mutate the shared task store or redirect its digest.
`python app.py backup` creates a consistent SQLite backup; `python app.py export`
writes portable JSON containing tasks, history, digests, and settings.

The Telegram token can live in macOS Keychain (`python app.py token set`) rather
than plaintext deployment configuration. `python app.py status` reports local
database, queue, pairing, digest, and model health without exposing task text or
secrets. Verified `restore` and `import` commands safety-backup current data
before an atomic replacement.

Every Telegram update is durable before its polling offset advances. One user
turn—including mutations, settings, undo history, clarification state, and its
reply—commits atomically. Temporary model failures retry the original inbox row;
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
