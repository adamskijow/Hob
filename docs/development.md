<!-- SPDX-License-Identifier: MIT -->
# Development

Use Xcode's developer directory for native commands.

Native sources use the checked-in four-space Swift format. Run
`xcrun swift-format format --in-place --recursive native/HobAppFoundation/Sources`
after edits; CI checks the same style.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/HobAppFoundation --skip 'FoundationModelInterpreterLiveTests|MessageBenchmarkTests'
```

Before installing a changed interpreter, run the message gate on a Mac with
Apple Intelligence ready:

```sh
bash scripts/check_messages.sh release
```

`smoke` runs development cases once; `challenge` runs the separate challenge
sets twice. `release` runs deterministic tests, the historical live suite,
all benchmark conversations three times, and the `HobiOSUI` Simulator journeys.
It fails on missing interaction-contract evidence, missed injected faults,
behavior mismatches, an unavailable model, p95 over 15 seconds (including per
processing path), or a turn over 45 seconds. Reports,
diagnostics, and source fingerprints are saved under `/tmp/hob-message-check-*`.
No real tasks or external integrations are used.

The benchmark checks actions, saved tasks, digest visibility, replies, and
multi-turn context, including notification-to-chat flows, restart, cancellation,
competing task focus, command words inside task titles, negation, and
date/rollover boundaries. `coverage.json`
separates controller, real-interpreter, and rendered-UI evidence; repeated runs
are not additional scenario coverage. UI journeys use a controlled parser and
read the actual displayed question. They do not test model understanding.
When a challenge case
informs a fix, it becomes regression evidence; add fresh reviewed cases before
claiming unseen coverage. Passing a finite corpus is not a guarantee for every
message. Hosted CI runs deterministic checks, not Apple model evaluations.

Keep interaction contracts in `RuntimeInteractions.swift` and their required
evidence in `InteractionInventoryTests.swift`. A conversational question stores
its displayed text, kind, task IDs/revisions, local day, and timezone. UI and
interpreter share it; changed tasks or dates require renewed clarification.
Do not infer follow-up targets from whichever task happens to appear first.
The gate explicitly reports remaining gaps, including real integration outages
and truly cold system-model loading.

For representative live checks on a paired iPhone, use the `HobiOSMessages`
scheme with local signing settings. Its test host leaves the real workspace
closed and uses isolated fixtures. The model must be available on the phone.
For manual signing, pass the app's profile through `HOB_APP_PROFILE`, not a
global `PROVISIONING_PROFILE_SPECIFIER` that would also affect the test bundle.
Regenerate the project with `xcodegen generate` in `native/HobAppleApps` after
changing `project.yml`. These device checks complement, not replace, the Mac
release gate and visual UI checks.

Build the iPhone app for Simulator:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project native/HobAppleApps/HobAppleApps.xcodeproj \
  -scheme HobiOS -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Build the Mac app:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project native/HobMacApp/HobMacApp.xcodeproj \
  -scheme Hob CODE_SIGNING_ALLOWED=NO build
```

CI also runs the retained Open Local regression suite. For those tests, run
`uv sync --locked` followed by `uv run pytest`.

Signed device builds use local profiles. Do not commit credentials, device
identifiers, profile names, or signing material. Do not upload a build without
explicit approval.
