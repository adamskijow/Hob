# SPDX-License-Identifier: MIT
"""Recurrence rules for repeating tasks. Pure date math, no I/O.

A recurring task is an open item with a `repeat` rule and a `due_date` that points
at its next occurrence. Completing it advances the due_date to the following
occurrence instead of closing it (see app.MessageService). Supported rules:
daily, weekdays, multiple weekly days, monthly/yearly dates, and plain intervals.
"""
from __future__ import annotations

import calendar
import re
from datetime import date, timedelta

_DOW = {
    "mon": 0, "monday": 0, "tue": 1, "tuesday": 1, "wed": 2, "wednesday": 2,
    "thu": 3, "thursday": 3, "fri": 4, "friday": 4, "sat": 5, "saturday": 5,
    "sun": 6, "sunday": 6,
}
_CANON = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
_NAMES = {
    "mon": "monday", "tue": "tuesday", "wed": "wednesday", "thu": "thursday",
    "fri": "friday", "sat": "saturday", "sun": "sunday",
}


def normalize(rule: str | None) -> str | None:
    """Canonicalize a repeat rule, or None if it is not a supported recurrence."""
    if not rule:
        return None
    r = rule.strip().lower()
    if r in ("daily", "weekdays"):
        return r
    if r.startswith("weekly:"):
        days = [d.strip() for d in r.split(":", 1)[1].split(",")]
        if days and all(day in _DOW for day in days):
            canon = sorted({_CANON[_DOW[day]] for day in days}, key=_CANON.index)
            return f"weekly:{','.join(canon)}"
    match = re.fullmatch(r"monthly:(\d{1,2})", r)
    if match and 1 <= int(match.group(1)) <= 31:
        return f"monthly:{int(match.group(1))}"
    match = re.fullmatch(r"yearly:(\d{1,2})-(\d{1,2})", r)
    if match:
        month, day = map(int, match.groups())
        if 1 <= month <= 12 and 1 <= day <= calendar.monthrange(2024, month)[1]:
            return f"yearly:{month}-{day}"
    match = re.fullmatch(r"every:(\d+):(day|week|month|year)s?", r)
    if match and int(match.group(1)) >= 1:
        return f"every:{int(match.group(1))}:{match.group(2)}"
    return None


def describe(rule: str | None) -> str:
    """A human phrase for replies: 'daily', 'every weekday', 'every monday'."""
    rule = normalize(rule)
    if rule == "daily":
        return "daily"
    if rule == "weekdays":
        return "every weekday"
    if rule and rule.startswith("weekly:"):
        days = [_NAMES[d] for d in rule.split(":", 1)[1].split(",")]
        return "every " + " and ".join(days)
    if rule and rule.startswith("monthly:"):
        return f"monthly on day {rule.split(':', 1)[1]}"
    if rule and rule.startswith("yearly:"):
        month, day = rule.split(":", 1)[1].split("-")
        return f"yearly on {int(month)}/{int(day)}"
    if rule and rule.startswith("every:"):
        _, n, unit = rule.split(":")
        return f"every {n} {unit}{'' if n == '1' else 's'}"
    return ""


def _matches(rule: str, d: date) -> bool:
    if rule == "daily":
        return True
    if rule == "weekdays":
        return d.weekday() < 5
    if rule.startswith("weekly:"):
        return _CANON[d.weekday()] in rule.split(":", 1)[1].split(",")
    return False


def _add_months(d: date, months: int) -> date:
    total = d.year * 12 + d.month - 1 + months
    year, month0 = divmod(total, 12)
    month = month0 + 1
    return date(year, month, min(d.day, calendar.monthrange(year, month)[1]))


def next_due(rule: str | None, after: date, inclusive: bool = False) -> date | None:
    """The first matching date on/after `after` (inclusive=True, for the first
    occurrence) or strictly after it (inclusive=False, to advance on completion).
    None if the rule is not a supported recurrence."""
    rule = normalize(rule)
    if rule is None:
        return None
    if rule.startswith("every:"):
        _, raw_n, unit = rule.split(":")
        n = int(raw_n)
        if inclusive:
            return after
        if unit == "day":
            return after + timedelta(days=n)
        if unit == "week":
            return after + timedelta(weeks=n)
        if unit == "month":
            return _add_months(after, n)
        return date(after.year + n, after.month, min(
            after.day, calendar.monthrange(after.year + n, after.month)[1]
        ))
    if rule.startswith("monthly:"):
        day = int(rule.split(":", 1)[1])
        cursor = after if inclusive else after + timedelta(days=1)
        for offset in range(24):
            month = _add_months(cursor.replace(day=1), offset)
            candidate = month.replace(day=min(day, calendar.monthrange(month.year, month.month)[1]))
            if candidate >= cursor:
                return candidate
        return None
    if rule.startswith("yearly:"):
        month, day = map(int, rule.split(":", 1)[1].split("-"))
        cursor = after if inclusive else after + timedelta(days=1)
        for year in range(cursor.year, cursor.year + 3):
            candidate = date(year, month, min(day, calendar.monthrange(year, month)[1]))
            if candidate >= cursor:
                return candidate
        return None
    start = after if inclusive else after + timedelta(days=1)
    for i in range(366):
        d = start + timedelta(days=i)
        if _matches(rule, d):
            return d
    return None
