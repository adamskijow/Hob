<!-- SPDX-License-Identifier: MIT -->
# Apple migration and onboarding

Date: 2026-08-18.

## Customer path

1. Open the native app on Mac or iPhone.
2. Check Apple Intelligence and optionally connect iCloud, Calendar, and
   reminders.
3. Choose planning hours, days, default effort, and transition time.
4. Optionally export from the Open Local teapot and import the JSON.
5. Describe the first task and review the proposed schedule.

Setup remains available from the workspace toolbar.

## Safety

- Import accepts portable Open Local schema 1–11 files up to 10 MB.
- The full file validates before one atomic native-state write.
- Existing native tasks block import, preventing an accidental merge.
- Advanced task fields travel with each imported task as bounded source data.
- Open Local and its export remain unchanged.
- The v7 CloudKit journal survives the v8 preference migration.

## Evidence

- 44 native tests, including invalid import, repeat import, advanced-field
  preservation, preference scheduling, and v7 journal migration
- Mac and iPhone simulator builds
- Open Local menu tests and optimized build
- 115/115 real-model interpreter cases and 4/4 analysis cases

Signed-device onboarding, VoiceOver, and two-device CloudKit rehearsal remain
release gates.
