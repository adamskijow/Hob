<!-- SPDX-License-Identifier: MIT -->
# Handoff

Hob's active product is the native iPhone and Mac app. It uses Foundation
Models, durable local state, optional one-way Calendar availability, local
notifications, and private iCloud sync. The Python, Telegram, and Ollama edition
is retired.

## Current work

The worktree contains ongoing Apple-app hardening. Recent changes improve
conversational task matching, stale-task replies, recurrence repair, the living
daily plan, sync-safe migrations, and a capped, internally scrolling chat
transcript. The September 9 Upcoming/History build is installed on the paired
iPhone. No TestFlight or Store upload has been made.

Review the worktree before editing because these changes are not isolated to
documentation.

## Verify

Run `bash scripts/check_messages.sh release` before installing interpreter
changes. It checks historical live cases and repeated, end-to-end conversation
fixtures; unavailable models are failures, not skipped passes. The separate
`HobiOSMessages` scheme runs representative cases on an iPhone without opening
the user's task store. See `docs/development.md` for details.

Current hardening adds explicit clarification context, grounded task matching,
negation and partial-progress guards, safe short-command paths, and named
completion replies. Keep challenge cases out of production prompts and refresh
them after tuning. Test actual saved effects, not just a plausible response.

`RuntimeInteractions` inventories 12 interaction contracts. Pending questions
store the actual displayed text, kind, stable task IDs/revisions, day, and
timezone. The controller and interpreter share this state; restart preserves it,
while changed tasks/dates require renewed clarification. Bare review choices
refer to the visible review; recent conversational focus handles other follow-ups.
Queries clear ambiguous recent focus instead of silently selecting the stale task.

The effect oracle distinguishes seven injected faults from its valid control.
Coverage reports separate controller, interpreter, and rendered-UI evidence.
UI journeys use a parser fixture, not the model. Live external-service outages,
all device layouts, and truly cold model loading remain unverified. Cases reused
after tuning are regression evidence, not unseen validation.

September 9: fixed the command/title collision behind “Remove Stays” producing a
keep action. Literal named commands are resolved before review/date/completion
shortcuts, and keep evidence excludes the matched task title. Duplicate literal
names require clarification. Added 42 controller cases (seven command-like titles,
three removal verbs, review present/absent) to the required release matrix, plus
deterministic negation, ambiguity, and natural-keep controls. A fixed-delay
notification test now waits for the actual result with a bounded timeout.

Verified: 110 deterministic tests, 16 historical live tests, 142 scenarios across
525 turn executions, and three Simulator UI journeys passed. Generation p95 was
3.31s; overall maximum 3.57s. The final iPhone build passed 87 isolated turns
(maximum 3.27s) before normal-app installation. Evidence:
`/tmp/hob-title-collision-release-verified/coverage.json` and
`/tmp/HobTitleCollisionDeviceVerified.xcresult`.

Latest UI change: Schedule is now Upcoming, grouped by stated dates only. History
contains completed, removed, missed, and legacy paused items. Today is no longer
capped at six reminders. Tap-to-edit supports title/date/optional time and date
clearing; existing chat scheduling remains available with proposals in Today.
No tasks were migrated/deleted by this presentation change. Verified 113
non-model tests and five Simulator UI journeys, including minute-accurate display,
date clearing, History, and relaunch persistence. Evidence:
`/tmp/hob-upcoming-deterministic-verified.log` and `/tmp/HobUpcomingUIVerified.xcresult`.

The per-task ongoing policy (`reviewPolicy: "never"`) is implemented.
An ongoing untimed item remains on Today indefinitely but is excluded from the
seven-day stale-task question. It is available through “Keep it forever” language
and a “Keep indefinitely” task-editor toggle; switching it off starts a fresh
review interval. The Xcode agreement blocker was resolved and this feature was
tested and installed on the paired iPhone.

The audit fixes retain task-driven alerts, offline day refresh, read-only Calendar
integration, timezone-correct sync, and journal compaction with tombstones.
The follow-up audit fixes independent compound captures, shared capture/query
dates, ongoing policy at creation, per-revision retry-safe snoozes, same-second
edit protection, and working check-ins on both platforms. Persistent state is
version 13; edits have durable revision IDs, with compatibility for older sync
clients that omit that field. Native sources use checked-in Swift formatting,
enforced by CI; the unused legacy interpreter entry point is removed.

Verified: 133 deterministic native tests, 484 Python tests, 18 historical live
tests, 147 scenarios across 543 turn executions, and six Simulator UI journeys.
Mac and signed iPhone builds pass. Conversation p95 was 1.53s, maximum 3.27s.
Evidence: `/tmp/hob-audit-fixes-verified/coverage.json`.
The verified build is installed and launched on the paired iPhone.

The nightly “What got done?” notification is restored as a first-class,
time-pickable check-in. It defaults on only when the user has never chosen a
preference, preserves an explicit opt-out, and is visible alongside the morning
digest during setup and in the gear menu. Setup now scrolls on compact devices.
The notification scheduler, 133 deterministic tests, the iPhone build, and a
rendered setup UI journey pass. This build is installed and launched on the
paired iPhone.

The gear control now opens a persistent Settings sheet instead of a transient
SwiftUI menu. Changing toggles or times and running actions such as Sync now no
longer dismisses Settings; Calendar choices open as a nested sheet, and Review
setup intentionally transitions out of Settings. A rendered Simulator journey
verifies toggle and button persistence. The signed build is installed on the
paired iPhone; automatic launch was denied because the device was locked.

Settings now uses Hob's adaptive palette instead of the stock Form colors:
Hob background, themed row surfaces and navigation chrome, and copper links,
switches, and controls in both light and dark mode. The oversized Divider row
between check-ins was removed. The persistent-settings UI journey passes in
both appearances, and a signed iPhone build is ready; the paired phone was
unavailable when installation was attempted.

Build commands and the module map are in `docs/development.md` and
`docs/architecture.md`.

Keep model output typed and fail closed when it cannot be grounded. Calendar
availability remains optional, off by default, and one-way. Do not upload or
distribute builds without explicit approval.
