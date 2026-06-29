<!-- SPDX-License-Identifier: MIT -->
# Hob handoff

Written 2026-06-29 at the end of the initial build, for continuing development in
a fresh Claude Code chat on the MacBook where Hob will actually run.

## What Hob is

A personal, single-user morning-digest agent (a long-lived daemon, supervised by
Hearth). You message a Telegram bot small tasks through the day; each morning it
sends one organized digest; you correct it in plain language and it updates the
list. The conversational reply-to-correct loop is the reason it exists. See
[README.md](README.md) for the full picture.

## Status

Built end to end, phases 0 through 9, committed one commit per phase plus this
handoff. The full suite passes: 99 tests.

```
uv sync
uv run pytest        # expect 99 passed
uv run python app.py # validates config; exits clean with no token set
```

What is verified: the entire pure core and the edge orchestration, headless,
with a fake clock, an in-memory store, and a fake LLM returning canned JSON.

What is NOT yet verified (it could not be, on the Windows dev box): the live
adapters. Nothing has talked to real Telegram, a real Ollama, or launchd. The
first job on the Mac is live bring-up.

## Architecture in one breath

Pure core, adapters at the edges. `core/` has zero I/O; the clock, store, and LLM
are injected as protocols (`core/ports.py`). `adapters/` holds all I/O. `app.py`
is the composition root and also holds the two edge orchestrators
(`MessageService`, `DigestService`).

Two rules the core never breaks:
- The model never does date math. It proposes; `core/dates.py` decides
  (deterministic, over dateparser). Ambiguity, a parser/model disagreement, or a
  parser that finds nothing where a date was intended all produce a question.
- Fuzzy language never silently mutates. An unresolved reference or low
  confidence asks; the action log plus `/undo` backs everything applied.

The interpreter (`core/interpreter.py` + `core/planner.py`) is the load-bearing
component. Everything else is plumbing.

## Live bring-up (do this first on the Mac)

1. `uv sync` then `uv run pytest` to confirm the suite passes here too.
2. Create the bot: message @BotFather, `/newbot`, copy the token into
   `HOB_TELEGRAM_TOKEN`.
3. `ollama pull qwen2.5:7b-instruct` (or set `HOB_MODEL` to another JSON-capable
   7-8B instruct build).
4. Set `HOB_TIMEZONE` (e.g. `America/New_York`) and `HOB_WAKE_TIME`.
5. `uv run python app.py`, message the bot, and walk the whole loop against the
   real model: capture with and without dates, `/today`, an ambiguous date (it
   should ask), a correction like "did the prez one, drop the pool call, push the
   audit to Friday", a query, and `/undo`.
6. Wire it under Hearth/launchd per the README and confirm restart recovery
   (kill mid-run, restart, no reprocessed captures, no double digest).

## Things most likely to need attention

- Prompt tuning against the real 7-8B model. The interpreter prompt is in
  `core/interpreter.py`. The parser/model date-disagreement check
  (`core/planner.py`) errs toward asking; with a real model you may find it asks
  too often on relative weekdays and want to relax it.
- Reference and ordinal resolution quality (the model maps "the prez one" / "the
  third one" to an id; the planner validates the id). Watch how often it lands.
- The handler runs synchronously inside the asyncio loop, so a slow model call
  briefly blocks polling and the scheduler tick. Fine for one user; revisit with
  an executor only if it bites.

## Honest caveats about this repo

- Developed on Windows, targets macOS. `tzdata` is a dependency only under a
  `sys_platform == 'win32'` marker so stdlib `zoneinfo` works on the dev box; it
  is a no-op on macOS.
- The per-phase commit history was reconstructed by forward-replay at the end of
  the build (it was not committed incrementally during the original session).
  HEAD is the verified, tested state. The intermediate commits faithfully show
  the code narrative, but `pyproject.toml` only declares the full runtime
  dependency set at the phase 9 (HEAD) commit, so a fresh `uv sync` checked out
  at an intermediate commit (phases 5 to 8) would not install dateparser/ollama.
  Work from HEAD.
- Python is pinned to 3.12 via uv (the dev box had 3.14; 3.12 is safer for the
  date and telegram libraries). Reconsider on the Mac if you prefer the system
  Python.

## Constraints to keep

Pure core, MIT with `# SPDX-License-Identifier: MIT` on every source file, no em
dashes anywhere, terse output and commit messages. Ask before adding any
dependency beyond python-telegram-bot, dateparser, ollama, pytest (and the
Windows-only tzdata).

## Prompt to paste into the new chat

> I'm continuing development of Hob, a personal morning-digest agent, now on the
> MacBook where it will actually run. Clone or pull the repo from
> github.com/adamskijow/Hob. It is already built: 10 commits (phase 0 through
> phase 9) plus a handoff, 99 passing tests. Before anything else, read
> HANDOFF.md and README.md in the repo root, then run `uv sync && uv run pytest`
> to confirm the suite passes on this machine.
>
> Key context: pure core (core/, zero I/O) plus adapters (adapters/) plus app.py
> composition root; the interpreter is the load-bearing component. Two rules the
> core never breaks: the model never does date math (deterministic dateparser
> resolution, ambiguity asked about), and fuzzy language never silently mutates
> (low confidence or unresolved reference asks; action log plus /undo backs
> everything). It was developed on Windows and targets macOS, so the live
> adapters (Telegram long-poll, Ollama, launchd/Hearth) have never run, only been
> unit-tested with fakes. The first job is live bring-up.
>
> Likely next steps, confirm with me before large changes: (1) live bring-up:
> create the Telegram bot via BotFather and set HOB_TELEGRAM_TOKEN, `ollama pull
> qwen2.5:7b-instruct`, `uv run python app.py`, and verify capture, /today, the
> morning digest, reply-to-correct, and /undo end to end against the real model;
> (2) tune the interpreter prompt against the real 7-8B model, especially the
> date-disagreement-ask behavior and reference resolution; (3) wire it under
> Hearth/launchd per the README and confirm restart recovery.
>
> Keep the constraints: pure core, MIT plus SPDX headers, no em dashes, terse
> output, ask before adding dependencies beyond python-telegram-bot / dateparser
> / ollama / pytest.
