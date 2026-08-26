<!-- SPDX-License-Identifier: MIT -->
# Apple calendar selection

## Scope

- Choose calendars that protect planning time.
- Support shared and subscribed calendars through EventKit.

## Product decisions

- Calendar integration defaults off on new and upgraded installs.
- Enabling it initially plans around every calendar.
- Onboarding offers one optional switch; detailed choices stay in the gear menu.
- Calendar choices stay on each device; calendars and events sync through their
  Apple accounts.
- Event titles stay inside EventKit. Scheduling receives times only.
- Subscription URLs stay in Apple Calendar; Hob stores calendar identifiers.
- All-day events remain available as an opt-in block.

## Failure handling

- Missing input calendars pause planning and lead back to Calendar settings.
- Replanning ignores the current Hob proposal while respecting other events.

## Acceptance

- Free and cancelled events leave time available.
- With integration off, planning performs no Calendar reads.
- Schedule adoption always stays local.
- Selected busy events constrain proposals.
- Existing Hob blocks remain removable after the upgrade.
- iPhone and Mac can make independent calendar selections safely.
