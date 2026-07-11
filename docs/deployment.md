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
    <key>HOB_TIMEZONE</key>       <string>America/New_York</string>
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
Schema 10 backups and portable exports include proposed and adopted plan runs
and every split session.
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
