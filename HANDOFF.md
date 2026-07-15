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
- **Released:** v0.9.6. v0.9 adds a deterministic weekly capacity outlook,
  explicit working days, plan-aware EOD, first-adoption coaching, accessible
  media fallback, privacy-safe activation metrics, and correct silent handling
  of Telegram-generated service events, and guarded shared-tense completion
  reports, plain-message digest decisions, safe numbered exclusions, and
  token-wide Telegram singleton ownership. Schema remains 10.
- **Green:** `uv run pytest` (387 passing), 29 native App Store foundation
  tests, signed native bridge build, and the
  real-model eval (`HOB_MODEL=qwen2.5:14b-instruct uv run python -m
  evals.interpreter_eval`, 76/76). The release head passes exact Ubuntu and
  macOS CI before tagging.
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
- **v0.9.2 list-scope patch:** a live EOD reply exposed that “everything on
  that list” could inherit the model's broad `all` scope and move unrelated
  open tasks that were not displayed. Proactive EOD lists are now persisted for
  24 hours, list-referential bulk turns are deterministically intersected with
  those exact ids, and a missing or stale list asks instead of guessing. See
  `docs/audits/v0.9.2.md`.
- **v0.9.3 service-event patch:** daily use exposed an unsupported-media reply
  immediately after Hob pinned the morning digest even though the owner sent
  nothing. Telegram pin and other status updates are now durable silent no-ops;
  actual uncaptioned owner media retains its text alternative. See
  `docs/audits/v0.9.3.md`.
- **v0.9.4 shared-tense patch:** daily use exposed “I did A and hit B” being
  split into one completion plus a false start because “hit” has the same
  present and past form. A conservative deterministic core correction now
  closes both tasks unless future, imperative, or partial-progress wording
  changes the second clause. See `docs/audits/v0.9.4.md`.
- **v0.9.5 digest-decision patch:** daily use exposed that the digest advertised
  “Reply keep” but only an explicit Telegram reply carried the item anchor. A
  content-free, same-day, single-use decision context now makes plain `keep`,
  `tomorrow`, `drop`, and `back on` work, while newer task focus wins for terse
  destructive choices. See `docs/audits/v0.9.5.md`.
- **v0.9.6 numbered-exclusion and singleton patch:** an unrecognized local CLI
  flag started a second process on the legacy database, which could share the
  Telegram bot because ownership was only database-scoped. The stale six-row
  digest then disagreed with the live four-row context. CLI commands and
  ambiguous database selection now fail fast, a content-free token-wide lease
  permits only one local poller, and numbered `all except` reports preserve the
  exact digest order or change nothing. See `docs/audits/v0.9.6.md`.
- **Mac App Store track:** ADR 0001 establishes one behavior with Open Local
  and Store distribution editions. `native/HobAppFoundation` starts the native
  menu-bar/settings surface, typed setup readiness, bounded Apple Foundation
  Models seam, and minimum sandbox/Calendar/network boundary. The Xcode target
  now produces a real unsigned `Hob.app` shell in local and CI builds. It is not
  yet a signed archive or distributable Store app.
- **Store helper increment:** the Xcode shell embeds a sandboxed login-item
  helper, exposes an explicit reversible `SMAppService` consent flow, and
  resolves shared data only through the protected App Group. The helper is
  health-only, so the UI deliberately locks registration until the real task
  runtime is connected. See `docs/audits/app-store-background-service.md`.
- **Store model-readiness increment:** the Xcode bundle now embeds the
  Foundation Models command tool with Apple's sandbox-inheritance signing
  boundary. Setup exposes an explicit privacy-safe generation check with a
  30-second deadline and fails closed on missing, unavailable, timed-out, or
  malformed responses. A framework availability flag is never enough. See
  `docs/audits/app-store-model-readiness.md`.
- **Store runtime-contract increment:** a bounded versioned Swift turn contract
  and first deterministic task slice now compile into both app and agent. One
  shared fixture executes against Python and Swift for capture, date math,
  correction, confidence holds, unknown targets, atomic multi-action turns,
  and repeated undo. It remains in-memory and intentionally cannot unlock the
  background service. See `docs/audits/app-store-runtime-contract.md`.
- **Store durable-state increment:** task state and bounded undo history now
  persist atomically in the protected App Group with private permissions,
  validation, size and symlink defenses, and explicit previous-state recovery.
  A save failure cannot commit the in-memory candidate or return success. The
  agent validates storage at startup but remains health-only and registration
  stays locked. See `docs/audits/app-store-durable-state.md`.
- **Store delivery-pipeline increment:** state v2 adds a durable typed-turn
  inbox and compact reply outbox. Interrupted turns replay once, duplicate ids
  cannot repeat mutation, delivery order and bounded retry state persist, and
  setup exposes content-free storage health plus confirmed previous-copy
  recovery. Telegram transport remains disconnected and background registration
  stays locked. See `docs/audits/app-store-delivery-pipeline.md`.
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
