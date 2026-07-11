<!-- SPDX-License-Identifier: MIT -->
# Hob handoff

Picking up development? Read [CLAUDE.md](CLAUDE.md) first (conventions, the
model-proposes/core-disposes doctrine, the dev loop, and ops), then
[docs/architecture.md](docs/architecture.md). This file is just the current-state
snapshot.

## Where it stands

- **Live and in daily use.** Runs as a `launchd` daemon on macOS, with
  [Hearth](https://github.com/adamskijow/Hearth) keeping Ollama alive. Model:
  `qwen2.5:14b-instruct` (7b works; 14b is more reliable on dense messages).
- **Released:** v0.9.1. v0.9 adds a deterministic weekly capacity outlook,
  explicit working days, plan-aware EOD, first-adoption coaching, accessible
  media fallback, and privacy-safe activation metrics. Schema remains 10.
- **Green:** `uv run pytest` (347 passing), native bridge build, and the
  real-model eval (`HOB_MODEL=qwen2.5:14b-instruct uv run python -m
  evals.interpreter_eval`, 73/73). The v0.9.1 patch head passed Ubuntu and macOS
  CI in run `29165920137`.
- **Live v0.9:** release commit `c656459` passed exact Ubuntu/macOS CI in run
  `29165341007`, was tagged and published as v0.9.0, backed up, and deployed by
  graceful launchd restart. Status is healthy on schema 10 with clean queues and
  14B. The first real `/outlook` delivered without changing adopted-plan state.
- **v0.9.1 patch:** PR #7 fixes the live
  screenshot case where an immediate “Nevermind I'm good” became chitchat and
  left the unwanted capture scheduled. Only an exact standalone phrase plus a
  mutation batch at most 15 minutes old can trigger undo; stale or task-bearing
  variants fail safe. Its exact feature head passed 347 tests and 73/73 model
  cases before merge.
- **Live v0.9.1 evidence:** release commit `9a7d253` passed Ubuntu and macOS CI
  in run `29165983344`, including the EventKit bridge. The release was tagged,
  backed up, and deployed by graceful restart. A phone replay captured a new
  tomorrow task and immediately retracted it with “Nevermind I'm good”; Hob
  reported one undone change, the item is absent from storage, and queues are
  clean.
- **Mac App Store track:** ADR 0001 establishes one behavior with Open Local
  and Store distribution editions. `native/HobAppFoundation` starts the native
  menu-bar/settings surface, typed setup readiness, bounded Apple Foundation
  Models seam, and minimum sandbox/Calendar/network boundary. It is a foundation
  package, not yet a signed Xcode archive or distributable Store app.
- **Live v0.8 evidence:** the exact launchd database contains one active and one
  superseded run, three canceled old sessions, one started and two planned
  revised sessions. The direct nudge reply produced `started`, not completion;
  inbox and outbox have no pending or failed rows. Details are in the v0.8 audit.

## What is built

The full loop (capture, morning digest, reply-to-correct, EOD recap) plus:
natural-language everything (complete/drop/reschedule/amend/bulk, queries and
search, history, undo); typed-intent date resolution with day-word backstops;
priorities, project tags, recurring tasks, notes, waiting-on; timed reminders
with a lead time, snooze, and reply-to-act; conversational focus and edited-
message sync; Telegram-native forwarding, reactions, reminder/confirmation
buttons, and a pinned digest; actionable stale-task nudges (including undated
tasks); chat-settable wake/recap times; single-owner pairing; safe long-message
splitting; portable export and backup; semantic recall; read-only constraint-
aware daily planning; broader recurrence; the kettle bot avatar; a `doctor`
preflight and `scripts/setup.sh`. Details in
[docs/features.md](docs/features.md).

The v0.4 reliability layer commits one user turn atomically, persists Telegram
updates before offset advancement, retries model outages without asking the
user to resend, and delivers replies/digests/reminders through a deduplicated
outbox. `status`, verified `restore`/`import`, macOS Keychain token management,
app-data defaults outside the checkout, and released-schema migration fixtures
complete the operational surface.

The v0.5 temporal layer separates scheduled dates from hard deadlines and adds
duration/confidence, fixed/flexible and splittable work, earliest starts,
preferred windows, parents, dependency validation, and multiple reminders.
Structured recurrence preserves fixed cadence across a moved occurrence and
supports completion-relative schedules, end dates/counts, skips, and stops.

The v0.6 feasibility layer subtracts opaque EventKit busy periods and protected
breaks from working hours, locks stated times, and packs flexible work without
letting the model invent capacity. Event titles never leave the Swift bridge.
The prior proposal is persisted as meta state so replanning shows a small diff.
Calendar denial or an absent bridge falls back to working-hours-only planning.

The customer-profile layer has a five-step `/setup` state machine that
resumes across restart and uses ordinary pending Setting actions. Default task
effort, planning days, and transition space are explicit, inspectable, undoable
inputs to the feasibility core. Plan blocks persist as ordered conversational
focus so ordinal follow-ups target what was displayed. “Start the second one”
focuses work without falsely completing it. The initial increment audit is in
`docs/audits/v0.7.md`.

The v0.8 execution layer preserves each proposed block as a local plan session,
including split work. “Use this plan” explicitly adopts it; an active plan can
only change through an explicit replacement or cancellation, and none of those
operations changes task dates or writes Calendar events. Named future days use
their own availability window. Adopted order remains conversational context,
task lifecycle and recurrence stay authoritative, stale plans expire safely,
and durable start nudges retain reply anchoring without reminder controls that
cannot be honored. The increment audit is in `docs/audits/v0.8.md`.

The v0.9 draft carries each task's remaining effort through a read-only outlook
of up to seven days. Natural overload, fit, weekly-budget, morning-only, and
named-boundary questions use deterministic Calendar and feasibility math. Daily
planning now has explicit working days with backward-compatible upgrade
behavior. EOD reviews adopted session state without inferring completion, and
status exposes aggregate adoption/session/nudge evidence without private text.
The increment audit and unresolved dogfood gate are in `docs/audits/v0.9.md`.

## How development goes here

Screenshots of live misbehavior are the usual input. Reproduce against the real
model with a throwaway scratchpad probe, fix correctness deterministically in the
core (not the prompt), add a test and an eval case, then restart the daemon
(`launchctl kill SIGTERM gui/$(id -u)/com.local.hob`) and confirm live. See
CLAUDE.md for the full loop and the established deterministic backstops.
