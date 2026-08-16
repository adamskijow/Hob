<!-- SPDX-License-Identifier: MIT -->
# Features

## Daily loop

1. Send tasks to Hob throughout the day.
2. Review one morning digest of scheduled and carried work.
3. Correct the list in ordinary language.
4. Tell Hob what finished during the evening recap.

Every free-form message reaches the local model. Tested code validates task
identity, dates, scope, arithmetic, prompt context, and allowed effects before a
change commits. `/undo` reverses the latest change.

## Onboarding

A private `/start` shows the local pairing command. After pairing, five short
questions set:

- work hours;
- work days;
- protected time;
- default task effort;
- transition time.

Setup resumes after restart. `/setup` resumes a paused flow. `/settings` shows
setup progress, Calendar state, and saved values. Settings changed in chat use
the same validation and undo path as task edits.

## Capture and correction

Hob supports:

- new tasks, several tasks in one message, forwards, and media captions;
- dates, times, deadlines, estimates, priority, projects, notes, dependencies,
  preferred windows, earliest starts, fixed commitments, and split work;
- completion, partial progress, drops, rescheduling, bulk changes, and numbered
  exclusions;
- edited Telegram messages, brief follow-ups, and reply-anchored actions;
- clarification and confirmation when a target, date, or large change is
  uncertain.

Examples:

```text
Call the pool guy Friday.
For the wedding: book the caterer, order flowers.
I did home insurance and called the bank.
Finished everything except 1 and 6.
Move everything to Monday except taxes, which goes Sunday.
```

Ambiguous messages stay pending until the answer arrives. A message such as
`lunch with Sam Thursday or Friday` followed by `Thursday` becomes one Thursday
task.

## Digests, recaps, and stale work

The morning digest includes today's work and carried items. It marks repeated
rollover with an age and asks whether stale work should stay, move, or drop.
Waiting tasks receive a similar blocker check.

The evening recap lists open work and accepts natural completion reports,
partial progress, or zero-result answers such as `nada`, `today was a wash`, or
`jack shit got done`. A zero-result answer leaves every shown task open.

Digest numbers remain tied to the displayed list. Newer task conversations take
priority over old recap, confirmation, onboarding, and stale-task prompts.

## Reminders and Telegram controls

A timed task receives a reminder before its due time. Reply with `done`,
`snooze 20`, or a new date. Reminder buttons offer Done, Snooze 10, and Drop.
Thumbs-up completes an anchored reminder; thumbs-down drops it.

Digest pinning defaults off. Say `pin my morning digest` to enable it or `stop
pinning the morning digest` to disable it. When enabled, each digest replaces
the prior pin. Telegram pin events are ignored. Unsupported owner media gets a
short text response. Slow model calls show Telegram's typing state, and long
replies split at safe boundaries.

## Notes, projects, and waiting

Notes appear with the task and its reminder. Project tags support grouped
queries. Waiting tasks leave the daily list until their blocker clears, while
remaining visible through queries and periodic checks.

```text
Add a note to the vet task: gate code 4412.
The contract is waiting on Jerry.
Jerry got back to me.
What's left for the wedding?
```

## Recurrence

Supported rules include daily, weekdays, several weekdays, monthly dates,
yearly dates, and intervals such as every two weeks. Series may follow a fixed
cadence or advance from completion. They can end by date or count and support
skip and stop actions. Moving one fixed occurrence preserves the series anchor.

## Planning

`Plan my day`, `plan tomorrow`, and constrained requests run the feasibility
engine. It accounts for:

- work hours and work days;
- protected breaks and transition time;
- opaque Calendar busy periods;
- stated times, estimates, deadlines, dependencies, and earliest starts;
- preferred windows, energy, splitting, and explicit time budgets.

The result lists scheduled blocks, conflicts, deferred work, deadline risk, and
visible default estimates. Calendar titles stay inside the EventKit bridge.
Without Calendar access, planning uses work hours and breaks.

`Use this plan` adopts the proposal as local sessions. A later proposal needs
`replace my plan with this` to replace active sessions. `/plan`, `cancel my
plan`, and `/undo` inspect or change that state. Plan adoption never changes task
dates or writes Calendar events.

Plan order remains available for follow-ups such as `start the second one`.
Starting focuses the task and leaves its completion state open. Session-start
nudges use durable, deduplicated delivery.

## Capacity, explanations, and what-ifs

Ask `am I overloaded this week?` or `can I finish by Friday?` for a seven-day
capacity outlook. Hob carries remaining effort across days, reserves adopted
sessions and Calendar busy time, and reports leftovers, risks, conflicts, and
assumptions.

Plan and outlook facts remain available for 24 hours. Follow with:

```text
Why didn't the audit fit?
What assumptions did you use?
What would need to change?
What if it took 30 minutes and I worked until 7?
```

What-if inputs apply to a temporary copy. They may change available time,
energy, work bounds, one estimate, or split permission. Saved tasks, settings,
Calendar data, and adopted plans stay unchanged until an explicit edit or
adoption.

## Search and queries

Semantic search covers labels, original captures, notes, and project tags. Hob
validates every returned task ID and falls back to literal search when needed.

Common queries include today's work, overdue work, waiting tasks, completed
work, project status, plan status, and weekly capacity.

## Commands

- `/today`: today's on-deck tasks
- `/list`: every open task
- `/settings`: schedule, planning profile, Calendar, and setup
- `/setup`: guided setup
- `/plan`: adopted plan and next session
- `/outlook` or `/capacity`: seven-day capacity
- `/undo`: latest change
- `/help`: command summary

## Ownership, privacy, and recovery

Pairing occurs locally with `scripts/hobctl pair ID` or through an explicit
`HOB_ALLOWED_TELEGRAM_USER_ID`. Messages, captions, reactions, and buttons must
come from that owner in the paired private chat. Other content is discarded
before storage.

The Telegram token can live in macOS Keychain. `status` reports health and
aggregate queue/plan state without task text or secrets. Backup, export,
restore, and import preserve task, history, setting, proposal, and session data.

Authorized updates enter a durable inbox before Telegram's polling offset moves.
Each turn commits its state and reply atomically. Failed model calls retry the
same inbox row; failed sends retry a deduplicated outbox. Completed delivery
metadata is retained for 30 days and capped at 1,000 rows per queue. Pending
work is exempt.

The Open Local installer adds a menu-bar teapot for status, start, restart,
health, logs, and data access. `scripts/hobctl` provides the same service
controls in Terminal.
