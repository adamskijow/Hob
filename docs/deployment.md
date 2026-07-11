<!-- SPDX-License-Identifier: MIT -->
# Deployment (launchd and Hearth)

Hob does not supervise itself; it is built to survive being killed and restarted
at any moment. Two supervisors keep the setup alive: `launchd` keeps Hob running
(restart on crash, resume on login), and
[Hearth](https://github.com/adamskijow/Hearth) keeps the Ollama model runner Hob
depends on alive (readiness checks, restart on crash or wedge, sleep
prevention). Ready-to-edit `LaunchAgent` templates for both are in
[`deploy/`](../deploy/).

Hob is one process started by `launchd`. The run command is:

```
uv run --directory /path/to/hob python app.py
```

`launchd` sets the environment, runs that command, and restarts it on exit. Copy
[`deploy/com.local.hob.plist`](../deploy/com.local.hob.plist) to
`~/Library/LaunchAgents/`, edit the paths, store the bot token with
`uv run python app.py token set`, and load it with
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
    <key>HOB_ALLOWED_TELEGRAM_USER_ID</key> <string>123456789</string>
    <key>HOB_MODEL</key>          <string>qwen2.5:7b-instruct</string>
    <key>HOB_WAKE_TIME</key>      <string>07:00</string>
    <key>HOB_DB_PATH</key>        <string>/Users/you/Library/Application Support/Hob/hob.db</string>
    <key>HOB_WORK_DAYS</key>      <string>mon,tue,wed,thu,fri</string>
  </dict>
  <key>KeepAlive</key>          <true/>
  <key>StandardOutPath</key>    <string>/Users/you/Library/Application Support/Hob/hob.log</string>
  <key>StandardErrorPath</key>  <string>/Users/you/Library/Application Support/Hob/hob.log</string>
</dict>
</plist>
```

The Telegram token lives in the user's macOS Keychain, not in the plist. The
explicit owner id is recommended for unattended installs. If omitted, the first private
`/start` pairs the database to that Telegram user. Group chats are always
rejected.

When `HOB_TIMEZONE` is absent, a real install reads the Mac's IANA system
timezone. The launchd template deliberately leaves it unset so moving the
template to another region cannot silently keep New York time. Set an explicit
IANA value only when Hob should intentionally differ from the system. Doctor,
`/settings`, and guided setup expose the effective zone.

Build the local Calendar bridge once from the checkout, then explicitly grant
access while logged into the same macOS user account that owns the LaunchAgent:

```
scripts/build_calendar_bridge.sh
uv run --directory /path/to/hob python app.py calendar authorize
```

Apple labels read access as full Calendar access. Hob's bridge exposes no write
operation and emits no event titles. If permission is denied or later revoked,
the daemon remains healthy and plans against working hours and protected breaks.

Ollama is kept alive separately by Hearth. Install Hearth, then run it headless
under `launchd` with
[`deploy/com.hearth.headless.plist`](../deploy/com.hearth.headless.plist) (it
points at the Hearth app binary and your Hearth config). The menubar app also
works, but the `LaunchAgent` survives logout and restarts on crash. Hob degrades
gracefully when the model is briefly unreachable; Hearth keeps those windows
short.

**Logging.** Hob logs to stderr (and stdout). Under `launchd`, point
`StandardErrorPath` at a file as above. The bot token is kept out of the log.
Create `~/Library/Application Support/Hob` before loading the agent. Hob does
not manage its own log files.

**Restart behavior and recovery.** Hob is safe to kill at any moment.

- Telegram updates are normalized into a durable inbox before the polling
  offset advances. Model outages and processing failures leave the message
  pending for automatic retry instead of asking the user to resend it.
- Each message's mutations, settings, undo log, conversational state, and reply
  outbox row commit as one transaction. Delivery failures retry the outbox
  without reapplying state. Stable keys deduplicate proactive messages too.
- The morning digest fires once per day. macOS sleep does not eat it: an
  in-process timer cannot fire while asleep, so on startup and on every tick Hob
  checks the last sent date and fires the digest if today's is still owed and the
  time is past wake time. The day is marked done only once the digest is actually
  sent, so a digest owed before the chat is known is not lost.
- Model timeouts or malformed output degrade to a clarifying question rather than
  a crash.

**Backups and recovery.** Backups include committed WAL changes and are
integrity-checked after writing. Restore/import verify a candidate in isolation,
safety-backup current data, and replace the database atomically.
Schema 11 backups and portable exports include proposed and adopted plan runs
and every split session. Database backups also retain operational inbox,
outbox, quarantine, and recovery history. Portable JSON exports deliberately
start with fresh operational queues and no recovery history.
The daemon holds an advisory database lease: restore/import will refuse to run
until the LaunchAgent is stopped, preventing a live process from continuing on
the replaced file. A second daemon using the same data path is rejected too.

```
uv run --directory /path/to/hob python app.py backup /safe/hob.db
uv run --directory /path/to/hob python app.py export /safe/hob.json
uv run --directory /path/to/hob python app.py restore /safe/hob.db
uv run --directory /path/to/hob python app.py import /safe/hob.json
uv run --directory /path/to/hob python app.py status
```

Status is safe to retain in operational logs: execution activation is reported
only as aggregate run/session state counts, adoption time, and plan-nudge
delivery counts. It does not print task labels, plan constraints, message text,
Telegram message identifiers, or secrets.

If status reports a failed queue, inspect content-free metadata while Hob is
still running:

```
uv run --directory /path/to/hob python app.py queue status
uv run --directory /path/to/hob python app.py queue history
```

Automatic retries remain the default. For a failure known to be permanent,
stop Hob before changing queue state. Replace `inbox` and `telegram:123` with
the direction and reference shown by queue status:

```
launchctl bootout gui/$(id -u)/com.local.hob
uv run --directory /path/to/hob python app.py queue quarantine inbox telegram:123
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.hob.plist
uv run --directory /path/to/hob python app.py status
```

Use `queue retry DIRECTION REF` instead of `quarantine` after fixing the cause.
A quarantined row is retained and can be retried later. Inbox quarantine means
the failed user turn was not applied. Outbox quarantine means Hob's state was
already applied and only that delivery is skipped. An outbound retry can
duplicate a message if Telegram accepted the earlier send without returning an
acknowledgement. Mutations refuse while Hob holds the database lease, and all
queue commands refuse to guess when both legacy and app-data databases exist.
