<!-- SPDX-License-Identifier: MIT -->
# Apple task sync

Status: implemented; signed-device rehearsal pending.

Hob stores immutable task operations in the customer's private iCloud database.
iPhone and Mac merge the same journal deterministically, including offline edits
and deletions. Invalid, oversized, conflicting, or malformed records fail closed.

Task text and planning fields sync. Model prompts, Calendar details, adopted
Calendar event IDs, reminders, and delivery queues stay local.

Release requires the production `HobTaskOperation` schema and a signed two-device
test covering offline capture, concurrent edits, deletion, reconnect, and restart.
