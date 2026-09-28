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
Invalid output changes nothing. Compound commands keep their own constraints;
captures and date queries share one calendar resolver.

Conversation questions are typed state shared by the controller, UI, and
interpreter. Pending questions and recent task focus survive relaunch locally;
task revisions, local day, and timezone invalidate stale context. A changed
question requires clarification instead of silently selecting another task.

Untimed tasks remain on deck. Fixed appointments retain their stated time. An
explicit request creates a schedule proposal, which remains separate until the
user adopts it locally. Explicit dated/time reminders notify without adoption;
adoption adds alerts for explicitly planned untimed work. Refresh reconciles
alerts against durable edit identities, not clock precision, and discards stale
notification actions. Snooze progression is per revision and retry-safe.
Daily check-ins repeat indefinitely on iPhone and Mac and invite the user to open
the live Today list, rather than repeating an old task snapshot.

Today shows current/unfinished untimed reminders. Upcoming groups future stated
dates into Tomorrow, This week, and Later; it does not generate times. History
holds completed, removed, missed, and legacy paused items. Open reminders can be
edited by chat or by tapping to change their title, date, and optional time.
Explicit schedule proposals appear in Today, not as a separate Schedule tab.

Calendar integration is optional and off by default. EventKit supplies busy
intervals from the calendars the user selects. Hob does not create or edit
calendar events; its removal path only cleans up blocks from older versions.

Tasks, schedules, undo, notification actions, and cleanup state survive
restarts. iPhone and Mac exchange bounded, validated operations through the
user's private iCloud account. Prompts and Calendar details stay on device.
Sync compares timestamp instants across timezones and retains only the latest
operation per task, including deletion tombstones. Local day refresh does not
depend on iCloud availability.

The Python Open Local implementation is retired but remains in the repository
for legacy regression coverage.
