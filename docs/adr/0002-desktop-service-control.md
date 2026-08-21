<!-- SPDX-License-Identifier: MIT -->
# ADR 0002: native desktop service control

Status: accepted for the retired Open Local edition. Native direction is in
[ADR 0003](0003-universal-apple-app.md).

## Decision

Each desktop edition provides service controls in the OS status area:

- Open Local macOS uses a menu-bar companion.
- A future Windows edition may use the system tray.
- The Store edition controls its bundled `SMAppService` helper.

| State | Meaning | Action |
| --- | --- | --- |
| Running | Service process is active | Restart |
| Off | Installed and stopped | Turn on |
| Needs setup | Service definition is missing | Finish setup |
| Unavailable | OS state lookup failed | Check again |

Health is an explicit check of database integrity, queues, pairing, and model.
Desktop controls never show task text, message content, tokens, or Calendar
titles.

## Open Local macOS

The SwiftUI companion lives in the user's Applications folder and starts at
login. It controls the fixed `com.local.hob` label through `launchctl`, opens
Hob's private log and data folder, and runs `app.py status` with installed
configuration.

The Store app has a separate sandboxed implementation and uses only its bundled
helper.

## Installation and recovery

`scripts/install_macos.sh` builds and signs the companion, preserves daemon
settings, installs both login services, rejects ambiguous databases, and starts
or restarts Hob. Re-running it updates or repairs the installation.

`scripts/hobctl` provides `status`, `on`, `restart`, `logs`, and `install` for
keyboard-only or remote use.

## Windows follow-on

Windows support requires a service installer, update path, data location,
credential store, log action, and health probe. The tray should use the states
and actions above without exposing service-manager details.
