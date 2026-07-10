# SPDX-License-Identifier: MIT
"""Configuration: load from environment, validate, expose a frozen Config.

config.py sits at the edge (it reads the environment), so it is not part of the
pure core. The core receives plain values, never this module.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

_WAKE_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
# ollama keep_alive: "-1" (forever), integer seconds ("0", "300"), or a duration
# with a unit ("30m", "2h", "1.5h"). A unit-less decimal like "1.5" is rejected
# (it passes here but ollama would reject it as a bad duration).
_KEEP_ALIVE_RE = re.compile(r"^(-?\d+|\d+(\.\d+)?[smh])$")


class ConfigError(Exception):
    """Raised when configuration values are missing or malformed."""


@dataclass(frozen=True)
class Config:
    telegram_token: str
    allowed_telegram_user_id: int | None  # explicit owner; first /start pairs if unset
    model: str
    wake_time: str  # HH:MM 24h, interpreted in timezone
    timezone: str  # IANA tz key
    db_path: str
    ollama_host: str
    keep_alive: str  # how long ollama keeps the model loaded; "-1" = resident
    reminder_lead: int  # minutes before a timed item's due moment to ping
    eod_time: str  # HH:MM for the evening "what got done?" recap; "" = off

    @property
    def telegram_enabled(self) -> bool:
        return bool(self.telegram_token)

    @classmethod
    def from_env(cls, env: dict | None = None) -> "Config":
        src = os.environ if env is None else env
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
            telegram_token=src.get("HOB_TELEGRAM_TOKEN", "").strip(),
            allowed_telegram_user_id=allowed_user,
            model=src.get("HOB_MODEL", "qwen2.5:7b-instruct").strip(),
            wake_time=src.get("HOB_WAKE_TIME", "07:00").strip(),
            timezone=src.get("HOB_TIMEZONE", "UTC").strip(),
            db_path=src.get("HOB_DB_PATH", "hob.db").strip(),
            ollama_host=src.get("HOB_OLLAMA_HOST", "http://localhost:11434").strip(),
            keep_alive=src.get("HOB_KEEP_ALIVE", "-1").strip(),
            reminder_lead=reminder_lead,
            eod_time=src.get("HOB_EOD_TIME", "20:30").strip(),
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
