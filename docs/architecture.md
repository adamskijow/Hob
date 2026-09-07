<!-- SPDX-License-Identifier: MIT -->
# Architecture

Hob shares one Swift core and SwiftUI experience across iPhone and Mac.

```text
native/HobAppFoundation/
  HobAppCore/             tasks, scheduling, validation, undo
  HobAppleIntelligence/   Foundation Models interpretation
  HobAppStorage/          durable local state
  HobCloudSync/           private iCloud operation journal
  HobCalendar/            EventKit availability
  HobNotifications/       local notifications and actions
  HobAppExperience/       shared controller and SwiftUI views
native/HobAppleApps/      iPhone app
native/HobMacApp/         Mac app
```

Foundation Models returns typed actions. The core validates targets,
constraints, recurrence, bounds, and destructive scope before changing state.
Invalid output changes nothing.

Untimed tasks remain on deck. Fixed appointments retain their stated time. An
explicit request creates a schedule proposal, which remains separate until the
user adopts it locally. Adoption can schedule local notifications.

Calendar integration is optional and off by default. EventKit supplies busy
intervals from the calendars the user selects. Hob does not create or edit
calendar events; its removal path only cleans up blocks from older versions.

Tasks, schedules, undo, notification actions, and cleanup state survive
restarts. iPhone and Mac exchange bounded, validated operations through the
user's private iCloud account. Prompts and Calendar details stay on device.

The Python Open Local implementation is retired but remains in the repository
for legacy regression coverage.
