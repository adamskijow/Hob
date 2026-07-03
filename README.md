<!-- SPDX-License-Identifier: MIT -->
<p align="center">
  <img src="assets/hob-banner.svg" alt="Hob: text tasks all day, wake to one organized digest" width="100%">
</p>

# Hob

<p align="center">
  <a href="https://github.com/adamskijow/Hob/actions/workflows/ci.yml"><img src="https://github.com/adamskijow/Hob/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT">
  <img src="https://img.shields.io/badge/macOS-black?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/python-3.12-blue?logo=python&logoColor=white" alt="Python 3.12">
  <img src="https://img.shields.io/badge/LLM-local%20(Ollama)-ff9a3c" alt="Local LLM via Ollama">
</p>

**Text tasks to a Telegram bot all day; wake to one organized morning digest.**

Hob is a personal task agent that understands plain language, powered by a
local LLM (Ollama) and run as a long-lived daemon on macOS. It is named for the
ledge at the side of a hearth where a kettle is kept warm and ready.

## Why

Some tasks are too small for a calendar and too fleeting to survive until you
open a to-do app. With Hob you just text them ("call the pool guy", "dentist
next friday at 2pm") and each morning one digest lays out your day. Corrections
are the point: "already did the prez one", "push the audit to wednesday",
"that's urgent", "scratch that" all work, because every message flows through
one natural-language interpreter. When a message is ambiguous, Hob asks instead
of guessing, and every change is undoable. The model and your data stay on your
machine; only the Telegram transport leaves it.

## Getting started

Requires [uv](https://docs.astral.sh/uv/) and a local
[Ollama](https://ollama.com/) with a JSON-capable instruct model:

```
ollama pull qwen2.5:7b-instruct   # or 14b-instruct if you have headroom
uv sync                           # venv, Python 3.12, deps
uv run python app.py doctor       # preflight: token, ollama, model, config, db
uv run python app.py              # start hob
```

Create the bot: message [@BotFather](https://t.me/BotFather), send `/newbot`,
then in the bot's settings restrict usage to just yourself (Hob has no per-user
gate of its own). Put the token in `HOB_TELEGRAM_TOKEN` and message the bot once
(`/start`); that first message tells Hob where to send the digest.

## Usage

Talk to it like a person:

- "call the vet at 3pm" gets a reminder ping before the time; reply "done" or
  "snooze 20" to the ping, or just react with a thumbs-up to complete it.
- "take out the trash every monday" recurs; "in a couple days", "end of the
  month", "this weekend" all resolve to real dates.
- "did everything today but the slides", "push everything to tomorrow", "what's
  overdue", "what did i finish this week", "what am i waiting on".
- "for the wedding: book the caterer, order flowers" files a tagged project;
  "add a note to the vet one: gate code is 4412" sticks a note.
- Forward someone's message to capture it, edit a message to correct it, or use
  `/today`, `/undo`, `/help`.

The full tour lives in [everything Hob understands](docs/features.md).

## Configure

All configuration is environment variables:

| Variable | Meaning | Default |
| --- | --- | --- |
| `HOB_TELEGRAM_TOKEN` | Bot token from BotFather | (none; bot disabled) |
| `HOB_MODEL` | Ollama model name | `qwen2.5:7b-instruct` |
| `HOB_WAKE_TIME` | Morning digest time, `HH:MM` 24h | `07:00` |
| `HOB_TIMEZONE` | IANA timezone, e.g. `America/New_York` | `UTC` |
| `HOB_DB_PATH` | SQLite file path | `hob.db` |
| `HOB_OLLAMA_HOST` | Ollama endpoint | `http://localhost:11434` |
| `HOB_KEEP_ALIVE` | How long Ollama keeps the model loaded | `-1` (resident) |
| `HOB_REMINDER_LEAD` | Minutes of heads-up before a timed task | `10` |
| `HOB_EOD_TIME` | Evening recap time (empty disables) | `20:30` |

The digest and recap times can also be changed in chat ("send the morning
digest at 8"), no restart needed.

## Docs

- [Everything Hob understands](docs/features.md): the full feature tour.
- [Architecture](docs/architecture.md): pure core, adapters at the edges, and
  the two correctness rules (the model never does date math; fuzzy language
  never silently mutates state).
- [Deployment](docs/deployment.md): run it durably under `launchd`, with
  [Hearth](https://github.com/adamskijow/Hearth) keeping Ollama alive.
- [Development](docs/development.md): the test suite and the real-model eval.

## License

MIT. Every source file starts with `# SPDX-License-Identifier: MIT`.
