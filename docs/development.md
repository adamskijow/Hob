<!-- SPDX-License-Identifier: MIT -->
# Development

The host currently selects Command Line Tools. Prefix native commands with the
full Xcode developer directory.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/HobAppFoundation
uv sync --locked
uv run pytest
```

Build iPhone:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project native/HobAppleApps/HobAppleApps.xcodeproj \
  -scheme HobiOS -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Build Mac:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project native/HobMacApp/HobMacApp.xcodeproj \
  -scheme Hob CODE_SIGNING_ALLOWED=NO build
```

For a language bug, reproduce it against Foundation Models, inspect typed
output, trace it through storage and scheduling, then add an end-to-end
regression. Never repair free text with a phrase list.

Signed installs use local development identities and profiles. Do not commit
profile names, UUIDs, device identifiers, or signing material. Do not upload a
build without explicit approval.

CI builds the shared package, both Apple shells, EventKit bridge, retired menu
bar package, and Python suite on macOS and Ubuntu.
