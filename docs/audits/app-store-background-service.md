<!-- SPDX-License-Identifier: MIT -->
# App Store background-service audit

Date: 2026-07-11. Parent: PR #8.

## Result

The Xcode bundle embeds `HobAgent.app` as a sandboxed login item. Setup and
Settings expose registration, approval, disable, retry, and refresh states
through `SMAppService`. App and helper use the registered App Group only.

Activation stays locked while the helper is health-only. Setup cannot imply
that reminders or delivery work.

## Covered

- Distinct unregistered, enabled, approval-required, missing, and unknown states
- Reversible registration and disable flow
- App Group path errors with no filesystem fallback
- Atomic heartbeat containing protocol, state, and timestamp
- Embedded helper assertion in Xcode and CI
- Text labels and status that do not rely on color

## Open gates

1. Register bundle and App Group identifiers and verify distribution signing.
2. Connect model, database, Telegram, and queue health before enabling service.
3. Choose the EventKit permission owner.
4. Test stale heartbeat, crash, login, sleep/wake, update, uninstall, and data
   retention.
5. Complete VoiceOver and keyboard testing.

## Merge evidence

Python, Swift package, Xcode shell/helper, plist, EventKit, real-model, and exact
Ubuntu/macOS CI gates were required.
