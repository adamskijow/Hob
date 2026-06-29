<!-- SPDX-License-Identifier: MIT -->
# Hob

Hob is a personal, single-user morning-digest agent. It runs as a long-lived
daemon. It is named for the ledge at the side of a hearth where a kettle is kept
warm and ready. Hob is meant to be supervised by Hearth (a separate macOS
supervisor daemon): Hearth keeps Hob alive, Hob keeps the day's small tasks warm
until they are picked up.

## The loop

1. **Capture.** Throughout the day you send short messages to a Telegram bot
   ("call the pool guy", "review the SR audit before standup"). Tasks too small
   to put on a calendar.
2. **EOD report.** At end of day you message what you got done. This closes items.
3. **Morning digest.** Each morning the bot sends one organized message: today's
   items plus anything undone that rolled forward.
4. **Reply to correct.** The morning digest will often be wrong, because the EOD
   report is easy to forget. You fix it in plain language ("already did the prez
   one", "drop the pool call", "push the audit to Wednesday", "what's on for
   tomorrow?") and Hob updates the list. Every inbound message flows through one
   interpreter that decides what you meant and turns it into concrete actions.

Feature 4 is the reason Hob exists rather than a standard to-do app.

## Setup

Requires [uv](https://docs.astral.sh/uv/) and a local
[Ollama](https://ollama.com/) install.

```
uv sync                       # create the venv, fetch Python, install deps
uv run python app.py          # start hob
uv run pytest                 # run the test suite
```

Configuration is read from environment variables:

| Variable | Meaning | Default |
| --- | --- | --- |
| `HOB_TELEGRAM_TOKEN` | Bot token from BotFather | (none; bot disabled) |
| `HOB_MODEL` | Ollama model name | `qwen2.5:7b-instruct` |
| `HOB_WAKE_TIME` | Morning digest time, `HH:MM` 24h | `07:00` |
| `HOB_TIMEZONE` | IANA timezone, e.g. `America/New_York` | `UTC` |
| `HOB_DB_PATH` | SQLite file path | `hob.db` |
| `HOB_OLLAMA_HOST` | Ollama endpoint | `http://localhost:11434` |

Creating the Telegram bot and pulling the model are documented as those phases
land.

## Architecture

Pure core, adapters at the edges. All logic lives in `core/` with zero I/O: no
network, no `sqlite3`, no Telegram library, no wall-clock reads. The LLM call,
the clock, and the store are injected as protocols (`core/ports.py`). This makes
the core fully unit-testable headless with a fake clock, fake store, and fake
LLM, and makes it portable: the capture channel and storage are swappable
without touching the logic.

All I/O lives in `adapters/`. `app.py` is the composition root that wires
adapters into the core and runs the daemon.

## Hearth integration

To be written (Phase 9). Hearth (or `launchd`) starts Hob, restarts it on crash,
and owns its lifecycle. Hob is built to survive being killed and restarted at any
moment.

## Caveat: not fully local

The model and the store run locally, but Telegram messages transit Telegram's
servers, so this is not an end-to-end local pipeline. The capture channel is the
swappable part: anyone who needs fully local can replace the Telegram adapter
without touching the core.

## License

MIT. Every source file starts with an SPDX header:
`# SPDX-License-Identifier: MIT`.
