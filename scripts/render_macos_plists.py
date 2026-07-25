#!/usr/bin/env python3
"""Render Hob's launchd plists without relying on mutable array indexes."""

from __future__ import annotations

import argparse
import plistlib
from pathlib import Path
from typing import Any


def _load(path: Path) -> dict[str, Any]:
    with path.open("rb") as source:
        return plistlib.load(source)


def _write(path: Path, payload: dict[str, Any]) -> None:
    with path.open("wb") as destination:
        plistlib.dump(payload, destination, fmt=plistlib.FMT_XML, sort_keys=False)


def render_daemon(
    *,
    template: Path,
    output: Path,
    python_path: str,
    uv_path: str,
    project_root: str,
    model: str,
    timezone: str,
    database_path: str,
    log_path: str,
    allowed_telegram_user_id: str | None,
) -> None:
    payload = _load(template)
    payload["ProgramArguments"] = [python_path, "app.py"]
    payload["WorkingDirectory"] = project_root
    payload["StandardOutPath"] = log_path
    payload["StandardErrorPath"] = log_path

    environment = payload["EnvironmentVariables"]
    environment["HOB_MODEL"] = model
    environment["HOB_TIMEZONE"] = timezone
    environment["HOB_DB_PATH"] = database_path
    environment["PATH"] = (
        f"{Path(uv_path).parent}:"
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    )
    if allowed_telegram_user_id:
        environment["HOB_ALLOWED_TELEGRAM_USER_ID"] = allowed_telegram_user_id
    else:
        environment.pop("HOB_ALLOWED_TELEGRAM_USER_ID", None)

    _write(output, payload)


def render_menu(
    *,
    template: Path,
    output: Path,
    executable_path: str,
    project_root: str,
    database_path: str,
    uv_path: str,
    log_path: str,
    model: str,
    ollama_host: str,
    timezone: str,
    menu_log_path: str,
) -> None:
    payload = _load(template)
    payload["ProgramArguments"] = [executable_path]
    payload["StandardOutPath"] = menu_log_path
    payload["StandardErrorPath"] = menu_log_path

    environment = payload["EnvironmentVariables"]
    environment["HOB_PROJECT_PATH"] = project_root
    environment["HOB_DB_PATH"] = database_path
    environment["HOB_UV_PATH"] = uv_path
    environment["HOB_LOG_PATH"] = log_path
    environment["HOB_MODEL"] = model
    environment["HOB_OLLAMA_HOST"] = ollama_host
    environment["HOB_TIMEZONE"] = timezone

    _write(output, payload)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    daemon = commands.add_parser("daemon")
    daemon.add_argument("--template", type=Path, required=True)
    daemon.add_argument("--output", type=Path, required=True)
    daemon.add_argument("--python-path", required=True)
    daemon.add_argument("--uv-path", required=True)
    daemon.add_argument("--project-root", required=True)
    daemon.add_argument("--model", required=True)
    daemon.add_argument("--timezone", required=True)
    daemon.add_argument("--database-path", required=True)
    daemon.add_argument("--log-path", required=True)
    daemon.add_argument("--allowed-telegram-user-id")

    menu = commands.add_parser("menu")
    menu.add_argument("--template", type=Path, required=True)
    menu.add_argument("--output", type=Path, required=True)
    menu.add_argument("--executable-path", required=True)
    menu.add_argument("--project-root", required=True)
    menu.add_argument("--database-path", required=True)
    menu.add_argument("--uv-path", required=True)
    menu.add_argument("--log-path", required=True)
    menu.add_argument("--model", required=True)
    menu.add_argument("--ollama-host", required=True)
    menu.add_argument("--timezone", required=True)
    menu.add_argument("--menu-log-path", required=True)
    return parser


def main() -> None:
    arguments = vars(_parser().parse_args())
    command = arguments.pop("command")
    if command == "daemon":
        render_daemon(**arguments)
    else:
        render_menu(**arguments)


if __name__ == "__main__":
    main()
