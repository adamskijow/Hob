# SPDX-License-Identifier: MIT
"""Configuration: load from environment, validate, expose a frozen Config.

config.py sits at the edge (it reads the environment), so it is not part of the
pure core. The core receives plain values, never this module.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from adapters.keychain import get_telegram_token

_WAKE_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
_RANGE_RE = re.compile(
    r"^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$"
)
# ollama keep_alive: "-1" (forever), integer seconds ("0", "300"), or a duration
# with a unit ("30m", "2h", "1.5h"). A unit-less decimal like "1.5" is rejected
# (it passes here but ollama would reject it as a bad duration).
_KEEP_ALIVE_RE = re.compile(r"^(-?\d+|\d+(\.\d+)?[smh])$")


def _valid_timezone(value: str | None) -> str | None:
    candidate = (value or "").strip().lstrip(":")
    if not candidate or candidate.startswith("/"):
        return None
    try:
        ZoneInfo(candidate)
    except (ZoneInfoNotFoundError, ValueError):
        return None
    return candidate


def _system_timezone(
    environ: dict | None = None,
    localtime: Path = Path("/etc/localtime"),
    timezone_file: Path = Path("/etc/timezone"),
) -> str:
    """Best-effort IANA zone for a real install, with a deterministic fallback."""
    src = os.environ if environ is None else environ
    configured = _valid_timezone(src.get("TZ"))
    if configured:
        return configured
    try:
        resolved = str(localtime.resolve(strict=True))
    except OSError:
        resolved = ""
    marker = "/zoneinfo/"
    if marker in resolved:
        linked = _valid_timezone(resolved.split(marker, 1)[1])
        if linked:
            return linked
    try:
        file_value = _valid_timezone(timezone_file.read_text(encoding="utf-8"))
    except OSError:
        file_value = None
    return file_value or "UTC"


class ConfigError(Exception):
    """Raised when configuration values are missing or malformed."""


@dataclass(frozen=True)
class Config:
    telegram_token: str
    telegram_token_source: str  # environment | keychain | none
    allowed_telegram_user_id: int | None  # explicit owner; first /start pairs if unset
    model: str
    wake_time: str  # HH:MM 24h, interpreted in timezone
    timezone: str  # IANA tz key
    db_path: str
    ollama_host: str
    keep_alive: str  # how long ollama keeps the model loaded; "-1" = resident
    reminder_lead: int  # minutes before a timed item's due moment to ping
    eod_time: str  # HH:MM for the evening "what got done?" recap; "" = off
    calendar_enabled: bool
    calendar_bridge: str
    work_start: str
    work_end: str
    work_days: tuple[int, ...]
    breaks: tuple[tuple[str, str], ...]
    default_duration_minutes: int
    transition_buffer_minutes: int

    @property
    def telegram_enabled(self) -> bool:
        return bool(self.telegram_token)

    @classmethod
    def from_env(cls, env: dict | None = None) -> "Config":
        src = os.environ if env is None else env
        timezone_default = _system_timezone() if env is None else "UTC"
        environment_token = src.get("HOB_TELEGRAM_TOKEN", "").strip()
        keychain_token = (
            get_telegram_token() if env is None and not environment_token else None
        )
        telegram_token = environment_token or keychain_token or ""
        if environment_token:
            token_source = "environment"
        elif keychain_token:
            token_source = "keychain"
        else:
            token_source = "none"
        owner_raw = src.get("HOB_ALLOWED_TELEGRAM_USER_ID", "").strip()
        try:
            allowed_user = int(owner_raw) if owner_raw else None
        except ValueError as exc:
            raise ConfigError(
                "HOB_ALLOWED_TELEGRAM_USER_ID must be a positive integer"
            ) from exc
        lead_raw = src.get("HOB_REMINDER_LEAD", "10").strip()
        try:
            reminder_lead = int(lead_raw)
        except ValueError as exc:
            raise ConfigError(
                f"HOB_REMINDER_LEAD must be a whole number of minutes, got {lead_raw!r}"
            ) from exc
        cfg = cls(
            telegram_token=telegram_token,
            telegram_token_source=token_source,
            allowed_telegram_user_id=allowed_user,
            model=src.get("HOB_MODEL", "qwen2.5:7b-instruct").strip(),
            wake_time=src.get("HOB_WAKE_TIME", "07:00").strip(),
            timezone=src.get("HOB_TIMEZONE", timezone_default).strip(),
            db_path=_db_path(src, preserve_legacy=env is None),
            ollama_host=src.get("HOB_OLLAMA_HOST", "http://localhost:11434").strip(),
            keep_alive=src.get("HOB_KEEP_ALIVE", "-1").strip(),
            reminder_lead=reminder_lead,
            eod_time=src.get("HOB_EOD_TIME", "20:30").strip(),
            calendar_enabled=_boolean(src.get("HOB_CALENDAR_ENABLED", "1")),
            calendar_bridge=src.get("HOB_CALENDAR_BRIDGE", "").strip(),
            work_start=_range(src.get("HOB_WORK_HOURS", "09:00-17:30"))[0],
            work_end=_range(src.get("HOB_WORK_HOURS", "09:00-17:30"))[1],
            work_days=_work_days(
                src.get("HOB_WORK_DAYS", "mon,tue,wed,thu,fri")
            ),
            breaks=_breaks(src.get("HOB_BREAKS", "12:00-13:00")),
            default_duration_minutes=_integer(
                src.get("HOB_DEFAULT_DURATION", "30"),
                "HOB_DEFAULT_DURATION",
            ),
            transition_buffer_minutes=_integer(
                src.get("HOB_TRANSITION_BUFFER", "0"),
                "HOB_TRANSITION_BUFFER",
            ),
        )
        cfg.validate()
        return cfg

    def validate(self) -> None:
        if self.allowed_telegram_user_id is not None and self.allowed_telegram_user_id <= 0:
            raise ConfigError("HOB_ALLOWED_TELEGRAM_USER_ID must be a positive integer")
        if not _WAKE_RE.match(self.wake_time):
            raise ConfigError(
                f"HOB_WAKE_TIME must be HH:MM 24h, got {self.wake_time!r}"
            )
        try:
            ZoneInfo(self.timezone)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ConfigError(f"HOB_TIMEZONE invalid: {self.timezone!r}") from exc
        if not self.model:
            raise ConfigError("HOB_MODEL must not be empty")
        if not self.db_path:
            raise ConfigError("HOB_DB_PATH must not be empty")
        if not _KEEP_ALIVE_RE.match(self.keep_alive):
            raise ConfigError(
                f"HOB_KEEP_ALIVE must be -1, seconds, or a duration like 30m, "
                f"got {self.keep_alive!r}"
            )
        if self.reminder_lead < 0:
            raise ConfigError(
                f"HOB_REMINDER_LEAD must be 0 or more minutes, got {self.reminder_lead}"
            )
        if self.eod_time and not _WAKE_RE.match(self.eod_time):
            raise ConfigError(
                f"HOB_EOD_TIME must be HH:MM 24h (or empty to disable), "
                f"got {self.eod_time!r}"
            )
        if self.work_start >= self.work_end:
            raise ConfigError("HOB_WORK_HOURS must end after it starts")
        if not 5 <= self.default_duration_minutes <= 480:
            raise ConfigError("HOB_DEFAULT_DURATION must be between 5 and 480 minutes")
        if not 0 <= self.transition_buffer_minutes <= 120:
            raise ConfigError("HOB_TRANSITION_BUFFER must be between 0 and 120 minutes")


def _boolean(value: str) -> bool:
    low = value.strip().lower()
    if low in {"1", "true", "yes", "on"}:
        return True
    if low in {"0", "false", "no", "off"}:
        return False
    raise ConfigError("HOB_CALENDAR_ENABLED must be true or false")


def _integer(value: str, name: str) -> int:
    try:
        return int(value.strip())
    except ValueError as exc:
        raise ConfigError(f"{name} must be a whole number of minutes") from exc


def _range(value: str) -> tuple[str, str]:
    raw = value.strip()
    if not _RANGE_RE.match(raw):
        raise ConfigError(f"time range must be HH:MM-HH:MM, got {raw!r}")
    start, end = raw.split("-", 1)
    if start >= end:
        raise ConfigError(f"time range must end after it starts, got {raw!r}")
    return start, end


def _breaks(value: str) -> tuple[tuple[str, str], ...]:
    if not value.strip():
        return ()
    return tuple(_range(part) for part in value.split(","))


def _work_days(value: str) -> tuple[int, ...]:
    names = {
        "mon": 0, "monday": 0,
        "tue": 1, "tues": 1, "tuesday": 1,
        "wed": 2, "wednesday": 2,
        "thu": 3, "thur": 3, "thurs": 3, "thursday": 3,
        "fri": 4, "friday": 4,
        "sat": 5, "saturday": 5,
        "sun": 6, "sunday": 6,
    }
    parts = [part.strip().lower() for part in value.split(",") if part.strip()]
    if not parts or any(part not in names for part in parts):
        raise ConfigError(
            "HOB_WORK_DAYS must be comma-separated weekdays such as mon,tue,wed"
        )
    return tuple(sorted({names[part] for part in parts}))


def _db_path(src: dict, *, preserve_legacy: bool) -> str:
    """Prefer app data outside the checkout without abandoning legacy installs."""
    explicit = src.get("HOB_DB_PATH", "").strip()
    if explicit:
        return explicit
    legacy = Path.cwd() / "hob.db"
    if preserve_legacy and legacy.exists():
        return "hob.db"
    home = Path(src.get("HOME") or Path.home())
    return str(home / "Library" / "Application Support" / "Hob" / "hob.db")
