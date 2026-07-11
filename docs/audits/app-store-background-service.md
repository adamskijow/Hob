<!-- SPDX-License-Identifier: MIT -->
# App Store background-service increment audit

Date: 2026-07-11. Parent: merged App Store foundation PR #8.

## Decision

This increment is mergeable as a disabled foundation, not releasable to
customers. It adds the signed-bundle structure and consent path needed for a
real service while failing closed until the actual Hob task runtime is present.
The live Open Local daemon and its data path are unchanged.

## Experience and robustness matrix

| Area | Evidence | Assessment before merge |
| --- | --- | --- |
| User onboarding | Setup and Settings show service state, explain why background operation matters, and provide Turn On, Turn Off, approval, cancel, retry, and refresh paths | Clear and reversible. Turn On remains disabled while the helper is health-only, so onboarding cannot imply reminders work. |
| Customer experience | The app owns the lifecycle through `SMAppService`; no plist editing or Terminal command appears in the Store journey | Strong foundation. A signed development build still needs a manual enable, approval, disable, and relaunch rehearsal after the runtime is connected. |
| Privacy and safety | Main app and helper are sandboxed; both share one named App Group; helper has outbound networking only; health contains protocol, state, and timestamp with no task or message text | Minimal for the intended Telegram worker. The App Group must be registered and proven with the distribution signing identity before release. |
| Bugs and failure states | `notRegistered`, `enabled`, `requiresApproval`, `notFound`, and unknown states are distinct. Registration and unregister errors use stable text. Missing container and directory failure fail closed. | Deterministic coverage exists. Status refreshes when setup becomes active and whenever the background settings view appears, covering a return from System Settings. |
| Feature robustness | Xcode builds `HobAgent.app` inside `Hob.app/Contents/Library/LoginItems`; CI asserts the executable exists. Atomic heartbeat writes expose a privacy-safe future health seam. | Packaging is real. The helper intentionally has no task runtime yet and cannot be enabled from Hob. |
| Accessibility | Controls use text labels, native buttons, status text, and no color-only state | Native semantics are a good baseline; VoiceOver and keyboard journeys remain required before release. |
| Operational reliability | Helper starts through the system service manager, not a custom installer. Disable and approval recovery are first-class. | Login, sleep/wake, crash relaunch, update replacement, stale heartbeat, and uninstall cleanup remain unproven. |

## Findings resolved in this increment

### P0: registration must not be mistaken for working delivery

The first implementation could have allowed registration while the helper only
wrote a heartbeat. That would make setup look successful even though no digest
or reminder could arrive. The controller now has a separate runtime-available
gate. App readiness requires both an enabled system service and a connected
runtime. Turn On stays disabled and explains why until both exist.

### P1: system approval is a separate state

`SMAppService.register()` can succeed while macOS still requires approval in
Login Items. The UI therefore does not equate registration with enabled. It
opens the correct System Settings pane, supports canceling registration, and
continues to block readiness until the system reports enabled.

### P1: shared storage must fail closed

The app and helper resolve only `group.com.josephadamski.hob`, then construct
their database and health paths beneath that protected container. A missing App
Group or directory creation failure returns a stable typed error rather than
falling back to an unsandboxed path.

## Open gates

1. Register the App Group and both bundle identifiers in the Apple developer
   account, then verify distribution-signed entitlements and container access.
2. Embed the actual task runtime and change the runtime gate only after a model,
   database, Telegram, and queue health preflight passes.
3. Decide and prove which bundle identity owns EventKit permission. The helper
   currently does not request Calendar access, avoiding a surprise background
   prompt but leaving Calendar-backed planning unconnected.
4. Add stale-heartbeat detection, foreground status refresh, crash/relaunch,
   login, sleep/wake, update, uninstall, and data-retention rehearsals.
5. Complete VoiceOver and keyboard testing on every service state.

## Verification required before merge

- Complete Python suite and compile check.
- Swift package build with all native tests.
- Xcode shell build with the nested helper executable assertion.
- Main and helper plist lint, scheme XML validation, diff and privacy-boundary
  checks, and signed EventKit bridge build.
- Supported 14B interpreter corpus, because Store work may not regress the Open
  Local edition.
- Exact Ubuntu and macOS CI on the feature head and merge commit.
