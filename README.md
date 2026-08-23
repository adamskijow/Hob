<!-- SPDX-License-Identifier: MIT -->
<p align="center">
  <img src="assets/hob-banner.svg" alt="Hob" width="100%">
</p>

# Hob

<p align="center">
  <a href="https://github.com/adamskijow/Hob/actions/workflows/ci.yml"><img src="https://github.com/adamskijow/Hob/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT">
  <img src="https://img.shields.io/badge/iPhone%20%2B%20Mac-black?logo=apple&logoColor=white" alt="iPhone and Mac">
</p>

Hob turns ordinary language into a realistic schedule. It runs locally on
iPhone and Mac with Apple Foundation Models and keeps tasks in sync through the
customer's private iCloud account.

## Current build

The native app is installed locally on the development Mac and paired iPhone.
Nothing has been uploaded to TestFlight or an App Store.

The previous Telegram and Ollama edition remains in the repository for history,
tests, and migration. It is retired from daily use.

## What it does

- Captures several tasks, dates, times, deadlines, priority, and effort from one
  natural message.
- Builds a feasible schedule around working hours and opaque Calendar busy
  intervals.
- Keeps today's plan on the main screen and sends the same optional morning
  digest to the iPhone.
- Adds an accepted schedule to Calendar and can cancel or replan it.
- Sends optional start reminders with Done, Snooze, and Replan actions.
- Persists tasks, proposals, adoption, undo, and cleanup across restarts.
- Syncs bounded task operations between iPhone and Mac through private iCloud.
- Keeps model prompts and Calendar details on the device.

## Build and test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/HobAppFoundation
uv sync --locked
uv run pytest
```

iPhone simulator build:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project native/HobAppleApps/HobAppleApps.xcodeproj \
  -scheme HobiOS -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Mac build:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project native/HobMacApp/HobMacApp.xcodeproj \
  -scheme Hob CODE_SIGNING_ALLOWED=NO build
```

Signed device installs require the local development profiles. See
[Development](docs/development.md).

## Docs

- [Handoff](HANDOFF.md)
- [Features](docs/features.md)
- [Architecture](docs/architecture.md)
- [Apple app](docs/app-store.md)
- [Development](docs/development.md)
- [Deployment](docs/deployment.md)
- [1.0 acceptance](docs/audits/v1.0-acceptance.md)

## License

MIT.
