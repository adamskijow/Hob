<!-- SPDX-License-Identifier: MIT -->
# Apple task sync

Status: implemented; signed two-device rehearsal pending.

Hob stores a bounded operation journal in the customer's private iCloud
key-value store. Each device writes its own shard, then merges every shard
deterministically. Invalid, oversized, conflicting, or malformed data fails
closed.

Task text and planning fields sync. Model prompts, Calendar details, adopted
event IDs, reminders, and delivery queues stay local.

The local gate covers offline capture, concurrent edits, deletion, reconnect,
and restart on the signed Mac and iPhone builds.
