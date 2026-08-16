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
</p>

Hob is a private task agent for macOS. Text it what is on your mind, get a
realistic plan, and revise that plan in ordinary language.

A local Ollama model interprets messages. Tested code owns dates, task identity,
capacity, confirmation, persistence, and undo. Telegram carries chat messages.
The task database and model inference stay on the Mac unless remote Ollama is
explicitly enabled.

The released Open Local edition runs as a background service with a menu-bar
teapot. A local [iPhone and Mac app](docs/app-store.md) is in development.

## What it does

- Captures, edits, completes, drops, reschedules, and groups tasks from natural
  messages, forwards, captions, replies, and reactions.
- Sends a morning digest, timed reminders, stale-task checks, and an evening
  recap. Digest pinning is optional and defaults off. Replies such as `nada` or
  `today was a wash` keep all shown work open.
- Plans around work hours, breaks, deadlines, dependencies, estimates, fixed
  commitments, and opaque Calendar busy periods.
- Adopts, replaces, cancels, and explains plans with undoable state changes.
- Answers capacity and what-if questions without changing saved work.
- Supports recurrence, multiple reminders, notes, projects, waiting-on, bulk
  updates, semantic recall, backup, export, restore, and import.

See [Everything Hob understands](docs/features.md) for examples.

## Install

On macOS:

```sh
scripts/setup.sh
```

The script installs missing tools, syncs locked dependencies, pulls the model,
runs preflight checks, and installs Hob plus its menu-bar control at login.

Manual setup:

```sh
ollama pull qwen2.5:7b-instruct
uv sync --locked
uv run python app.py doctor
scripts/install_macos.sh
```

For Calendar-aware planning:

```sh
uv run python app.py calendar authorize
```

Hob reads busy intervals through a signed EventKit bridge. Event titles stay
inside the bridge. Planning falls back to work hours and breaks when Calendar
access is unavailable.

## Connect Telegram

1. Create a bot with [@BotFather](https://t.me/BotFather).
2. Store its token:

   ```sh
   uv run python app.py token set
   ```

3. Send the bot `/start` in a private chat.
4. Run the pairing command it shows, then send `/start` again:

   ```sh
   scripts/hobctl pair TELEGRAM_USER_ID
   ```

Pairing happens on the Mac. Other users and group chats are ignored before
their content reaches storage. Setup then asks about work hours, work days,
protected time, default effort, and transition time. Use `/setup` to resume and
`/settings` to review the result.

## Use it

Try messages such as:

- `Call the vet tomorrow at 3.`
- `I did home insurance and called the bank.`
- `Move everything to Monday except taxes, which goes Sunday.`
- `Plan tomorrow. I have 40 minutes and low energy.`
- `Why didn't the audit fit?`
- `What if it took 30 minutes and I worked until 7?`
- `Use this plan.`
- `Take out the trash every Monday.`
- `Pin my morning digest.`

Useful commands: `/today`, `/list`, `/plan`, `/outlook`, `/settings`, `/setup`,
`/undo`, and `/help`.

## Configuration

| Variable | Purpose | Default |
| --- | --- | --- |
| `HOB_TELEGRAM_TOKEN` | Development override for the Keychain token | Keychain |
| `HOB_ALLOWED_TELEGRAM_USER_ID` | Owner ID for managed installs | Local pairing |
| `HOB_MODEL` | Ollama model | `qwen2.5:7b-instruct` |
| `HOB_WAKE_TIME` | Morning digest time | `07:00` |
| `HOB_EOD_TIME` | Evening recap time; empty disables it | `20:30` |
| `HOB_TIMEZONE` | IANA timezone | `UTC` |
| `HOB_DB_PATH` | SQLite database | `~/Library/Application Support/Hob/hob.db` |
| `HOB_OLLAMA_HOST` | Ollama endpoint | `http://localhost:11434` |
| `HOB_ALLOW_REMOTE_OLLAMA` | Permit a remote HTTPS Ollama endpoint | `false` |
| `HOB_KEEP_ALIVE` | Ollama model lifetime | `-1` |
| `HOB_REMINDER_LEAD` | Default reminder lead in minutes | `10` |
| `HOB_CALENDAR_ENABLED` | Use EventKit availability | `true` |
| `HOB_CALENDAR_BRIDGE` | EventKit bridge path override | Bundled build |
| `HOB_WORK_HOURS` | Planning bounds | `09:00-17:30` |
| `HOB_WORK_DAYS` | Flexible planning days | `mon,tue,wed,thu,fri` |
| `HOB_BREAKS` | Protected ranges | `12:00-13:00` |
| `HOB_DEFAULT_DURATION` | Unstated task estimate | `30` |
| `HOB_TRANSITION_BUFFER` | Minutes between commitments | `0` |

Digest, recap, pinning, and planning settings can also be changed in chat.

Remote Ollama requires HTTPS and `HOB_ALLOW_REMOTE_OLLAMA=1`. `doctor` and
`status` show when task text leaves the Mac. Endpoint URLs cannot contain
credentials.

## Operations

The menu-bar teapot can start, restart, inspect, and open Hob's logs. Terminal
equivalents:

```sh
scripts/hobctl status
scripts/hobctl on
scripts/hobctl restart
scripts/hobctl logs
```

Data commands:

```sh
uv run python app.py backup /safe/place/hob.db
uv run python app.py export /safe/place/hob.json
uv run python app.py restore /safe/place/hob.db
uv run python app.py import /safe/place/hob.json
```

Hob creates databases, sidecars, locks, backups, exports, and logs owner-only.
Backups and recovery candidates receive integrity checks. The application log
rotates at 5 MiB with three backups.

## More docs

- [Features](docs/features.md)
- [Architecture](docs/architecture.md)
- [Deployment](docs/deployment.md)
- [Development](docs/development.md)
- [1.0 acceptance audit](docs/audits/v1.0-acceptance.md)

## License

MIT.
