<!-- SPDX-License-Identifier: MIT -->
# Deployment

## Supported macOS install

```sh
scripts/install_macos.sh
```

The installer:

- preserves existing daemon settings;
- refuses ambiguous database paths;
- builds and signs **Hob Local.app**;
- installs Hob and its menu control as user LaunchAgents;
- starts or restarts Hob when a Telegram token is available.

Run it again to update or repair the installation. The menu-bar teapot provides
start, restart, health, logs, and data-folder actions. Terminal equivalents:

```sh
scripts/hobctl status
scripts/hobctl on
scripts/hobctl restart
scripts/hobctl logs
```

Hob runs under `launchd` as `com.local.hob`. Hearth supervises Ollama as
`com.hearth.headless`. Install Hearth's login agent with:

```sh
/Applications/Hearth.app/Contents/MacOS/Hearth install-agent
```

Both services return at login.

## Telegram ownership

Store the bot token in macOS Keychain:

```sh
uv run python app.py token set
```

For local pairing, send `/start` to the bot, then run the command it shows:

```sh
scripts/hobctl pair TELEGRAM_USER_ID
```

Managed installs may set `HOB_ALLOWED_TELEGRAM_USER_ID`. Group chats and other
users are rejected before content reaches storage.

## Calendar

```sh
scripts/build_calendar_bridge.sh
uv run python app.py calendar authorize
```

Run authorization while logged into the account that owns the LaunchAgent.
Apple calls this full Calendar access. The bridge exposes status, permission,
and event queries only, and returns busy intervals without titles. Planning uses
work hours and breaks when access is unavailable.

## Manual LaunchAgent

The supported installer renders [`deploy/com.local.hob.plist`](../deploy/com.local.hob.plist).
For managed deployment, copy that template to `~/Library/LaunchAgents`, edit its
paths and settings, then load it:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.hob.plist
```

The service command is:

```sh
uv run --directory /path/to/hob python app.py
```

Keep the Telegram token in Keychain. Set `HOB_DB_PATH`, `HOB_LOG_PATH`, model,
timezone, and owner ID in the plist. Route launchd stdout and stderr to
`/dev/null`; Hob writes its own rotating application log.

## Ollama privacy

Loopback Ollama works by default. A remote endpoint requires HTTPS and:

```sh
HOB_ALLOW_REMOTE_OLLAMA=1
```

`doctor` and `status` identify remote inference. URLs containing credentials are
rejected.

## Logs

The installer creates private app data and a private `hob.log`. Hob rotates the
log at 5 MiB and retains three backups. All four generations stay owner-only.

## Recovery guarantees

- Authorized owner updates enter a durable inbox before the polling offset
  advances.
- Telegram service events and unauthorized updates advance the offset without
  content retention.
- One turn commits mutations, settings, undo history, conversational state, and
  its reply row in one transaction.
- Model failures retry the original inbox row. Send failures retry the outbox
  without repeating task changes.
- Stable keys deduplicate replies, reminders, digests, and recaps.
- Digest catch-up runs after sleep or restart when today's digest is owed.
- A local lease blocks duplicate daemons and live restore/import.

Restart from the teapot, with `scripts/hobctl restart`, or with:

```sh
launchctl kickstart -k gui/$(id -u)/com.local.hob
```

## Backup and restore

```sh
uv run --directory /path/to/hob python app.py backup /safe/hob.db
uv run --directory /path/to/hob python app.py export /safe/hob.json
uv run --directory /path/to/hob python app.py restore /safe/hob.db
uv run --directory /path/to/hob python app.py import /safe/hob.json
uv run --directory /path/to/hob python app.py status
```

Backups include committed WAL changes and receive an integrity check. Restore
and import validate the candidate, save current data, and replace the database
atomically. Hob creates database, sidecar, lock, backup, export, restore, and
log files owner-only. Opening older data tightens its permissions.

Status output contains aggregate health and queue/plan counts. It omits task
text, plan constraints, message bodies, Telegram message IDs, and secrets.
