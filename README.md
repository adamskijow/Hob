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

Hob is a planner for iPhone and Mac. Describe work or ask about your plan in
ordinary language. Apple's Foundation Models framework interprets each message
on the device, and private iCloud sync keeps tasks aligned across your devices.

## Features

- Captures tasks, appointments, deadlines, priority, effort, and recurrence.
- Keeps untimed work on deck without assigning arbitrary times.
- Builds a proposed schedule only when asked.
- Answers planning and task-history questions without changing state.
- Shows a living daily plan with task editing and completion.
- Sends optional morning, evening, and scheduled-task notifications.
- Can read selected Apple calendars as busy time; this is off by default.
- Keeps Calendar integration one-way and never creates or edits events.

## Requirements

- iOS 26 or macOS 26
- Apple Intelligence enabled and available
- iCloud for cross-device sync

## Development

The active app is native Swift under `native/`. Run its tests with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/HobAppFoundation --skip FoundationModelInterpreterLiveTests
```

See [Development](docs/development.md) for builds and live-model tests, or
[Architecture](docs/architecture.md) for the small system overview.

## License

MIT.
