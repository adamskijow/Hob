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
transcript. The latest development build was installed on the paired iPhone; no
TestFlight or Store upload has been made.

Review the worktree before editing because these changes are not isolated to
documentation.

## Verify

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/HobAppFoundation --skip FoundationModelInterpreterLiveTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/HobAppFoundation --filter FoundationModelInterpreterLiveTests
```

Build commands and the module map are in `docs/development.md` and
`docs/architecture.md`.

Keep model output typed and fail closed when it cannot be grounded. Calendar
availability remains optional, off by default, and one-way. Do not upload or
distribute builds without explicit approval.
