<!-- SPDX-License-Identifier: MIT -->
# Development

Use Xcode's developer directory for native commands.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/HobAppFoundation --skip FoundationModelInterpreterLiveTests
```

Run live Foundation Models regressions on a supported Mac:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/HobAppFoundation --filter FoundationModelInterpreterLiveTests
```

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
