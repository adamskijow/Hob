<!-- SPDX-License-Identifier: MIT -->
# Architecture

Pure core, adapters at the edges. All logic lives in `core/` with zero I/O: no
network, no `sqlite3`, no Telegram library, no wall-clock reads. The LLM call,
the clock, and the store are injected as protocols (`core/ports.py`). This makes
the core fully unit-testable headless with a fake clock, an in-memory store, and
a fake LLM that returns canned JSON, and it makes the design portable: the
capture channel and the storage are swappable without touching the logic.

```
core/         pure, zero I/O, fully tested, time injected
  models.py       Item, Action variants, Digest, etc.
  ports.py        Protocols: Store, Llm, Clock
  interpreter.py  builds the prompt; parses + validates JSON into Actions
  dates.py        date-intent resolution + day-word backstops
  planner.py      Actions + context -> concrete mutations (no I/O)
  digest.py       owed-decision, digest selection + rollover, rendering
  recurrence.py   recurring-rule parsing + next-occurrence math
  undo.py         action-log replay / revert (operates on snapshots)
adapters/     all I/O lives here
  store_sqlite.py SQLite Store
  llm_ollama.py   Ollama structured-output client
  telegram_bot.py long-poll loop, offset persistence
  clock.py        real clock
  scheduler.py    morning-digest timer + catch-up-on-wake
app.py        composition root: wire adapters into core, run the daemon
config.py     env config + validation
```

Two correctness rules the core never breaks:

- **The model never does date math.** It classifies a date phrase into a typed
  intent ("next friday" becomes weekday/next/fri); the core (`dates.py`) does
  the calendar arithmetic, exactly and testably. Day words named in the message
  ("monday", "tomorrow") deterministically win over a misclassified intent, and
  on ambiguity ("thursday or friday") Hob asks rather than guesses.
- **Fuzzy language never silently mutates state.** An unresolved reference or a
  low-confidence guess produces a clarifying question, not an edit, and Hob
  remembers that question so your next message can answer it. Sweeping deletes
  and implausibly far dates are held for a yes/no. The action log plus `/undo`
  backs everything that does get applied.

## Caveat: not fully local

The model and the store run locally, but Telegram messages transit Telegram's
servers, so this is not an end-to-end local pipeline. The capture channel is the
swappable part: anyone who needs fully local can replace the Telegram adapter
(`adapters/telegram_bot.py`) without touching the core.
