<!-- SPDX-License-Identifier: MIT -->
# 1.0 queue-recovery increment audit

Audit baseline: the stacked time-correctness branch after draft PR #2. This
increment addresses the 1.0 P1 finding that one permanent inbox or outbox
failure can block every later user turn or delivery.

Release status: implemented on a stacked draft branch. It is not deployable
before v0.9 and time correctness, and it is not release-proven until the manual
failure drill below passes against a copied production database.

## Automated evidence

- Feature commit `c6c0c50`: 358 deterministic tests and compile check pass.
- The complete 14B real-model corpus passes 72/72. Queue recovery adds no new
  model behavior, and this full gate checks for accidental cross-layer change.
- The signed EventKit app builds, and both launchd plists pass `plutil -lint`.
- The feature diff passes whitespace and forbidden em-dash checks. Ruff is not
  installed in the locked project environment and is not claimed as evidence.
- Ubuntu/macOS CI on the stacked PR head and the copied-data/VoiceOver operator
  drill remain pending.

## Product decision

Hob continues to retry transient failures automatically and preserve queue
order. It never guesses that a failure is permanent and never silently drops a
message. A local operator can inspect content-free failure metadata, stop the
daemon, and explicitly choose one row:

- `retry` resets attempt metadata and puts the retained row back in order.
- `quarantine` retains the full row but removes it from the pending path so
  later work can proceed. A quarantined row can be retried later.

Inbox processing is transactional, so quarantining a failed inbound row means
its task and conversation mutations were not applied. Outbox state was already
committed before delivery, so quarantining an outbound row skips only that
message. Retrying an outbound row can produce a duplicate if Telegram accepted
an earlier send but its acknowledgement never reached Hob; the CLI states this
before the operator leaves the flow.

## Increment audit

| Criterion | Finding and decision | Evidence before release |
| --- | --- | --- |
| User onboarding and discoverability | Recovery is an exceptional local operation, not a chat command. Ordinary `status` points directly to `queue status`; that view says to stop the daemon and names the next commands. The deployment guide gives a copyable sequence and explains inbox versus outbox consequences. | A person unfamiliar with the implementation follows only status output and docs to inspect, quarantine, restart, verify, and optionally retry both directions. Record confusing wording as a defect. |
| User experience | Output uses `inbox`/`outbox`, `failed`/`quarantined`, and a durable reference. It never asks the user to inspect SQLite. Quarantine success says what happened to state, the retained row, and later work. Retry success says to restart. | Manual terminal pass at narrow width, invalid reference/direction pass, empty/history pass, and daemon-running refusal pass. |
| Customer experience | Later Telegram work can continue without making the owner resend everything behind a poison row. No automatic quarantine can conceal a lost user request or acknowledgement. | Inject one permanent inbound and outbound failure into a copy, place valid rows behind each, recover them, and verify the later interactions arrive exactly once. |
| LLM-native differentiation | None claimed. This increment protects the reliability of LLM-backed interaction but is deliberately deterministic operational plumbing. | No model evaluation delta required; the complete real-model release gate still runs on the exact stacked head. |
| Bugs and correctness | Recovery is limited to failed or already quarantined rows. Inbox and outbox order exclude quarantined rows. Retrying clears errors and attempts. Mutations take the same database lease as the daemon and restore/import. Schema migration is backed up. | Store tests, poison-row adapter tests, CLI tests, released-schema fixture migrations, complete suite, compile check, and copied-data drill. |
| Privacy and safety | Status, problem listings, history, and success output exclude payload, message text, exception text, chat ids, task ids, and Telegram message ids. Audit history stores only direction, reference, action, time, prior status, and attempt count. Portable exports exclude operational queues and recovery history; database backups retain both. | Secret-bearing payload/error regression, output inspection, export inspection, backup/restore inspection, and log inspection during the manual drill. |
| Operations | Read-only status/history can run while Hob is live. Retry/quarantine refuse while the daemon owns the database lease. Ambiguous legacy/app-data database selection is rejected. `status` accounts for failed outbound and both quarantine counts. | launchd stop/recovery/start commands on target macOS, wrong-database ambiguity test, post-start drain check, and health check. |
| Robustness | Quarantine is explicit and reversible. Recovery history survives restart and backup. A portable import starts with no delivery queues or recovery history. Limits cap history reads. No new autonomous behavior or remote dependency exists. | Repeated retry/quarantine cycle, crash between commands, restore of a backup with quarantined rows, malformed outbox reference, and disk-full/corruption drills. |
| Accessibility | All state and actions are plain text. Status does not rely on color, symbols, tables, cursor control, or an interactive prompt. Commands have equivalent copyable forms and consequences are stated in words. | VoiceOver terminal read-through and keyboard-only recovery rehearsal. |

## Deterministic acceptance cases

- A secret-bearing failed inbox summary and recovery event reveal neither the
  payload nor the stored exception.
- Quarantining the first inbound row allows the second to run. Retrying the
  first restores its original order with zero attempts and no stored error.
- Quarantining the first outbound row allows the second to send without
  reapplying application state. Retrying the first retains its original text
  and emits the duplicate-delivery warning.
- Pending rows that have never failed cannot be quarantined. Unknown rows,
  directions, actions, and nonnumeric outbox references fail safely.
- Queue mutations refuse while another process holds the database lease.
- Released schema fixtures migrate to schema 11 with a pre-migration backup and
  a content-free recovery log table.

## Manual drill before merge

1. Back up the live database and restore it to an isolated path.
2. Start a test daemon on that path and inject one deterministic permanent
   failure in front of a valid inbound row. Confirm the valid row is initially
   blocked and `status` points to queue recovery without private content.
3. Stop the daemon, quarantine the failed reference, restart, and confirm the
   valid row is processed while the quarantined mutation remains absent.
4. Repeat with an outbound failure. Confirm application state was already
   applied once, later delivery proceeds, and retry explains duplicate risk.
5. Retry both quarantined rows under controlled fixed dependencies. Verify
   history, restart persistence, backup/restore behavior, and logs.
6. Repeat the sequence using only VoiceOver and the deployment guide.

## Remaining boundary

This closes deterministic product support for poison queues once the manual
drill passes. It does not close disk-full/corrupt-database recovery, log and
storage retention, durable installation, supported-model evidence, or the
seven-day daily-use gate for 1.0.
