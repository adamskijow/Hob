# SPDX-License-Identifier: MIT
"""Deterministic date resolution and ambiguity detection.

The model never does date math. The core re-resolves the raw phrasing here,
seeded with today's date (already in the configured timezone via the clock).

Findings that shape this module:
- dateparser.parse misfires on relative weekdays ("next Friday" -> None) and on
  bare ordinals ("the 3rd" -> a month). search_dates over the whole phrase is
  far more reliable, so we use it, with a dedicated handler for bare ordinal
  days that dateparser still gets wrong.
- A midnight RELATIVE_BASE keeps the base time from leaking into results, so a
  non-midnight time in a match means a time was explicitly stated.
- More than one distinct date in a single phrase means ambiguous: ask, never
  guess.
"""
from __future__ import annotations

import calendar
import re
import warnings
from dataclasses import dataclass
from datetime import date, datetime, time

# dateparser emits a pytz-related warning on some platforms; quiet it.
warnings.filterwarnings("ignore", module="dateparser")

from dateparser.search import search_dates  # noqa: E402

_MIDNIGHT = time(0, 0)
# "the 3rd", "on the 5th": a bare ordinal day of month, which dateparser
# mishandles. Requires a leading "the" so "June 3rd" still goes to dateparser.
_ORDINAL_DAY = re.compile(r"\bthe\s+(\d{1,2})(?:st|nd|rd|th)\b", re.IGNORECASE)


@dataclass
class DateResolution:
    date: str | None = None  # ISO YYYY-MM-DD
    time: str | None = None  # HH:MM 24h
    ambiguous: bool = False
    reason: str | None = None


def _settings(today: date) -> dict:
    return {
        "PREFER_DATES_FROM": "future",
        "RELATIVE_BASE": datetime.combine(today, _MIDNIGHT),
        "RETURN_AS_TIMEZONE_AWARE": False,
        "STRICT_PARSING": False,
    }


def _next_with_day(today: date, day: int) -> date | None:
    """The next date on or after today whose day-of-month is `day`."""
    year, month = today.year, today.month
    for _ in range(13):
        if day <= calendar.monthrange(year, month)[1]:
            candidate = date(year, month, day)
            if candidate >= today:
                return candidate
        month += 1
        if month > 12:
            month = 1
            year += 1
    return None


def _ordinal_day(text: str, today: date) -> date | None:
    match = _ORDINAL_DAY.search(text)
    if not match:
        return None
    day = int(match.group(1))
    if not 1 <= day <= 31:
        return None
    return _next_with_day(today, day)


def _hm(dt: datetime) -> str | None:
    return dt.strftime("%H:%M") if dt.time() != _MIDNIGHT else None


def resolve(text: str, today: date) -> DateResolution:
    """Resolve a date and optional time from natural-language phrasing."""
    matches = search_dates(text, languages=["en"], settings=_settings(today)) or []
    datetimes = [dt for _, dt in matches]

    # Bare ordinal day overrides dateparser, which misreads it as a month.
    ordinal = _ordinal_day(text, today)
    if ordinal is not None:
        explicit_time = next((_hm(dt) for dt in datetimes if _hm(dt)), None)
        return DateResolution(date=ordinal.isoformat(), time=explicit_time)

    if not datetimes:
        return DateResolution()

    distinct = {dt.date() for dt in datetimes}
    if len(distinct) > 1:
        return DateResolution(ambiguous=True, reason="more than one date")

    dt = datetimes[0]
    return DateResolution(date=dt.date().isoformat(), time=_hm(dt))
