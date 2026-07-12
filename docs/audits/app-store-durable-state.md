<!-- SPDX-License-Identifier: MIT -->
# App Store durable-state increment audit

Date: 2026-07-11. Parent: merged runtime-contract PR #11.

## Customer outcome

The Store runtime's covered tasks and undo history now survive a helper restart.
Hob does not report an applied turn until its candidate state is durably written.
If the task file is corrupt, too large, from a future version, or unsafe to
access, Hob stops rather than pretending the customer has an empty list.

## Increment audit

| Criterion | Evidence | Assessment |
| --- | --- | --- |
| User onboarding | Background activation remains locked. No recovery control is exposed before it works end to end | Honest, but recovery UI is now the next onboarding requirement. |
| Usability | Storage failures have stable human messages that say no changes were made. Recovery from the previous copy is explicit | Clear foundation. The app does not display these states yet. |
| Customer experience | Capture and repeated undo survive independent runtime reconstruction. Corruption never silently discards visible work | Resolves the first restart-loss risk for the covered native slice. |
| Bugs and feature robustness | State schema, task count, undo depth, ids, uniqueness, status, labels, raw text, timestamps, dates, times, file size, and paths are validated. Writes are atomic and serialized by an actor | Strong for a single-process seed. Process-kill and disk-full rehearsals remain. |
| False acknowledgement safety | A turn applies to a copied runtime. The copy becomes live only after storage succeeds; a failed write throws and leaves the prior runtime unchanged | Preserves the acknowledged-means-durable promise at this boundary. |
| Privacy | State stays under the registered App Group. The directory is mode 0700 and files are mode 0600. Errors contain no path or task text | Appropriate local boundary. Export, retention, deletion, and diagnostics remain open. |
| Recovery | Each replacement first validates the current document and writes it atomically as the previous-state copy. A corrupt primary must be explicitly restored; it never auto-falls back | Safe and understandable. Recovery needs authenticated UI and audit evidence before release. |
| Operations | The helper constructs the durable runtime before writing health. Corrupt storage therefore prevents a false healthy heartbeat | Correct fail-closed startup. Health does not yet identify the recovery category. |

## Verified paths

1. Missing state opens as a new empty store.
2. Two captures survive restart; undo survives another restart; repeated undo
   remains durable.
3. A failed save neither updates live memory nor returns a success response.
4. Corrupt primary data fails and requires explicit verified-backup recovery.
5. Future schema versions, duplicate ids, invalid timestamps, oversized files,
   state-file symlinks, and storage-directory symlinks fail closed.
6. State files and directories receive private POSIX modes.
7. Xcode compiles storage into the sandboxed login item, which opens only the
   App Group path.

## Known gaps and release blockers

1. The state document covers the initial task fields and undo snapshots only.
   The full schema, recurrence, plan sessions, settings, pending confirmations,
   action log, inbox, outbox, and migrations are not native yet.
2. Task mutation and persistence are atomic together, but inbound receipt and
   outbound acknowledgement are not yet in the same durable pipeline.
3. Recovery exists in code but has no Settings status, preview, confirmation,
   VoiceOver path, or post-recovery explanation.
4. The previous-state copy is local resilience, not a customer backup or export.
5. Atomic-write behavior has deterministic failure tests but not live process
   termination, disk-full, sleep/wake, multi-year size, or OS-update evidence.
6. JSON is acceptable for the bounded seed, but the complete queue and history
   workload needs a measured format and migration decision before activation.

## Decision

Accept the durable-state boundary and keep background registration locked. The
next increment should connect a durable inbound-turn-outbound coordinator, add
idempotency and crash replay, and expose privacy-safe storage health and explicit
recovery in onboarding before any real Telegram message reaches this runtime.
