# SPDX-License-Identifier: MIT
"""Reversible, secret-free macOS LaunchAgent installation for Hob."""
from __future__ import annotations

import os
import plistlib
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from config import Config

LABEL = "com.local.hob"
PLIST_NAME = f"{LABEL}.plist"
Run = Callable[..., subprocess.CompletedProcess]


class LaunchdError(RuntimeError):
    pass


@dataclass(frozen=True)
class LaunchdPaths:
    plist: Path
    previous_plist: Path
    uninstalled_plist: Path
    data_dir: Path
    log_path: Path


@dataclass(frozen=True)
class InstalledDefinition:
    checkout: str
    database: str
    model: str
    contains_token: bool


def service_paths(home: Path) -> LaunchdPaths:
    agents = home / "Library" / "LaunchAgents"
    data = home / "Library" / "Application Support" / "Hob"
    plist = agents / PLIST_NAME
    return LaunchdPaths(
        plist=plist,
        previous_plist=agents / f"{PLIST_NAME}.previous",
        uninstalled_plist=agents / f"{PLIST_NAME}.uninstalled",
        data_dir=data,
        log_path=data / "hob.log",
    )


def launch_agent_payload(
    cfg: Config,
    *,
    root: Path,
    uv_path: Path,
    home: Path,
    environ: dict[str, str] | None = None,
) -> dict:
    """Build the exact plist without ever copying the Telegram credential."""
    env = os.environ if environ is None else environ
    paths = service_paths(home)
    runtime = {
        "HOB_MODEL": cfg.model,
        "HOB_WAKE_TIME": cfg.wake_time,
        "HOB_DB_PATH": str(Path(cfg.db_path).expanduser().resolve()),
        "HOB_OLLAMA_HOST": cfg.ollama_host,
        "HOB_KEEP_ALIVE": cfg.keep_alive,
        "HOB_REMINDER_LEAD": str(cfg.reminder_lead),
        "HOB_EOD_TIME": cfg.eod_time,
        "HOB_CALENDAR_ENABLED": "true" if cfg.calendar_enabled else "false",
        "HOB_WORK_HOURS": f"{cfg.work_start}-{cfg.work_end}",
        "HOB_WORK_DAYS": ",".join(
            ("mon", "tue", "wed", "thu", "fri", "sat", "sun")[day]
            for day in cfg.work_days
        ),
        "HOB_BREAKS": ",".join(f"{start}-{end}" for start, end in cfg.breaks),
        "HOB_DEFAULT_DURATION": str(cfg.default_duration_minutes),
        "HOB_TRANSITION_BUFFER": str(cfg.transition_buffer_minutes),
        "PATH": ":".join(dict.fromkeys((
            str(uv_path.parent),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ))),
    }
    if cfg.allowed_telegram_user_id is not None:
        runtime["HOB_ALLOWED_TELEGRAM_USER_ID"] = str(
            cfg.allowed_telegram_user_id
        )
    explicit_timezone = env.get("HOB_TIMEZONE", "").strip()
    if explicit_timezone:
        runtime["HOB_TIMEZONE"] = explicit_timezone
    if cfg.calendar_bridge:
        runtime["HOB_CALENDAR_BRIDGE"] = cfg.calendar_bridge
    return {
        "Label": LABEL,
        "ProgramArguments": [
            str(uv_path),
            "run",
            "--frozen",
            "--no-sync",
            "--directory",
            str(root),
            "python",
            "app.py",
        ],
        "WorkingDirectory": str(root),
        "EnvironmentVariables": runtime,
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 30,
        "ProcessType": "Background",
        "StandardOutPath": str(paths.log_path),
        "StandardErrorPath": str(paths.log_path),
    }


def installed_definition(paths: LaunchdPaths) -> InstalledDefinition | None:
    if not paths.plist.exists():
        return None
    try:
        payload = plistlib.loads(paths.plist.read_bytes())
    except (OSError, plistlib.InvalidFileException):
        raise LaunchdError(f"invalid installed plist: {paths.plist}") from None
    environment = payload.get("EnvironmentVariables")
    environment = environment if isinstance(environment, dict) else {}
    return InstalledDefinition(
        checkout=str(payload.get("WorkingDirectory") or "unknown"),
        database=str(environment.get("HOB_DB_PATH") or "unknown"),
        model=str(environment.get("HOB_MODEL") or "unknown"),
        contains_token="HOB_TELEGRAM_TOKEN" in environment,
    )


def _checked(run: Run, argv: list[str], *, allow_unloaded: bool = False):
    result = run(argv, capture_output=True, text=True, check=False)
    if result.returncode and not allow_unloaded:
        detail = (result.stderr or result.stdout or "command failed").strip()
        raise LaunchdError(detail)
    return result


def install_launch_agent(
    payload: dict,
    paths: LaunchdPaths,
    *,
    uid: int,
    before_replace: Callable[[], None] | None = None,
    run: Run = subprocess.run,
) -> bool:
    """Install/update atomically and restore the prior agent on bootstrap failure."""
    paths.plist.parent.mkdir(parents=True, exist_ok=True)
    paths.data_dir.mkdir(parents=True, exist_ok=True)
    temporary = paths.plist.with_name(f".{paths.plist.name}.new")
    temporary.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML))
    try:
        _checked(run, ["/usr/bin/plutil", "-lint", str(temporary)])
        prior = paths.plist.read_bytes() if paths.plist.exists() else None
        domain = f"gui/{uid}"
        was_loaded, _ = service_status(uid=uid, run=run)
        if was_loaded:
            _checked(
                run,
                ["/bin/launchctl", "bootout", domain, str(paths.plist)],
            )
        try:
            if before_replace is not None:
                before_replace()
        except Exception:
            if was_loaded and prior is not None:
                _checked(
                    run,
                    ["/bin/launchctl", "bootstrap", domain, str(paths.plist)],
                )
            raise
        os.replace(temporary, paths.plist)
        try:
            _checked(
                run,
                ["/bin/launchctl", "bootstrap", domain, str(paths.plist)],
            )
        except LaunchdError:
            if prior is None:
                paths.plist.unlink(missing_ok=True)
            else:
                paths.plist.write_bytes(prior)
            if was_loaded and prior is not None:
                _checked(
                    run,
                    ["/bin/launchctl", "bootstrap", domain, str(paths.plist)],
                )
            raise
        if prior is not None:
            paths.previous_plist.write_bytes(prior)
        paths.uninstalled_plist.unlink(missing_ok=True)
        return prior is not None
    finally:
        temporary.unlink(missing_ok=True)


def service_status(*, uid: int, run: Run = subprocess.run) -> tuple[bool, str]:
    result = run(
        ["/bin/launchctl", "print", f"gui/{uid}/{LABEL}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        return False, "not loaded"
    fields = {}
    for raw in result.stdout.splitlines():
        line = raw.strip()
        for key in ("state", "pid", "last exit code"):
            if line.startswith(f"{key} ="):
                fields.setdefault(key, line)
    detail = "; ".join(
        fields[key] for key in ("state", "pid", "last exit code") if key in fields
    )
    return True, detail or "loaded"


def restart_service(*, uid: int, run: Run = subprocess.run) -> None:
    _checked(run, ["/bin/launchctl", "kickstart", "-k", f"gui/{uid}/{LABEL}"])


def uninstall_launch_agent(
    paths: LaunchdPaths, *, uid: int, run: Run = subprocess.run
) -> bool:
    loaded, _ = service_status(uid=uid, run=run)
    if loaded:
        _checked(
            run,
            ["/bin/launchctl", "bootout", f"gui/{uid}", str(paths.plist)],
        )
    if not paths.plist.exists():
        return False
    os.replace(paths.plist, paths.uninstalled_plist)
    return True
