<!-- SPDX-License-Identifier: MIT -->
# App Store durable-state audit

Date: 2026-07-11. Parent: PR #11.

## Result

Covered task and undo state survives helper restart. A candidate turn becomes
live after its atomic write succeeds. Corrupt, oversized, future-version,
duplicate-ID, invalid-date, or redirected state stops startup with a typed
error.

## Covered

- App Group storage only
- Directory mode `0700` and file mode `0600`
- 10 MB document bound and schema/content validation
- Serialized atomic replacement
- Verified previous-state copy and explicit recovery
- Save failure preserving prior in-memory state
- Corrupt state blocking a healthy heartbeat
- Restart persistence for capture and repeated undo

## Open gates at this increment

- Full task schema, plans, settings, confirmations, action log, and queues
- Durable inbound receipt and outbound acknowledgement
- Recovery UI and accessibility
- Export, deletion, retention, and diagnostics
- Process-kill, disk-full, sleep/wake, multi-process, and long-run sizing

Background activation remained locked.
