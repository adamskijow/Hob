<!-- SPDX-License-Identifier: MIT -->
# Handoff

## Start here

Hob is now a native iPhone and Mac planner. It uses Apple Foundation Models,
EventKit, local storage, notifications, and private iCloud sync. Telegram,
Ollama, Hearth, and the Python daemon belong to the retired Open Local edition.

Nothing has been uploaded to TestFlight or either App Store.

## Exact state

- Branch: `main`
- Current commit before this docs update: `8018506`
- Native app version: `0.1` build `1`
- Latest public tag: `v0.9.13`, for the legacy Open Local edition
- Tests: 484 Python and 51 native
- CI: green on Ubuntu and macOS at `8018506`
- iPhone: signed current build installed; launch it manually if the phone was locked
- Mac: signed app installed at `/Applications/Hob.app`; rebuild it after shared UI changes
- Legacy `com.local.hob` and `com.local.hob.menu` login agents: disabled and retired
- Hob's old `qwen2.5:14b-instruct` Ollama model: removed; other models untouched

Retired launch-agent files are under
`~/Library/Application Support/Hob/retired-open-local-20260821/`.

## Recent work

- Moved connection status into the gear menu and quieted routine iCloud sync.
- Removed Open Local import from first-run onboarding.
- Added safe conversational clock normalization and duplicate-action rejection.
- Verified `Take Willow to get her haircut at 230` produces one model action at
  `14:30` in a live Foundation Models smoke test.
- Compacted the proposed schedule card and installed that build on the iPhone.

## Next bug

The latest screenshot still displayed that `230` task at `9:00 AM`. The model
smoke test returned `14:30`, and the scheduler fixes tasks that retain
`RuntimeTask.dueTime`. Trace the value through:

1. `FoundationModelInterpreter`
2. `RuntimeAction.time`
3. `RuntimeTask.dueTime`
4. persisted and iCloud-merged task state
5. `RuntimeScheduleEngine`
6. the rendered proposal

Add an end-to-end regression using the exact sentence. Do not solve it with a
phrase list. Free-form meaning belongs to Foundation Models; code validates and
applies typed output.

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

Before 1.0: close the time-preservation bug, rehearse two-device offline sync,
test restart and notification actions, finish VoiceOver and large-text checks,
then prepare Store metadata and distribution signing.
