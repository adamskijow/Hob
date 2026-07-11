# SPDX-License-Identifier: MIT
"""Date resolution from a typed intent, plus leading-date detection and time
parsing. Pure, no I/O.

The model classifies a date phrase into a typed intent (core.models.When); this
module does the calendar arithmetic exactly, seeded with today. The division of
labor is deliberate: the model is good at understanding which day a phrase means
and bad at computing the date; the core is the reverse. So the model never emits
a computed date, and we never guess a phrase's meaning.

leading_date detects a date at the START of a multi-task message ("Tomorrow I
need to A, B, C") so the planner can share it; parse_time reads a clock time.
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
_DOW = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}


@dataclass
class DateResolution:
    date: str | None = None  # ISO YYYY-MM-DD
    time: str | None = None  # HH:MM 24h
    ambiguous: bool = False
    reason: str | None = None


# --- intent resolution: the model classifies the kind, we do the math --------


def _add_months(d: date, n: int) -> date:
    total = d.month - 1 + n
    year, month = d.year + total // 12, total % 12 + 1
    return date(year, month, min(d.day, calendar.monthrange(year, month)[1]))


def _last_of_month(d: date) -> date:
    return date(d.year, d.month, calendar.monthrange(d.year, d.month)[1])


def _next_dom(today: date, dom: int) -> date | None:
    """The next date on or after today whose day-of-month is dom."""
    year, month = today.year, today.month
    for _ in range(13):
        if 1 <= dom <= calendar.monthrange(year, month)[1]:
            candidate = date(year, month, dom)
            if candidate >= today:
                return candidate
        month, year = (1, year + 1) if month == 12 else (month + 1, year)
    return None


def resolve_intent(when, today: date) -> DateResolution:
    """Resolve a typed date intent (a core.models.When) to a concrete date.

    kind 'ambiguous' flags for a clarifying question; 'none', a null intent, or
    an unresolvable one yields no date. Everything else is exact arithmetic.
    """
    if when is None or when.kind in (None, "none"):
        return DateResolution()
    if when.kind == "ambiguous":
        return DateResolution(ambiguous=True, reason="more than one date")
    resolved = _resolve_kind(when, today)
    return DateResolution(date=resolved.isoformat()) if resolved else DateResolution()


def _resolve_kind(when, today: date) -> date | None:
    kind = when.kind
    if kind == "today":
        return today
    if kind == "tomorrow":
        return today + timedelta(days=1)
    if kind == "yesterday":
        return today - timedelta(days=1)
    if kind == "weekday":
        wd = _DOW.get((when.day or "")[:3].lower())
        if wd is None:
            return None
        return today + timedelta(days=((wd - today.weekday()) % 7) or 7)
    if kind == "offset":
        n = int(when.n or 0)
        unit = (when.unit or "day").lower()
        if unit.startswith("year"):
            return _add_months(today, n * 12)
        if unit.startswith("month"):
            return _add_months(today, n)
        return today + timedelta(days=(7 if unit.startswith("week") else 1) * n)
    if kind == "weekend":
        saturday = today + timedelta(days=(5 - today.weekday()) % 7)
        return saturday + timedelta(days=7) if when.which == "next" else saturday
    if kind == "week":
        monday = today - timedelta(days=today.weekday()) + timedelta(days=7)
        return monday + timedelta(days={"mid": 2, "late": 4}.get(when.part or "", 0))
    if kind == "month":
        nxt = when.which == "next"
        if (when.anchor or "end") == "start":
            return _add_months(today.replace(day=1), 1) if nxt else _next_dom(today, 1)
        return _last_of_month(_add_months(today.replace(day=1), 1) if nxt else today)
    if kind == "ordinal_day":
        return _next_dom(today, int(when.day_num)) if when.day_num else None
    if kind == "month_day":
        if not (when.month and when.day_num):
            return None
        month, day = int(when.month), int(when.day_num)
        try:
            candidate = date(today.year, month, day)
        except ValueError:
            return None
        return candidate if candidate >= today else date(today.year + 1, month, day)
    if kind == "absolute":
        try:
            return date.fromisoformat(when.date or "")
        except ValueError:
            return None
    return None  # unknown kind: treat as no date


_WEEKDAY_WORDS = {
    "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
    "friday": 4, "saturday": 5, "sunday": 6,
}


def named_day_correction(message: str, resolved_iso: str | None, today: date) -> str | None:
    """Backstop for simple day words the model sometimes drops or misfiles:
    'tomorrow' / 'yesterday' / 'today' / a weekday named in the message wins
    over a mismatched (or missing) resolved date. Skips messages naming more
    than one day (those are genuinely multi-part). None = nothing to correct."""
    low = message.lower()
    candidates = []
    if "day after tomorrow" in low:
        candidates.append(today + timedelta(days=2))
    elif re.search(r"\btomorrow\b", low):
        candidates.append(today + timedelta(days=1))
    if re.search(r"\byesterday\b", low):
        candidates.append(today - timedelta(days=1))
    if re.search(r"\b(today|tonight)\b", low):
        candidates.append(today)
    if len(candidates) > 1:
        return None
    if candidates:
        words = re.findall(r"[a-z]+", low)
        if any(w in _WEEKDAY_WORDS for w in words):
            return None  # "tomorrow or monday": ambiguous, do not pick
        iso = candidates[0].isoformat()
        return None if resolved_iso == iso else iso
    return weekday_correction(message, resolved_iso, today)


def weekday_correction(message: str, resolved_iso: str | None, today: date) -> str | None:
    """A deterministic backstop for a misclassified weekday: if the message
    names exactly one weekday and the resolved date does not fall on it (or
    there is no date at all), return the next occurrence of the named day.
    Weekday words are unambiguous; the model saying "monday" is "tomorrow" on a
    Thursday is a hallucination the core can catch. None = nothing to correct."""
    words = re.findall(r"[a-z]+", message.lower())
    named = {_WEEKDAY_WORDS[w] for w in words if w in _WEEKDAY_WORDS}
    if len(named) != 1:
        return None  # none, or several (ambiguity handled elsewhere)
    wd = named.pop()
    if resolved_iso is not None and date.fromisoformat(resolved_iso).weekday() == wd:
        return None
    return (today + timedelta(days=((wd - today.weekday()) % 7) or 7)).isoformat()


_DEADLINE_PHRASE = re.compile(
    r"\b(?:due(?:\s+by)?|deadline(?:\s+is|\s+of)?|by|before|no later than)\s+"
    r"(?P<tail>[^,;.]+)",
    re.IGNORECASE,
)


def deadline_in_text(text: str, today: date) -> str | None:
    """Resolve a literal deadline clause even when the message names a do date too.

    This is a narrow deterministic backstop for shapes like "work Friday; due
    Monday". The model identifies semantics, while dateparser only extracts the
    date from the words following an explicit deadline cue.
    """
    match = _DEADLINE_PHRASE.search(text)
    if not match:
        return None
    tail = match.group("tail").lower()
    if "end of the month" in tail or "end of month" in tail:
        return _last_of_month(today).isoformat()
    matches = search_dates(
        match.group("tail"), languages=["en"], settings=_settings(today)
    ) or []
    candidates = [value.date() for _, value in matches if value.date() >= today]
    return candidates[0].isoformat() if candidates else None


# --- time parsing ------------------------------------------------------------

_TIME_RE = re.compile(r"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b", re.IGNORECASE)


def parse_time(text: str | None) -> str | None:
    """A clock time as HH:MM 24h ('6:30', '8', '8am', '6:30pm'), or None. Used
    for the model's extracted time and for the wake-time setting."""
    if not text:
        return None
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


# --- leading-date detection for multi-task messages --------------------------

# Words that may precede a leading date without making it task-specific.
_DATE_PREFIXES = {
    "on", "by", "for", "this", "next", "the", "come", "starting", "around",
    "about", "early", "late", "mid", "middle", "of", "end", "beginning",
}


def _settings(today: date) -> dict:
    return {
        "PREFER_DATES_FROM": "future",
        "RELATIVE_BASE": datetime.combine(today, _MIDNIGHT),
        "RETURN_AS_TIMEZONE_AWARE": False,
        "STRICT_PARSING": False,
    }


def leading_date(text: str, today: date) -> str | None:
    """ISO date of a single date phrase at the START of text, else None. Lets a
    leading date be shared across a multi-task message ("Tomorrow I need to A, B,
    C") without misattributing a trailing one ("call A and email B tomorrow").
    Detection only: the shared date itself is taken from the first task's intent.
    """
    matches = search_dates(text, languages=["en"], settings=_settings(today)) or []
    floor = today - timedelta(days=366)  # ignore far-past misparses ("1130")
    matches = [(s, dt) for s, dt in matches if dt.date() >= floor]
    if not matches or len({dt.date() for _, dt in matches}) != 1:
        return None
    low = text.lower()
    earliest = min(matches, key=lambda m: low.find(m[0].lower()))
    idx = low.find(earliest[0].lower())
    if idx < 0:
        return None
    prefix = low[:idx].replace(",", " ").split()
    if all(w in _DATE_PREFIXES for w in prefix):
        return earliest[1].date().isoformat()
    return None
