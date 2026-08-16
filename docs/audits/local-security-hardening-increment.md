<!-- SPDX-License-Identifier: MIT -->
# Local security hardening audit

Date: 2026-08-15. Baseline: v0.9.12 plus Telegram hardening.

## Result

- Database, SQLite sidecars, locks, backup/export/recovery files, and logs are
  owner-only. Older databases tighten on open.
- Keychain writes use Security.framework and keep the token out of child
  process arguments.
- Remote Ollama requires HTTPS and explicit opt-in. Health identifies remote
  inference.
- Endpoint validation rejects credentials, paths, malformed URLs, remote HTTP,
  and remote hosts without consent. Loopback IPv4, IPv6, and `.localhost` work.
- Setup uses the committed lockfile. CI actions are pinned. CI audits frozen
  dependencies. Dependabot watches Python and Actions.
- Permission tests cover permissive umask, WAL/SHM, locks, backup, restore,
  export, and all log generations.

## Residual risk

Homebrew packages and Ollama tags are mutable upstream inputs. Release evidence
should record installed formula versions and the model digest.
