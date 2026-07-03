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
[`deploy/com.hearth.headless.plist`](../deploy/com.hearth.headless.plist) (it
points at the Hearth app binary and your Hearth config). The menubar app also
works, but the `LaunchAgent` survives logout and restarts on crash. Hob degrades
gracefully when the model is briefly unreachable; Hearth keeps those windows
short.

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
