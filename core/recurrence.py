# SPDX-License-Identifier: MIT
"""Recurrence rules for repeating tasks. Pure date math, no I/O.

A recurring task is an open item with a `repeat` rule and a `due_date` that points
at its next occurrence. Completing it advances the due_date to the following
occurrence instead of closing it (see app.MessageService). Supported rules:
"daily", "weekdays", and "weekly:<dow>" (dow = mon..sun).
"""
from __future__ import annotations

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
        day = r.split(":", 1)[1].strip()
        if day in _DOW:
            return f"weekly:{_CANON[_DOW[day]]}"
    return None


def describe(rule: str | None) -> str:
    """A human phrase for replies: 'daily', 'every weekday', 'every monday'."""
    rule = normalize(rule)
    if rule == "daily":
        return "daily"
    if rule == "weekdays":
        return "every weekday"
    if rule and rule.startswith("weekly:"):
        return f"every {_NAMES[rule.split(':', 1)[1]]}"
    return ""


def _matches(rule: str, d: date) -> bool:
    if rule == "daily":
        return True
    if rule == "weekdays":
        return d.weekday() < 5
    return d.weekday() == _CANON.index(rule.split(":", 1)[1])


def next_due(rule: str | None, after: date, inclusive: bool = False) -> date | None:
    """The first matching date on/after `after` (inclusive=True, for the first
    occurrence) or strictly after it (inclusive=False, to advance on completion).
    None if the rule is not a supported recurrence."""
    rule = normalize(rule)
    if rule is None:
        return None
    start = after if inclusive else after + timedelta(days=1)
    for i in range(366):
        d = start + timedelta(days=i)
        if _matches(rule, d):
            return d
    return None
