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
- **Released:** v0.8.0. Date-correct proposals can be explicitly adopted as
  first-class split sessions, queried as the current plan, safely replaced, and
  nudged once at session start. Schema is 10.
- **Draft:** v0.9 is isolated on `agent/llm-native-ux` in draft PR #1. It adds
  a deterministic weekly capacity outlook, working days, plan-aware EOD, first-
  adoption coaching, and privacy-safe activation metrics. It must not merge or
  deploy until the live v0.8 adoption/replan/nudge loop is dogfooded.
- **Stacked 1.0 readiness:** `agent/v1-time-correctness` derives the real Mac
  timezone, exposes it during setup, removes the template's regional default,
  and gives DST gaps/repeats explicit planning, reminder, and digest policies.
  It is not deployable ahead of v0.9.
- **Stacked queue recovery:** `agent/v1-queue-recovery` adds schema 11,
  privacy-safe queue status/history, explicit reversible retry/quarantine, a
  daemon-stop lease, failed-outbox accounting, and poison-row regressions. Its
  copied-data and VoiceOver operator drill is still pending, and it is not
  deployable ahead of either parent branch. Draft PR #3 contains the stack.
- **Current queue gate:** Feature commit `c6c0c50` passes 358 deterministic
  tests, compile, a signed native build, both plist lints, and the 72/72 14B
  real-model corpus. Ubuntu and macOS CI pass on verification head `4543f73`.
  The copied-data/VoiceOver drill remains pending for the stacked draft.
- **Stacked grounded explanation:** `agent/v1-grounded-explanations` is draft
  PR #4. It adds a typed, read-only planning explanation artifact and natural
  “why?” / “what would make it fit?” follow-ups. Exact feature head `b53f131`
  passes 384 deterministic tests, compile, native, both plists, the 75/75 14B
  corpus, and Ubuntu/macOS CI in run `29161761127`. Fresh-owner VoiceOver and
  five live disagreement-repair checks remain, and it is not deployable ahead
  of its parent branches.
- **Durable install in progress:** `agent/v1-durable-install` replaces manual
  plist editing with secret-free `service install/status/restart/uninstall`,
  live Telegram credential preflight, a verified pre-migration backup, and
  rollback-aware launchd replacement. 393 deterministic tests, compile, the
  75/75 14B corpus, signed native build, plists, and a read-only live status
  probe pass. Clean-install, update, reboot, sleep, rollback, VoiceOver, and CI
  remain, and it is stacked on draft PR #4.

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

The stacked queue-recovery increment prevents one permanent inbox or outbox
failure from blocking all later work. Automatic retry remains the default;
local status exposes no message or error content, and only an explicit stopped-
daemon command can retry or reversibly quarantine a failed row. Inbox recovery
preserves transactional mutation safety, while outbound recovery states the
remote duplicate-delivery edge. Its audit is in
`docs/audits/v1-queue-recovery.md`.

The stacked grounded-explanation increment preserves the latest plan/outlook's
deterministic blocks, remaining effort, risk reasons, visible assumptions, and
aggregate Calendar coverage. Natural references are model-assisted but locally
validated, all explanatory claims come from the artifact, literal questions
work through a model outage, and suggested repairs mutate nothing. Its audit is
in `docs/audits/v1-grounded-explanations.md`.

The stacked durable-install increment generates the exact per-user LaunchAgent,
validates live dependencies, stops the daemon before migration, preserves a raw
verified backup, and restores the prior loaded definition on failure. Uninstall
keeps data and credentials. Its audit is in
`docs/audits/v1-durable-install.md`.

## How development goes here

Screenshots of live misbehavior are the usual input. Reproduce against the real
model with a throwaway scratchpad probe, fix correctness deterministically in the
core (not the prompt), add a test and an eval case, then restart the daemon
(`launchctl kill SIGTERM gui/$(id -u)/com.local.hob`) and confirm live. See
CLAUDE.md for the full loop and the established deterministic backstops.
