<!-- SPDX-License-Identifier: MIT -->
# Apple local conversion

Date: 2026-08-18. Scope: Mac and paired iPhone only. No TestFlight or Store
upload.

## Complete

- One Swift experience and behavior core on iPhone and Mac
- On-device language interpretation, deterministic scheduling, and local state
- Calendar adoption, start reminders, replanning, undo, and recovery
- First-run model check, preferences, permissions, and Open Local import
- Private iCloud sync with bounded, validated per-device journals
- Mac menu-bar app, automatic login startup, and teapot icon
- Keyboard, VoiceOver labels, responsive layouts, and Dynamic Type layouts
- Signed development builds provisioned for this Mac and iPhone
- Mac app installed in `/Applications` and launched
- iPhone app installed on the paired phone and launched

## Local gate

- Make offline edits on both devices, reconnect, and verify convergence
- Reboot the Mac and verify Hob returns in the menu bar
- Run VoiceOver and large-text checks on both devices

Distribution remains out of scope until these checks pass.
