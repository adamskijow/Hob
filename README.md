<!-- SPDX-License-Identifier: MIT -->
# Hob

Hob is a personal, single-user morning-digest agent that runs as a long-lived
daemon on macOS. It is named for the ledge at the side of a hearth where a kettle
is kept warm and ready. Hob does not supervise itself, and it is built to survive
being killed and restarted at any moment. Two supervisors keep the setup alive:
`launchd` keeps Hob running (restart on crash, resume on login), and
[Hearth](https://github.com/adamskijow/Hearth), a separate macOS supervisor,
keeps the local model runner (Ollama) that Hob depends on alive and serving. See
[Deployment](#deployment-launchd-and-hearth).

## The loop

1. **Capture.** Throughout the day you send short messages to a Telegram bot
   ("call the pool guy", "review the SR audit before standup"). Tasks too small
   to put on a calendar.
2. **EOD report.** At end of day you message what you got done. This closes items.
3. **Morning digest.** Each morning the bot sends one organized message: today's
   items plus anything undone that rolled forward from prior days.
4. **Reply to correct.** The morning digest will often be wrong, because the EOD
   report is easy to forget. You fix it in plain language ("already did the prez
   one", "drop the pool call, not happening", "push the audit to Wednesday",
   "what's on for tomorrow?") and Hob updates the list. Every inbound message
   flows through one interpreter that decides what you meant and turns it into
   concrete actions.

Feature 4 is the reason Hob exists rather than a standard to-do app. The
interpreter is the load-bearing component; everything else is plumbing.

When a message is ambiguous (two possible dates, an unclear reference) Hob asks
instead of guessing, and it remembers the question: your next message is read as
the answer. So "lunch with sam thursday or friday" followed by "thursday"
captures it for Thursday, rather than the reply being misread on its own. The
context Hob keeps is deliberately small (the one open question), not a running
chat transcript; the task list itself carries the rest. You can also act on many
items at once in plain language ("did everything today", "clear my whole list",
"drop all of friday").

A task with a time ("call the vet at 3pm") also gets a one-off reminder ping at
that moment, not just a line in the morning digest. Rescheduling it re-arms the
reminder for the new time.

A recurring task ("take out the trash every monday", "water the plants daily",
"standup every weekday") reappears each occurrence: completing it advances to the
next one and stays on the list rather than closing. Dropping it ends the series.

## Commands

- `/today` lists what is open.
- `/undo` reverts your last change (one inbound message is one undoable batch;
  repeat to walk further back).
- `/help` shows a one-liner.

Everything else is just plain language. You can ask ("what's on today", "what's
overdue", "what do I have this week", "anything about the audit", "what did I
finish today"), move many at once ("push everything to tomorrow"), and undo
conversationally ("scratch that") as well as with `/undo`.

## Setup

Requires [uv](https://docs.astral.sh/uv/) and a local
[Ollama](https://ollama.com/).

```
uv sync                       # create the venv, fetch Python 3.12, install deps
uv run pytest                 # run the test suite
uv run python app.py          # start hob
```

### Create the Telegram bot

1. In Telegram, message [@BotFather](https://t.me/BotFather) and send
   `/newbot`. Follow the prompts to name the bot.
2. BotFather replies with an HTTP API token like `123456:ABC-DEF...`.
3. Put it in the environment as `HOB_TELEGRAM_TOKEN` (see config below). Hob
   learns which chat to send the morning digest to from the first message you
   send it, so message the bot once after starting it.

### Pull the model

```
ollama pull qwen2.5:7b-instruct
```

Any JSON-capable 7-8B instruct model works (a current Llama or Qwen instruct
build). Set the name with `HOB_MODEL`. Hob uses Ollama's structured-output mode,
so the model is forced to return valid JSON.

### Configuration

All configuration is environment variables:

| Variable | Meaning | Default |
| --- | --- | --- |
| `HOB_TELEGRAM_TOKEN` | Bot token from BotFather | (none; bot disabled) |
| `HOB_MODEL` | Ollama model name | `qwen2.5:7b-instruct` |
| `HOB_WAKE_TIME` | Morning digest time, `HH:MM` 24h | `07:00` |
| `HOB_TIMEZONE` | IANA timezone, e.g. `America/New_York` | `UTC` |
| `HOB_DB_PATH` | SQLite file path | `hob.db` |
| `HOB_OLLAMA_HOST` | Ollama endpoint | `http://localhost:11434` |
| `HOB_KEEP_ALIVE` | How long Ollama keeps the model loaded: `-1` resident, seconds, or a duration like `30m` | `-1` |

Wake time and timezone are validated at startup; a bad value exits with a clear
message and a non-zero code.

## Architecture

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
  dates.py        deterministic date resolution + ambiguity detection
  planner.py      Actions + context -> concrete mutations (no I/O)
  digest.py       owed-decision, digest selection + rollover, rendering
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

- **The model never does date math.** It proposes a date phrase, copied verbatim
  from your words; a deterministic parser (`dates.py`, over `dateparser`)
  resolves it. On ambiguity (more than one date in the phrase) or a phrase that
  resolves to nothing where a date was meant, Hob asks rather than guesses.
- **Fuzzy language never silently mutates state.** An unresolved reference or a
  low-confidence guess produces a clarifying question, not an edit, and Hob
  remembers that question so your next message can answer it. A reschedule whose
  date words are not actually in your message is treated as a misread and asked
  about. The action log plus `/undo` backs everything that does get applied.

## Deployment (launchd and Hearth)

Hob has two supervisors: `launchd` keeps Hob alive, and
[Hearth](https://github.com/adamskijow/Hearth) keeps the Ollama model runner Hob
depends on alive (readiness checks, restart on crash or wedge, sleep prevention).
Ready-to-edit `LaunchAgent` templates for both are in [`deploy/`](deploy/).

Hob is one process started by `launchd`. The run command is:

```
uv run --directory /path/to/hob python app.py
```

`launchd` sets the environment, runs that command, and restarts it on exit. Copy
[`deploy/com.local.hob.plist`](deploy/com.local.hob.plist) to
`~/Library/LaunchAgents/`, edit the paths and fill `HOB_TELEGRAM_TOKEN`, then
`chmod 600` it (it holds the token) and load it with
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.hob.plist`.
That template expands the minimal plist below with `WorkingDirectory`, `PATH`,
and `HOB_KEEP_ALIVE`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.local.hob</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/you/.local/bin/uv</string>
    <string>run</string>
    <string>--directory</string>
    <string>/Users/you/hob</string>
    <string>python</string>
    <string>app.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOB_TELEGRAM_TOKEN</key> <string>123456:ABC-DEF...</string>
    <key>HOB_MODEL</key>          <string>qwen2.5:7b-instruct</string>
    <key>HOB_WAKE_TIME</key>      <string>07:00</string>
    <key>HOB_TIMEZONE</key>       <string>America/New_York</string>
    <key>HOB_DB_PATH</key>        <string>/Users/you/hob/hob.db</string>
  </dict>
  <key>KeepAlive</key>          <true/>
  <key>StandardOutPath</key>    <string>/Users/you/hob/hob.log</string>
  <key>StandardErrorPath</key>  <string>/Users/you/hob/hob.log</string>
</dict>
</plist>
```

Keep the plist readable only by your user; it holds the bot token.

Ollama is kept alive separately by Hearth. Install Hearth, then run it headless
under `launchd` with
[`deploy/com.hearth.headless.plist`](deploy/com.hearth.headless.plist) (it points
at the Hearth app binary and your Hearth config). The menubar app also works, but
the `LaunchAgent` survives logout and restarts on crash. Hob degrades gracefully
when the model is briefly unreachable; Hearth keeps those windows short.

**Logging.** Hob logs to stderr (and stdout). Under `launchd`, point
`StandardErrorPath` at a file as above. The bot token is kept out of the log.
Hob does not manage its own log files.

**Restart behavior and recovery.** Hob is safe to kill at any moment.

- Telegram polling resumes from the update offset saved in the database, so the
  backlog is not reprocessed on restart. A hard kill mid long-poll causes a brief
  `Conflict` while Telegram releases the old connection; Hob backs off and
  resumes, and queued messages are delivered, not lost.
- If a crash redelivers a message whose changes were already applied, Hob
  recognizes it by its message id and does not apply or reply twice.
- The morning digest fires once per day. macOS sleep does not eat it: an
  in-process timer cannot fire while asleep, so on startup and on every tick Hob
  checks the last sent date and fires the digest if today's is still owed and the
  time is past wake time. The day is marked done only once the digest is actually
  sent, so a digest owed before the chat is known is not lost.
- Model timeouts or malformed output degrade to a clarifying question rather than
  a crash.

## Caveat: not fully local

The model and the store run locally, but Telegram messages transit Telegram's
servers, so this is not an end-to-end local pipeline. The capture channel is the
swappable part: anyone who needs fully local can replace the Telegram adapter
(`adapters/telegram_bot.py`) without touching the core.

## Development

```
uv run pytest
```

Core modules are near-fully covered with a fake clock, an in-memory store, and a
fake LLM returning canned JSON. Adapters get thin smoke tests.

The unit suite uses a fake LLM. To check the interpreter against the *real*
model (after tuning the prompt or changing `HOB_MODEL`), run the eval, which
feeds representative messages through Ollama and asserts the resulting plan:

```
HOB_MODEL=qwen2.5:14b-instruct uv run python evals/interpreter_eval.py
```
 On Windows, a
`tzdata` package is installed under a platform marker so the standard-library
`zoneinfo` has a timezone database; on the macOS target the OS provides it and
the marker keeps it off that environment.

## License

MIT. Every source file starts with an SPDX header:
`# SPDX-License-Identifier: MIT`.
