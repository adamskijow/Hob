# SPDX-License-Identifier: MIT
"""Real clock adapter. Implements core.ports.Clock.

Tests inject a fake clock instead; the core never constructs this directly.
"""
from __future__ import annotations

from datetime import date, datetime
from zoneinfo import ZoneInfo


class SystemClock:
    def __init__(self, timezone: str) -> None:
        self._tz = ZoneInfo(timezone)

    def now(self) -> datetime:
        return datetime.now(self._tz)

    def today(self) -> date:
        return self.now().date()
