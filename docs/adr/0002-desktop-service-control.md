<!-- SPDX-License-Identifier: MIT -->
# ADR 0002: native desktop service control

Status: accepted for implementation, 2026-07-25.

## Decision

Hob's background process is a product capability, not an operator detail. Each
supported desktop platform gets a small native control surface in the operating
system's persistent status area:

- the Open Local macOS edition uses a menu-bar companion;
- a future supported Windows edition uses a notification-area (system-tray)
  companion;
- the Mac App Store edition keeps its existing sandboxed menu-bar surface and
  controls only its bundled `SMAppService` helper.

Every surface uses the same user-facing states and actions:

| State | Meaning | Primary action |
| --- | --- | --- |
| Running | Background delivery is loaded and executing | Restart |
| Off | Installed but not executing | Turn on |
| Needs setup | No registered service definition exists | Finish setup |
| Unavailable | The OS could not report service state | Check again |

Health is a separate, explicit check. “Running” means the operating system has
the process; “healthy” additionally checks Hob's database, durable queues,
Telegram pairing, and local model. No task text, message content, token, or
Calendar title appears in the desktop surface.

## macOS Open Local boundary

The companion is a native SwiftUI app installed in the user's Applications
folder and launched at login by its own user LaunchAgent. It calls only
`launchctl` for the fixed `com.local.hob` label. Restart uses launchd's forced
kickstart, preserving Hob's existing durable inbox/outbox and database leases.
The companion can open the existing privacy-safe log and data folder and runs
the released `app.py status` with the database and model configuration copied
from the installed daemon.

This target is intentionally separate from the Mac App Store bundle. The Store
app remains sandboxed and never launches `launchctl`, uv, Python, or executables
outside its signed bundle.

## Installation and recovery

`scripts/install_macos.sh` builds and ad-hoc signs the companion, preserves an
existing daemon configuration, creates the durable service only when missing,
registers the menu at login, and starts or restarts Hob when a Telegram
credential exists. It refuses to choose between two databases. Re-running it is
the update/repair operation. The previous installed app and menu LaunchAgent
remain recoverable copies.

`scripts/hobctl` is a text fallback for accessibility, remote administration,
and recovery when the graphical session is unavailable. It exposes the same
`status`, `on`, `restart`, `logs`, and `install` concepts.

## Windows follow-on

This decision does not claim Windows support for 1.0. A Windows tray build must
first define and test the Windows service install/update boundary, durable data
location, credential storage, log opening, and process-health probe. It should
render the state/action contract above rather than importing launchd concepts
or running a hidden shell command parser.
