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
    model: str
    wake_time: str  # HH:MM 24h, interpreted in timezone
    timezone: str  # IANA tz key
    db_path: str
    ollama_host: str
    keep_alive: str  # how long ollama keeps the model loaded; "-1" = resident

    @property
    def telegram_enabled(self) -> bool:
        return bool(self.telegram_token)

    @classmethod
    def from_env(cls, env: dict | None = None) -> "Config":
        src = os.environ if env is None else env
        cfg = cls(
            telegram_token=src.get("HOB_TELEGRAM_TOKEN", "").strip(),
            model=src.get("HOB_MODEL", "qwen2.5:7b-instruct").strip(),
            wake_time=src.get("HOB_WAKE_TIME", "07:00").strip(),
            timezone=src.get("HOB_TIMEZONE", "UTC").strip(),
            db_path=src.get("HOB_DB_PATH", "hob.db").strip(),
            ollama_host=src.get("HOB_OLLAMA_HOST", "http://localhost:11434").strip(),
            keep_alive=src.get("HOB_KEEP_ALIVE", "-1").strip(),
        )
        cfg.validate()
        return cfg

    def validate(self) -> None:
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
