<!-- SPDX-License-Identifier: MIT -->
# Working on Hob

Read [architecture](docs/architecture.md) before changing behavior. The
[README](README.md) and [features](docs/features.md) describe the product.

Hob is a live, single-owner Telegram task agent on macOS. A local Ollama model
interprets free text. The service runs continuously under `launchd`.

## Rules

- Keep `core/` free of network, database, Telegram, and wall-clock I/O. Inject
  the clock, store, and model through `core/ports.py`.
- Put I/O in `adapters/`; use `app.py` for composition and edge orchestration.
- Add the MIT SPDX header to every source file.
- Avoid em dashes.
- Keep replies, docs, and commit messages short.
- Do not add `Co-Authored-By: Claude` trailers.
- Ask before adding dependencies beyond python-telegram-bot, ollama, pytest, and
  the Windows-only tzdata marker.

## Interpretation boundary

Every free-form message belongs to the model. It emits typed actions and typed
date intent at temperature 0. Code resolves dates and validates identity,
provenance, bounds, scope, confirmation, atomicity, and undo.

Never add an English phrase list, keyword router, prefix matcher, or raw-text
repair that invents semantic intent. Closed protocols may stay in code:

- slash commands;
- callback payloads;
- reactions;
- Telegram and task IDs;
- displayed ordinals.

Context such as reply anchors, focus, digests, recaps, confirmations, nudges,
and setup questions supplies typed evidence to the model. It does not authorize
an unchecked target.

Tone uses a separate hotter pass. `MessageService._varied_reply` calls
`Llm.complete_json` at temperature 0.9 and falls back to the classified reply.
Use that pattern for voice only.

## Development loop

1. Reproduce interpreter changes against live `qwen2.5:14b-instruct`.
2. Implement with the boundary above.
3. Run the Python suite.
4. Add a deterministic regression.
5. Run the real-model corpus and add a case.
6. Install and verify the live service.

```sh
uv sync --locked
uv run pytest
HOB_MODEL=qwen2.5:14b-instruct uv run python -m evals.interpreter_eval
HOB_MODEL=qwen2.5:14b-instruct uv run python -m evals.analysis_eval
scripts/install_macos.sh
scripts/hobctl status
```

## Operations

- Hob service: `com.local.hob`
- Hearth service: `com.hearth.headless`
- Preflight: `uv run python app.py doctor`
- Restart: `scripts/hobctl restart`
- Token: macOS Keychain; `HOB_TELEGRAM_TOKEN` is a development override

Never print or commit the Telegram token, Hearth credentials, task text,
message IDs, or Calendar titles.

## Data

SQLite lives in `adapters/store_sqlite.py`. Current schema: 11. Bump
`SCHEMA_VERSION`, add a migration step, update affected columns and mappers, and
add a released-schema fixture when changing persistence.

The live daemon may have pending delivery work. Preserve its database, take a
verified backup before risky deployment changes, and use the normal installer
for restart.

## Layout

```text
core/        pure task logic
adapters/    SQLite, Ollama, Telegram, Keychain, Calendar, clock, scheduler
native/      EventKit bridge, menu-bar apps, App Store foundation
app.py       composition root and services
config.py    environment validation
evals/       real-model gates
tests/       unit, integration, migration, and recovery tests
docs/        product, architecture, operations, ADRs, and audits
scripts/     setup, install, build, and service controls
assets/      product art
```

## Known limits

- Slow model calls block the single-user event loop briefly.
- Open Local targets macOS. Windows receives tzdata only for development
  compatibility.
- Telegram transit is outside the local privacy boundary.
