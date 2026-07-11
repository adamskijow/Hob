<!-- SPDX-License-Identifier: MIT -->
# 1.0 durable-install increment audit

Audit baseline: stacked grounded-explanation draft PR #4. The 1.0 acceptance
matrix identifies a customer-critical gap: setup prepared dependencies but left
the owner to edit paths and environment values in a plist, load launchd by hand,
and invent an update or rollback procedure.

Release status: implemented on a stacked branch. It cannot merge, release, or
deploy ahead of its four parent increments. macOS clean-install, update,
rollback, reboot, sleep, and VoiceOver gates remain.

## Product decision

`scripts/setup.sh` remains the guided entry point. It may install the user
LaunchAgent only after config, live Telegram credentials, Ollama/model, and the
database are healthy. Calendar authorization remains a separate consent step,
and first private `/start` remains the safe owner-pairing path when no explicit
owner id is configured.

The generated service definition uses the exact checkout and `uv` executable,
starts with a frozen non-syncing environment, derives the system timezone unless
the owner explicitly overrides it, and never contains the Telegram token.
Update stops the prior service before database access, takes a raw verified
pre-migration backup under the database lease, verifies migration, validates the
new plist, and restores the prior loaded definition if a callback or bootstrap
fails. Uninstall removes only launchd state and retains data, logs, backups, and
the Keychain credential.

## Increment audit

| Criterion | Finding and implementation | Evidence before release |
| --- | --- | --- |
| User onboarding | The old “one-command” claim ended at a foreground process. Setup now pauses on actionable failures, installs the durable service when ready, and ends with `/start`, five-step setup, and service-status guidance. | Fresh standard-user Mac from clone through BotFather, token, rerun, pairing, profile, first task, plan, reboot, and digest. Confirm every pause says the next command. |
| User experience | `service install`, `status`, `restart`, and `uninstall` replace path editing and raw launchctl commands. Status names definition, checkout, data, and log paths. | Long path and spaces, missing uv, unloaded service, repeated install, restart, and uninstall rehearsal. |
| Customer experience | A bad token, missing model, invalid config, unsafe database, invalid plist, or failed bootstrap cannot be presented as a completed install. Existing service definitions are restored on transactional failure. | Inject each failure, confirm precise non-secret output, prior service recovery, and no loss of first useful digest. |
| LLM-native differentiation | Installation does not manufacture AI behavior. It proves the local model and Telegram edge are ready so the conversational product is actually reachable after reboot. | First natural capture and planning follow-up after install and after reboot. |
| Bugs and robustness | Update no longer risks opening or migrating SQLite while the old daemon owns it. A verified raw pre-migration backup precedes migration; launchd definition replacement is atomic and rollback-aware. | Live copied-data update, locked database, corrupt database, plutil failure, bootstrap failure, and prior-agent restoration tests. |
| Privacy and safety | The plist has explicit safe environment keys and never receives the token. Credential verification prints neither token nor bot identity. System timezone is not frozen accidentally. | Secret-bearing generation test, plist/log inspection, revoked-token doctor check, and unauthorized owner/group probes. |
| Consent and reversibility | Calendar access and Telegram pairing stay explicit. Uninstall preserves all owner state. Application rollback requires a compatible explicit backup and prior release, avoiding a false promise that a plist alone rolls schema back. | Denied Calendar branch, uninstall/reinstall, prior-tag plus backup restore, and retained Keychain/data checks. |
| Failure states | Setup exits nonzero instead of continuing after doctor failure. launchd throttles crash restarts. Failed database preparation reloads the prior agent; failed bootstrap restores its plist and loaded state. | Offline Telegram, Ollama down, model missing, database busy/full/corrupt, invalid plist, and launchctl denial drills. |
| Accessibility | Every service operation is text-only with an equivalent command; no buttons, color, or raw launchctl knowledge is required. | VoiceOver Terminal pass with setup, status, failure, uninstall, and recovery output. |
| Operations | The daemon uses `uv --frozen --no-sync`, exposes exact paths, and has explicit backup/update/rollback documentation. Hob log retention is stated rather than implied. | Reboot/sleep, crash restart, status PID/state/exit evidence, log growth observation, and seven-day operation. |

## Automated evidence

- Secret-free plist generation covers paths with spaces and an explicit owner;
  status reads the installed runtime and flags a hand-edited token key.
- System timezone remains dynamic unless explicitly overridden.
- Definition update, callback failure, bootstrap failure, and uninstall retention
  have deterministic tests.
- Doctor rejects an unverified credential without printing it.
- 393 deterministic tests and compile pass locally. This increment does not
  change interpreter behavior; the inherited 75/75 14B real-model corpus passes.
  The signed EventKit bridge build and both plist lints pass.
- Read-only `service status` against the live released agent reports the actual
  released checkout and database, healthy loaded state, and the different
  candidate checkout without changing or restarting either service.
- GitHub Actions run
  [29162824498](https://github.com/adamskijow/Hob/actions/runs/29162824498)
  passes Ubuntu and macOS at exact feature head
  `138838f1853f0ea5126afd1b23373a43958168f9`. The macOS job includes the
  signed EventKit build and complete test step.

## Release gates

- Deterministic, compile, inherited real-model, plist, signed native, Ubuntu,
  and macOS gates pass on the exact branch head.
- Fresh standard-user install and repeated update complete without manual plist
  editing or token exposure.
- Reboot, sleep, uninstall/reinstall, copied-data update, compatible rollback,
  and each injected failure above are rehearsed.
- VoiceOver can identify the failure, retained state, and exact next action.
