<!-- SPDX-License-Identifier: MIT -->
# Working on Hob

Read [HANDOFF.md](HANDOFF.md) first. Hob's active product is the native iPhone
and Mac app. Open Local is a retired compatibility path.

## Rules

- Keep one Swift behavior core and SwiftUI experience across Apple platforms.
- Free-form language belongs to Foundation Models, which emits typed actions.
- Code owns identity, dates, validation, scheduling, persistence, iCloud,
  Calendar effects, notifications, and undo.
- Never add English phrase lists, keyword routers, prefix matching, or raw-text
  semantic repair.
- Closed identifiers and protocols may stay deterministic.
- Invalid, duplicate, stale, or oversized model output fails closed.
- Calendar writes require explicit adoption.
- Keep copy and layouts brief.
- Preserve VoiceOver and Dynamic Type.
- Add the MIT SPDX header to source files.
- Avoid new dependencies without approval.
- Do not upload to TestFlight or a Store without approval.

## Development loop

1. Reproduce language bugs against the live Apple model.
2. Trace typed output through runtime, storage, sync, and scheduling.
3. Add a deterministic end-to-end regression.
4. Run native and Python suites.
5. Build both Apple surfaces.
6. Install only on the paired local devices when requested.
7. Commit, push, and wait for CI.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/HobAppFoundation
uv run pytest
```

## Layout

```text
native/HobAppFoundation/ shared core, storage, model, sync, UI
native/HobAppleApps/     iPhone app
native/HobMacApp/        Mac menu-bar app
core/, adapters/, app.py retired Open Local implementation
docs/                    current docs, ADRs, and historical audits
```

Never print or commit task text, Calendar titles, credentials, tokens, device
identifiers, provisioning material, or private iCloud payloads.
