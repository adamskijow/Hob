<!-- SPDX-License-Identifier: MIT -->
# Working on Hob

Guidance for a coding agent picking up this repo. Read this first, then
[docs/architecture.md](docs/architecture.md) for the design in depth. The
[README](README.md) and [docs/features.md](docs/features.md) describe the
product for users.

Hob is a personal, single-user task agent. You text small tasks to a Telegram
bot in plain language; each morning it sends one organized digest; you correct
it conversationally. A local LLM (Ollama) does the understanding. It runs as a
long-lived daemon on macOS and is live: it has been running and used daily.

## Conventions (do not break these)

- **Pure core.** Everything in `core/` has zero I/O: no network, no `sqlite3`,
  no Telegram, no wall-clock reads. The clock, store, and LLM are injected as
  protocols (`core/ports.py`). All I/O lives in `adapters/`; `app.py` is the
  composition root and holds the edge orchestrators.
- **MIT + SPDX.** Every source file starts with `# SPDX-License-Identifier: MIT`
  (or the HTML-comment form in Markdown).
- **No em dashes anywhere.** Use commas, parentheses, or colons.
- **Terse.** Short replies, short commit messages.
- **No `Co-Authored-By: Claude` trailer** on commits. The user wants sole
  authorship; the whole history was rewritten once to remove it.
- **Ask before adding a dependency** beyond the named set: python-telegram-bot,
  ollama, pytest (plus tzdata under a `win32` marker).

## The doctrine: model proposes, core disposes

The interpreter (`core/interpreter.py` + `core/planner.py`) is the load-bearing
component. The split that makes it reliable:

- **The model classifies; it never computes or commits.** It reads a message
  into structured actions at `temperature=0`. Dates are emitted as a typed
  intent (`core.models.When`: `tomorrow`, `weekday`, `offset`, `month`,
  `ambiguous`, ...), NOT a computed date. `core/dates.resolve_intent` does the
  calendar math, exactly and testably. Raw-text date parsing was removed so the
  core cannot silently replace the model's semantic date classification.
- **Fuzzy language never silently mutates state.** Ambiguity asks; an unresolved
  reference or low confidence asks; sweeping deletes and far-future dates are
  held for a yes/no. The action log plus `/undo` backs everything applied.

**Every free-form message is model-owned.** Do not add an English phrase list,
prefix matcher, keyword router, or raw-text repair that synthesizes semantic
intent. A rules-only shortcut is both brittle and contrary to Hob's product
value. The interpreter uses typed structured output plus small focused semantic
audits for contextual decisions, capture/plan/undo disagreements, settings,
schedule metadata, recaps, and bulk scope/exclusions.

The core may reconcile only machine-owned facts and invariants:

- resolve typed date intent with deterministic calendar math;
- map model-proposed ids, positions, and ordinals to exact active items;
- verify reply, focus, digest, recap, nudge, confirmation, and onboarding
  provenance before using that conversational context;
- validate literal grounding for setting values, numeric bounds, confidence,
  destructive scope, target existence, and exclusion membership;
- hold ambiguity and high-impact changes for explicit confirmation;
- apply mutations atomically and record them for undo.

Slash commands, callbacks, reactions, message ids, and ordinals are closed
machine protocols and may remain deterministic. Conversational focus and
reply-to anchoring (`_load_focus`, `_replied_item`) supply context to the model;
they do not authorize an unverified target.

**The exception: tone is the model's job.** Chitchat replies are generated, so
warmth belongs in the prompt, and variety comes from a second, hotter pass:
classification runs at temp 0, then `MessageService._varied_reply` makes one
more call at `temperature=0.9` to write the reply, falling back to the classified
text on failure. `Llm.complete_json` takes an optional `temperature` (default 0).
Reuse this "cold decide, hot deliver" pattern for other voice, never for facts.

## How work gets done here

1. **Probe the real model first** when a change touches the interpreter. Write a
   throwaway script in the scratchpad that runs candidate messages through a
   live `OllamaLlm` (14b) and prints the parsed actions/plan. Validate the model
   behavior before writing code. Most bugs this repo has seen came in as
   screenshots and were reproduced this way.
2. **Implement**, keeping the core pure and the fix deterministic where it is
   about correctness.
3. **`uv run pytest`** (currently 417 passing). Add a unit test for any new core
   behavior.
4. **Run the eval** against the real model and add a case for the new behavior:
   `HOB_MODEL=qwen2.5:14b-instruct uv run python -m evals.interpreter_eval`
   (currently 102/102). The eval is the real-model regression net; keep it green.
5. **Deploy** by restarting the daemon (see Ops). Confirm the fix live.

## Ops (this is a live daemon)

- Hob runs under `launchd` as `com.local.hob`. Ollama is kept alive separately
  by [Hearth](https://github.com/adamskijow/Hearth) as `com.hearth.headless`.
  Details in [docs/deployment.md](docs/deployment.md).
- **Restart after a code change** (graceful, avoids a Telegram `Conflict` blip):
  `launchctl kill SIGTERM gui/$(id -u)/com.local.hob`, then poll for the new pid.
- If replies say "can't reach the model", **Ollama is down** (usually because
  the Hearth headless agent got unloaded, e.g. during a Hearth release). Hob
  degrades gracefully by design; bring Ollama/Hearth back.
- `uv run python app.py doctor` is the preflight: token, Ollama, model pulled,
  config, db. `scripts/setup.sh` is one-command setup.
- The bot token is a secret stored in macOS Keychain. Never print or commit it.
  `HOB_TELEGRAM_TOKEN` is only a development override.

## Data and schema

SQLite (`adapters/store_sqlite.py`). Schema is versioned by `PRAGMA
user_version` (`SCHEMA_VERSION`, currently 10) with stepped `ALTER TABLE`
migrations in `_migrate`. To add an item column: bump the version, add a
migration step, and extend `_ITEM_COLS`, `add_item`, `update_item`,
`_row_to_item`, and the `Item` dataclass. A restart migrates the live db.

## Layout

```
core/        pure logic (models, ports, interpreter, planner, dates,
             digest, recurrence, feasibility, undo)
adapters/    I/O (store_sqlite, llm_ollama, telegram_bot, clock, scheduler,
             calendar_eventkit)
native/      signed Swift EventKit bridge (busy times only, no event titles)
app.py       composition root + MessageService/DigestService/ReminderService/EODService
config.py    env config + validation
evals/       real-model interpreter eval
tests/       fakes + full suite
docs/        architecture, features, deployment, development
scripts/     setup.sh
assets/      banner, social card, bot avatar (svg + rendered png/jpg)
```

## Gotchas

- The message handler runs synchronously inside the asyncio loop, so a slow
  model call briefly blocks polling and the scheduler tick. Fine for one user.
- Targets macOS; `tzdata` is a dependency only under a `win32` marker.
- Rendering SVG assets to PNG/JPG: `sips -s format png in.svg --out out.png`
  works without extra tooling; a `cmd | grep -q` under `set -o pipefail` trips
  SIGPIPE (see the `scripts/setup.sh` note).
