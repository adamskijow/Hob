# Local security hardening increment audit

Audit date: 2026-08-15
Baseline: Hob 0.9.12 plus the Telegram security increment

## Outcome

This increment closes the remaining high-value local privacy and installation
supply-chain findings from the read-only security audit.

| Criterion | Result |
| --- | --- |
| Security | Task databases and SQLite sidecars, leases, backups, exports, restore/import candidates, and installed logs are owner-only. Existing databases tighten on open. Telegram token writes use Security.framework, so the token is never placed in a child process argument. |
| User onboarding | The normal local setup remains one command and now installs `uv` through Homebrew, consumes the committed lockfile, and creates private app data. Remote inference fails with a direct explanation and the exact opt-in rather than silently transmitting prompts. |
| Customer experience | Local Ollama behavior is unchanged. An intentionally remote HTTPS setup is supported, skips irrelevant local Ollama installation, and remains visibly labeled in doctor/status. Backup/export commands and file names are unchanged. |
| Bugs | Loopback IPv4, IPv6, and `.localhost` endpoints are accepted; malformed, credential-bearing, path-bearing, remote HTTP, and non-opted-in remote endpoints are rejected. Launchd and the menu preserve the endpoint opt-in across reinstall and status checks. |
| Robustness | CI actions are pinned to immutable commits, setup uses `uv sync --locked`, CI audits the frozen runtime graph for known vulnerabilities, and Dependabot watches Python and Actions updates. Permission tests run under an intentionally permissive umask and cover database, WAL/SHM, lock, backup, restore, export, and every bounded log generation. |
| LLM differentiation | The local model remains the default semantic engine. Remote models are not prohibited, but choosing one is now an explicit privacy decision because Hob sends natural task language to it. |

## Residual risk

Homebrew packages and the configured Ollama model tag remain upstream mutable
distribution inputs. The Python environment itself is locked and CI bootstrap
actions are immutable, but a 1.0 release rehearsal should still record the
installed Homebrew formula and model digest.
