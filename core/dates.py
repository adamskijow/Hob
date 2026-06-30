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
from datetime import date, datetime, time, timedelta

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


def _last_of_month(year: int, month: int) -> date:
    return date(year, month, calendar.monthrange(year, month)[1])


def _next_month(today: date) -> tuple[int, int]:
    month = today.month % 12 + 1
    year = today.year + (1 if today.month == 12 else 0)
    return year, month


def _this_saturday(today: date) -> date:
    return today + timedelta(days=(5 - today.weekday()) % 7)  # Sat=5


def _next_monday(today: date) -> date:
    return today - timedelta(days=today.weekday()) + timedelta(days=7)


# "a couple of days", "few weeks": vague spans dateparser does not handle.
_COUPLE_FEW = re.compile(r"\b(?:a\s+)?(couple|few)(?:\s+of)?\s+(days?|weeks?)\b", re.I)


def _fuzzy(text: str, today: date) -> date | None:
    """Relative phrases dateparser gets wrong or returns nothing for. The model
    copies these words verbatim; we own the math here, with simple conventions:
    weekend -> upcoming Saturday, next week -> next Monday, month/week ends ->
    the last/first day, "a couple/few days" -> +2/+3."""
    t = text.lower()

    m = _COUPLE_FEW.search(t)
    if m:
        n = 2 if m.group(1) == "couple" else 3
        per = 7 if m.group(2).startswith("week") else 1
        return today + timedelta(days=n * per)

    if re.search(r"\bnext\s+weekend\b", t):
        return _this_saturday(today) + timedelta(days=7)
    if re.search(r"\bweekend\b", t):
        return _this_saturday(today)

    if re.search(r"\bnext\s+month\b", t):
        year, month = _next_month(today)
        if re.search(r"\b(end|last)\b", t):
            return _last_of_month(year, month)
        return date(year, month, 1)  # beginning / first / bare "next month"

    if re.search(r"\b(end|last day)\s+of\s+(?:the\s+|this\s+)?month\b", t) or re.search(
        r"\bmonth['’]?s?\s+end\b", t
    ):
        return _last_of_month(today.year, today.month)
    if re.search(r"\b(start|beginning|first)\s+of\s+(?:the\s+|this\s+)?month\b", t):
        return _next_with_day(today, 1)

    if re.search(r"\bnext\s+week\b", t):
        monday = _next_monday(today)
        if re.search(r"\b(mid|middle)\b", t):
            return monday + timedelta(days=2)  # Wednesday
        if re.search(r"\b(late|end)\b", t):
            return monday + timedelta(days=4)  # Friday
        return monday  # bare or "early next week"
    if re.search(r"\b(end|rest)\s+of\s+(?:the\s+|this\s+)?week\b", t):
        return today - timedelta(days=today.weekday()) + timedelta(days=4)  # this Fri

    return None


_TIME_RE = re.compile(r"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b", re.IGNORECASE)


def parse_time(text: str) -> str | None:
    """A bare clock time as HH:MM 24h, for settings like the wake time. Handles
    '6:30', '8', '8am', '6:30pm'. Returns None if no sensible time is present."""
    m = _TIME_RE.search(text)
    if not m:
        return None
    hour, minute = int(m.group(1)), int(m.group(2) or 0)
    ampm = (m.group(3) or "").lower()
    if ampm == "pm" and hour != 12:
        hour += 12
    elif ampm == "am" and hour == 12:
        hour = 0
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return None
    return f"{hour:02d}:{minute:02d}"


def leading_date(text: str, today: date) -> str | None:
    """ISO date of a single date phrase at the START of text, else None. Lets a
    leading date be shared across a multi-task message ("Tomorrow I need to A, B,
    C") without misattributing a trailing one ("call A and email B tomorrow")."""
    matches = search_dates(text, languages=["en"], settings=_settings(today)) or []
    floor = today - timedelta(days=366)
    matches = [(s, dt) for s, dt in matches if dt.date() >= floor]
    if not matches or len({dt.date() for _, dt in matches}) != 1:
        return None  # nothing, or more than one distinct date: do not share
    low = text.lower()
    earliest = min(matches, key=lambda m: low.find(m[0].lower()))
    idx = low.find(earliest[0].lower())
    if idx < 0:
        return None
    # Leading means only date-prefixing stopwords sit before it ("on monday ...",
    # "tomorrow ..."), not a task word ("dentist friday ..." is dentist's date).
    prefix = low[:idx].replace(",", " ").split()
    if all(w in _DATE_PREFIXES for w in prefix):
        return earliest[1].date().isoformat()
    return None


# Words that may precede a leading date without making it task-specific.
_DATE_PREFIXES = {
    "on", "by", "for", "this", "next", "the", "come", "starting", "around",
    "about", "early", "late", "mid", "middle", "of", "end", "beginning",
}


def resolve(text: str, today: date) -> DateResolution:
    """Resolve a date and optional time from natural-language phrasing."""
    matches = search_dates(text, languages=["en"], settings=_settings(today)) or []
    datetimes = [dt for _, dt in matches]
    # Drop implausible far-past parses. dateparser reads a bare number like "1130"
    # ("my 1130 meeting", an 11:30 time) as the year 1130. We prefer future dates,
    # so anything well before today is a misparse, not an intent: ignore it rather
    # than schedule a task centuries ago.
    floor = today - timedelta(days=366)
    datetimes = [dt for dt in datetimes if dt.date() >= floor]
    explicit_time = next((_hm(dt) for dt in datetimes if _hm(dt)), None)

    # Bare ordinal day overrides dateparser, which misreads it as a month.
    ordinal = _ordinal_day(text, today)
    if ordinal is not None:
        return DateResolution(date=ordinal.isoformat(), time=explicit_time)

    # Fuzzy relative phrases ("this weekend", "end of the month") own the math;
    # they override dateparser, which returns nothing or the wrong day for them.
    fuzzy = _fuzzy(text, today)
    if fuzzy is not None:
        return DateResolution(date=fuzzy.isoformat(), time=explicit_time)

    if not datetimes:
        return DateResolution()

    distinct = {dt.date() for dt in datetimes}
    if len(distinct) > 1:
        return DateResolution(ambiguous=True, reason="more than one date")

    dt = datetimes[0]
    return DateResolution(date=dt.date().isoformat(), time=_hm(dt))
