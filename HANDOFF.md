<!-- SPDX-License-Identifier: MIT -->
# Handoff

## Current state

- Release: `v0.9.13`
- Runtime schema: 11
- Python suite: 474 tests at release
- Native suites: 40 tests at release
- Real-model gate: 113 interpreter cases plus the analysis gate on
  `qwen2.5:14b-instruct`
- Platforms: released Open Local macOS edition; App Store edition in development

The live Open Local install runs under `com.local.hob`. Hearth runs Ollama under
`com.hearth.headless`. Both return at login. `scripts/hobctl status` is the
privacy-safe health check.

## Product boundary

Hob is a single-owner task agent over Telegram. Free-form language reaches the
local model. Code owns identity, dates, arithmetic, prompt context, consent,
atomic mutation, delivery, and undo.

Do not add phrase lists, keyword routers, or raw-text semantic repairs. Slash
commands, callback payloads, reactions, IDs, and ordinals are closed protocols.

The Open Local edition stores the Telegram token in Keychain, pairs the owner
locally, keeps local files owner-only, and uses an explicit HTTPS opt-in for
remote Ollama. Calendar access returns opaque busy intervals through a signed
read-only EventKit bridge.

## Recent release

`v0.9.13` closed the security audit findings:

- one private-owner boundary across Telegram text, media, callbacks, and
  reactions;
- local owner pairing for fresh installs;
- chat-scoped reply references and bounded completed delivery history;
- private databases, sidecars, locks, backup/export/recovery files, and logs;
- 5 MiB log rotation with three backups;
- argv-safe Keychain writes;
- explicit HTTPS consent for remote Ollama;
- pinned CI actions, locked installs, dependency audit, and Dependabot;
- Hearth login supervision verified after restart.

Evidence: [`docs/audits/v0.9.13.md`](docs/audits/v0.9.13.md).

## 1.0 priorities

The current gate is [`docs/audits/v1.0-acceptance.md`](docs/audits/v1.0-acceptance.md).
Highest-risk gaps:

1. Confirm the local timezone during first-run setup.
2. Add privacy-safe queue retry, quarantine, and recovery for permanent inbox or
   outbox failures.
3. Define and test DST behavior across planning, reminders, recurrence,
   Calendar, sessions, digest, and recap.
4. Prove the supported model baseline. Documentation defaults to 7B; release
   evidence currently covers 14B.
5. Rehearse clean install, update, rollback, backup/restore, logout/login,
   reboot, sleep/wake, and Calendar denial/revocation.
6. Complete keyboard, text-only, VoiceOver, date/time comprehension, and command
   discoverability checks.
7. Measure long-run database size, latency, queue drain, and history retention.
8. Complete seven consecutive days of privacy-safe daily-use evidence.

The App Store edition also needs its Telegram edge, full behavior parity,
no-Terminal onboarding, distribution signing, privacy metadata, accessibility,
archive validation, and App Review.

## Development loop

```sh
uv sync --locked
uv run pytest
HOB_MODEL=qwen2.5:14b-instruct uv run python -m evals.interpreter_eval
HOB_MODEL=qwen2.5:14b-instruct uv run python -m evals.analysis_eval
```

CI also builds both Swift packages, the EventKit bridge, and the App Store shell
on macOS.

For interpreter work:

1. Reproduce the message against the real model.
2. Keep semantics in typed model output.
3. Validate IDs, context, dates, bounds, and effects in code.
4. Add a deterministic regression and a real-model case.
5. Install with `scripts/install_macos.sh` and verify `scripts/hobctl status`.

## Operations

```sh
scripts/hobctl status
scripts/hobctl restart
uv run python app.py doctor
uv run python app.py backup /safe/hob.db
```

Never print task text, Telegram tokens, Hearth credentials, message IDs, or
Calendar titles in audit evidence. Preserve the live database and unrelated
working-tree changes.

## Docs

- User setup and operations: [`README.md`](README.md)
- Feature behavior: [`docs/features.md`](docs/features.md)
- Architecture: [`docs/architecture.md`](docs/architecture.md)
- Deployment: [`docs/deployment.md`](docs/deployment.md)
- App Store track: [`docs/app-store.md`](docs/app-store.md)
- Historical release evidence: [`docs/audits/`](docs/audits/)
