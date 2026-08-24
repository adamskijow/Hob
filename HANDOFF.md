<!-- SPDX-License-Identifier: MIT -->
# Handoff

## Start here

Hob is now a native iPhone and Mac planner. It uses Apple Foundation Models,
EventKit, local storage, notifications, and private iCloud sync. Telegram,
Ollama, Hearth, and the Python daemon belong to the retired Open Local edition.

Nothing has been uploaded to TestFlight or either App Store.

## Exact state

- Branch: `main`
- Current increment base commit: `ca97849`
- Native app version: `0.1` build `1`
- Latest public tag: `v0.9.13`, for the legacy Open Local edition
- Tests: 484 Python and 64 native
- CI: green on Ubuntu and macOS at `ca97849`; recheck after this increment
- iPhone: signed current calendar build installed; relaunch was blocked by the lock screen
- Mac: signed current calendar build installed at `/Applications/Hob.app`
- Legacy `com.local.hob` and `com.local.hob.menu` login agents: disabled and retired
- Hob's old `qwen2.5:14b-instruct` Ollama model: removed; other models untouched

Retired launch-agent files are under
`~/Library/Application Support/Hob/retired-open-local-20260821/`.

## Recent work

- Added a living Today digest shared by iPhone and Mac.
- Made Today items editable and actionable with durable Save, Mark Done, and
  Undo support.
- Added optional iPhone morning notifications, on by default at 7:00 AM, with
  seven days refreshed after task or schedule changes.
- Moved detailed proposals and tasks into a Schedule tab.
- Moved connection status into the gear menu and quieted routine iCloud sync.
- Removed Open Local import from first-run onboarding.
- Added safe conversational clock normalization and duplicate-action rejection.
- Verified `Take Willow to get her haircut at 230` produces one model action at
  `14:30` in a live Foundation Models smoke test.
- Compacted the proposed schedule card and installed that build on the iPhone.
- Added opt-in Apple Calendar integration, off by default, with per-device
  choices in the gear menu.
- Planning can use all calendars or a chosen set, including shared and
  subscribed calendars already connected to Apple Calendar.
- Adopted plans go to the chosen writable calendar. Hob can create a dedicated
  calendar in the same account as Apple's default calendar.
- All-day blocking is optional. Free and cancelled events no longer block time.
- Calendar selection fails closed if a chosen calendar disappears.
- Split coordinated appointments and pair their stated times in order, backed by
  an exact live Foundation Models regression.
- Replaced the four inline digest times with one compact 24-hour selector.

## Next verification

On each device, open gear > Calendar, turn integration on, choose the planning
calendars and output calendar, then add an event to a shared or subscribed
calendar. Confirm the next proposal avoids it and an adopted plan appears in
the chosen output calendar.
Confirm the compact digest-time selector stays put while the gear menu scrolls.

## Product rules

- One shared Swift behavior core and SwiftUI experience on iPhone and Mac.
- Model output proposes typed actions. Code owns identity, dates, validation,
  persistence, sync, Calendar writes, notifications, and undo.
- Invalid or duplicate model output fails closed.
- Calendar changes require an explicit customer action.
- iCloud data must remain bounded and valid through offline convergence.
- Keep copy brief and the primary workspace visually quiet.
- Preserve Dynamic Type and VoiceOver while reducing layout bulk.

## Verification

The active Xcode selector points at Command Line Tools. Prefix native commands:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/HobAppFoundation
uv run pytest
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project native/HobAppleApps/HobAppleApps.xcodeproj \
  -scheme HobiOS -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project native/HobMacApp/HobMacApp.xcodeproj \
  -scheme Hob CODE_SIGNING_ALLOWED=NO build
```

CI runs the same native builds plus the legacy regression suite. Commit, push,
and wait for both CI jobs.

## Release boundary

Keep builds on the paired Mac and iPhone. Do not upload, archive for
distribution, create TestFlight builds, or submit to a Store without fresh user
approval.

Before 1.0: rehearse shared-calendar and two-device offline flows, test restart
and notification actions, finish VoiceOver and large-text checks, then prepare
Store metadata and distribution signing.
