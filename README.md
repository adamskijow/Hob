<!-- SPDX-License-Identifier: MIT -->
<p align="center">
  <img src="assets/hob-banner.svg" alt="Hob: a realistic day, renegotiated in chat" width="100%">
</p>

# Hob

<p align="center">
  <a href="https://github.com/adamskijow/Hob/actions/workflows/ci.yml"><img src="https://github.com/adamskijow/Hob/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/adamskijow/Hob/releases/latest"><img src="https://img.shields.io/github/v/release/adamskijow/Hob?sort=semver" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT">
  <img src="https://img.shields.io/badge/macOS-black?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/python-3.12-blue?logo=python&logoColor=white" alt="Python 3.12">
  <img src="https://img.shields.io/badge/LLM-local%20(Ollama)-ff9a3c" alt="Local LLM via Ollama">
</p>

**Text Hob what is on your mind; get a realistic day and renegotiate it in chat.**

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

Unlike a command parser, Hob can also answer "what should I do next?" or "I
have 40 minutes and low energy" with a short plan grounded in the actual task
list. Semantic recall finds related work across labels, notes, projects, and
forwarded context even when the words do not match exactly. These read-only LLM
passes validate every returned item id before showing it; mutations still go
through the deterministic core.

Hob keeps *when you plan to do something* separate from its hard deadline. It
also understands estimated effort, fixed versus flexible commitments,
splittable work, earliest starts, preferred windows, subtasks, and dependencies:
"draft the board report Friday; due Monday; three hours in two sessions" becomes
one inspectable set of constraints. Recurrence is structured, so one occurrence
can move without shifting a fixed series; series can be completion-relative,
end on a date or count, and skip an occurrence. A task can have several explicit
reminder offsets instead of relying only on the global lead time.

Planning is calendar-aware on macOS. A deterministic engine lays tasks into real
free time, honoring working hours, protected breaks, durations, deadlines,
fixed commitments, dependencies, earliest starts, preferred windows, splitting,
and a stated time budget. The local EventKit bridge strips event titles and
passes only opaque busy intervals to Hob. The model explains the resulting
timeline but cannot create overlaps or invent capacity. Replanning shows what
changed from the previous proposal, and no task is moved automatically.

## Getting started

One command installs [uv](https://docs.astral.sh/uv/) and
[Ollama](https://ollama.com/) if missing, syncs deps, pulls the model, and runs
the preflight:

```
scripts/setup.sh                  # honors HOB_MODEL; safe to re-run
```

Or do it by hand (needs uv and a local Ollama with a JSON-capable instruct model):

```
ollama pull qwen2.5:7b-instruct   # or 14b-instruct if you have headroom
uv sync                           # venv, Python 3.12, deps
uv run python app.py doctor       # preflight: token, ollama, model, config, db
uv run python app.py              # start hob
```

On macOS, setup also builds Hob's signed Calendar bridge. Calendar access is a
separate, explicit step:

```
uv run python app.py calendar authorize
```

Apple exposes calendar reads through its
["full access" permission tier](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:)). Hob's
bridge itself remains read-only: it has no save or delete operation and does
not export event titles. Without permission, planning falls back cleanly to
configured working hours and breaks.

Create the bot: message [@BotFather](https://t.me/BotFather), send `/newbot`,
then store the token in macOS Keychain and message the bot privately with
`/start`:

```
uv run python app.py token set
```

`HOB_TELEGRAM_TOKEN` remains an environment-variable override for development.
The first `/start` pairs Hob to that Telegram user; every other user and all
group chats are rejected. A fresh owner then gets a five-step, resumable setup
for planning hours, planning days, protected time, default effort, and
transition space. Run
`/setup` later to review it; every preference is visible in `/settings` and each
change is undoable. For explicit deployment-time ownership, set
`HOB_ALLOWED_TELEGRAM_USER_ID` before starting.

## Usage

Talk to it like a person:

- "call the vet at 3pm" gets a reminder ping before the time; reply "done" or
  "snooze 20" to the ping, or just react with a thumbs-up to complete it.
- "take out the trash every monday" recurs; multiple weekdays, monthly/yearly,
  and intervals such as "every 2 weeks" work too. "In a couple days", "end of
  the month", and "this weekend" all resolve to real dates.
- "did everything today but the slides", "push everything to tomorrow", "what's
  overdue", "what did i finish this week", "what am i waiting on".
- "for the wedding: book the caterer, order flowers" files a tagged project;
  "add a note to the vet one: gate code is 4412" sticks a note.
- Forward someone's message or a media caption to capture it, edit a message to
  correct it, or use `/today`, `/list`, `/settings`, `/undo`, `/help`. Media Hob
  cannot read receives a text fallback rather than silence.
- Ask "plan my day", "plan tomorrow", "I have 30 minutes before I leave", or
  "my afternoon is gone" for an overlap-checked timeline and a diff from the
  prior proposal. Named future days use their own availability window.
- Ask "am I overloaded this week?" or "can I finish everything by Friday?" for
  a read-only capacity outlook. It checks the planning profile and opaque
  Calendar busy time, exposes assumptions and conflicts, and changes nothing.
- Say "use this plan" to adopt every block as a local session, including split
  work. `/plan` or "what is on my plan?" shows the active version. A revised
  proposal requires "replace my plan with this"; "cancel my plan" and `/undo`
  are safe. Adoption never changes task dates or writes Calendar events.
- Say "plan work from 9 to 5" or "protect lunch from noon to 1" to change the
  planning frame in chat. `/settings` shows the live values.
- Say "assume tasks take 45 minutes" or "leave 10 minutes between things" to
  make unstated effort and breathing room explicit. Hob never learns hidden
  preferences from behavior; it uses only settings you can inspect and undo.
- After a plan, "start the second one" follows the plan order you just saw and
  focuses that task without falsely marking it complete. Adopted order remains
  available after ordinary conversational focus expires.
- Add or edit constraints naturally: "the audit is due Friday", "this takes 45
  minutes", "do it after the numbers", "split it into two sessions", "prefer
  mornings", or "remind me an hour and 10 minutes before".
- Manage a recurring series without conflating it with today: "skip the next
  one", "repeat after I finish", "stop after five times", or "stop repeating".

The full tour lives in [everything Hob understands](docs/features.md).

## Configure

All configuration is environment variables:

| Variable | Meaning | Default |
| --- | --- | --- |
| `HOB_TELEGRAM_TOKEN` | Development override for the Keychain token | (Keychain) |
| `HOB_ALLOWED_TELEGRAM_USER_ID` | Optional explicit owner id; otherwise first private `/start` pairs | (pair on first start) |
| `HOB_MODEL` | Ollama model name | `qwen2.5:7b-instruct` |
| `HOB_WAKE_TIME` | Morning digest time, `HH:MM` 24h | `07:00` |
| `HOB_TIMEZONE` | IANA timezone override, e.g. `America/New_York` | macOS system timezone (`UTC` fallback) |
| `HOB_DB_PATH` | SQLite file path | `~/Library/Application Support/Hob/hob.db`¹ |
| `HOB_OLLAMA_HOST` | Ollama endpoint | `http://localhost:11434` |
| `HOB_KEEP_ALIVE` | How long Ollama keeps the model loaded | `-1` (resident) |
| `HOB_REMINDER_LEAD` | Minutes of heads-up before a timed task | `10` |
| `HOB_EOD_TIME` | Evening recap time (empty disables) | `20:30` |
| `HOB_CALENDAR_ENABLED` | Use the local EventKit availability bridge | `true` |
| `HOB_CALENDAR_BRIDGE` | Override path to the bridge executable | (bundled build) |
| `HOB_WORK_HOURS` | Daily planning bounds, `HH:MM-HH:MM` | `09:00-17:30` |
| `HOB_WORK_DAYS` | Days for flexible planning, comma-separated names | `mon,tue,wed,thu,fri` |
| `HOB_BREAKS` | Comma-separated protected time ranges | `12:00-13:00` |
| `HOB_DEFAULT_DURATION` | Estimate for tasks with no stated duration | `30` |
| `HOB_TRANSITION_BUFFER` | Minutes kept between commitments | `0` |

The digest and recap times can also be changed in chat ("send the morning
digest at 8"), no restart needed.

¹ Existing installs with `hob.db` in their working directory keep using it
until `HOB_DB_PATH` is changed, so upgrading does not strand prior data.

Inspect health, back up, export, or recover everything:

```
uv run python app.py status
uv run python app.py queue status
uv run python app.py queue history
uv run python app.py calendar status
uv run python app.py backup /safe/place/hob-backup.db
uv run python app.py export /safe/place/hob-export.json
uv run python app.py restore /safe/place/hob-backup.db
uv run python app.py import /safe/place/hob-export.json
```

Backup files are integrity-checked after writing. Restore and import validate a
candidate in isolation, save the current database beside it, and only then swap
the data file atomically. If both a legacy checkout database and the app-data
database exist, data commands refuse to guess; set `HOB_DB_PATH` explicitly.
Portable export and verified restore include proposal and adopted-plan sessions.
If a permanent inbound or outbound failure blocks later work, `queue status`
shows content-free metadata and the exact recovery direction/reference. Stop
the daemon before `queue retry DIRECTION REF` or
`queue quarantine DIRECTION REF`. Quarantine retains the row and is reversible;
the deployment guide explains the different inbox and outbox consequences.

## Reliability

Hob persists each Telegram update before advancing the polling offset. The
task mutations, settings, undo history, conversational state, and reply for one
message commit as a single transaction. If Ollama is temporarily unavailable,
the original message stays in the inbox and is retried automatically; the user
does not need to resend it. Replies, reminders, digests, and recaps use a
deduplicated outbox, so a network failure after applying a task does not lose
the acknowledgement or apply the task twice.

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
