<!-- SPDX-License-Identifier: MIT -->
# Apple calendar selection

## Scope

- Choose calendars that protect planning time.
- Choose a writable calendar for adopted schedules.
- Create a dedicated Hob calendar in the Apple default account.
- Support shared and subscribed calendars through EventKit.

## Product decisions

- Calendar integration defaults off on new and upgraded installs.
- Enabling it initially plans around every calendar and writes to Apple’s default.
- Onboarding offers one optional switch; detailed choices stay in the gear menu.
- Calendar choices stay on each device; calendars and events sync through their
  Apple accounts.
- Event titles stay inside EventKit. Scheduling receives times only.
- Subscription URLs stay in Apple Calendar; Hob stores calendar identifiers.
- All-day events remain available as an opt-in block.

## Failure handling

- Missing input calendars pause planning and lead back to Calendar settings.
- Missing or read-only output calendars stop adoption before any write.
- A failed batch removes partial Calendar work.
- Replanning ignores the current Hob proposal while respecting other events.

## Acceptance

- Free and cancelled events leave time available.
- With integration off, planning performs no Calendar reads or writes.
- A schedule can be adopted locally while integration is off.
- Selected busy events constrain proposals.
- A custom destination receives every adopted block.
- Existing Hob blocks remain removable after the upgrade.
- iPhone and Mac can make independent calendar selections safely.
