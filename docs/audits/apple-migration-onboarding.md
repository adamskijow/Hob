<!-- SPDX-License-Identifier: MIT -->
# Apple migration and onboarding

Updated: 2026-08-25.

## Customer path

1. Open the native app on Mac or iPhone.
2. Check Apple Intelligence and optionally connect iCloud, Calendar, and
   reminders.
3. Describe the first task. Untimed work stays on deck.
4. Ask Hob to schedule on-deck work when a timed proposal would help.

Setup remains available from the workspace toolbar.

## Safety

- Model output validates before task state changes.
- Calendar writes require approval.
- iCloud sync validates bounded per-device journals before merging them.
- Untimed work never receives an automatic clock time.
- Open Local data stays separate from native app data.

## Evidence

- 71 native tests
- Mac and iPhone simulator builds
- 115/115 real-model interpreter cases and 4/4 analysis cases

Signed-device onboarding, VoiceOver, and two-device iCloud rehearsal remain
release gates.
