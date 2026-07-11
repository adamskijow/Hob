# SPDX-License-Identifier: MIT
"""Structured recurrence parsing and deterministic occurrence math."""
from __future__ import annotations

import calendar
import re
from dataclasses import replace
from datetime import date, timedelta

from core.models import RecurrenceRule

_DOW = {
    "mon": 0, "monday": 0, "tue": 1, "tuesday": 1, "wed": 2,
    "wednesday": 2, "thu": 3, "thursday": 3, "fri": 4, "friday": 4,
    "sat": 5, "saturday": 5, "sun": 6, "sunday": 6,
}
_CANON = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
_NAMES = {
    "mon": "monday", "tue": "tuesday", "wed": "wednesday",
    "thu": "thursday", "fri": "friday", "sat": "saturday", "sun": "sunday",
}


def normalize(rule: str | None) -> str | None:
    """Canonicalize the legacy model shorthand, retained as an input boundary."""
    if not rule:
        return None
    r = rule.strip().lower()
    if r in ("daily", "weekdays"):
        return r
    if r.startswith("weekly:"):
        days = [day.strip() for day in r.split(":", 1)[1].split(",")]
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


def parse(
    rule: str | RecurrenceRule | None,
    *,
    anchor: str = "fixed",
    anchor_date: str | None = None,
    end_date: str | None = None,
    count: int | None = None,
) -> RecurrenceRule | None:
    """Turn shorthand into the structured rule persisted by schema 9."""
    if isinstance(rule, RecurrenceRule):
        return rule
    legacy = normalize(rule)
    if legacy is None:
        return None
    common = {
        "anchor": anchor if anchor in ("fixed", "completion") else "fixed",
        "anchor_date": anchor_date,
        "end_date": end_date,
        "count": count if count and count > 0 else None,
    }
    if legacy == "daily":
        return RecurrenceRule(frequency="day", **common)
    if legacy == "weekdays":
        return RecurrenceRule(
            frequency="week", weekdays=_CANON[:5], **common
        )
    if legacy.startswith("weekly:"):
        return RecurrenceRule(
            frequency="week", weekdays=legacy.split(":", 1)[1].split(","), **common
        )
    if legacy.startswith("monthly:"):
        return RecurrenceRule(
            frequency="month", month_day=int(legacy.split(":", 1)[1]), **common
        )
    if legacy.startswith("yearly:"):
        month, day = map(int, legacy.split(":", 1)[1].split("-"))
        return RecurrenceRule(
            frequency="year", month=month, month_day=day, **common
        )
    _, raw_interval, frequency = legacy.split(":")
    return RecurrenceRule(
        frequency=frequency, interval=int(raw_interval), **common
    )


def to_legacy(rule: RecurrenceRule | None) -> str | None:
    """Compatibility shadow for old snapshots and older external tooling."""
    if rule is None:
        return None
    if rule.frequency == "day" and rule.interval == 1:
        return "daily"
    if rule.frequency == "week" and rule.interval == 1:
        if rule.weekdays == _CANON[:5]:
            return "weekdays"
        if rule.weekdays:
            return f"weekly:{','.join(rule.weekdays)}"
    if rule.frequency == "month" and rule.interval == 1 and rule.month_day:
        return f"monthly:{rule.month_day}"
    if (
        rule.frequency == "year"
        and rule.interval == 1
        and rule.month
        and rule.month_day
    ):
        return f"yearly:{rule.month}-{rule.month_day}"
    return f"every:{max(1, rule.interval)}:{rule.frequency}"


def describe(rule: str | RecurrenceRule | None) -> str:
    structured = parse(rule)
    if structured is None:
        return ""
    if structured.frequency == "day":
        base = "daily" if structured.interval == 1 else f"every {structured.interval} days"
    elif structured.frequency == "week" and structured.weekdays:
        days = [_NAMES[day] for day in structured.weekdays]
        base = "every " + " and ".join(days)
        if structured.weekdays == _CANON[:5]:
            base = "every weekday"
    elif structured.frequency == "week":
        base = f"every {structured.interval} week{'s' if structured.interval != 1 else ''}"
    elif structured.frequency == "month" and structured.month_day:
        base = f"monthly on day {structured.month_day}"
    elif structured.frequency == "year" and structured.month and structured.month_day:
        base = f"yearly on {structured.month}/{structured.month_day}"
    else:
        base = (
            f"every {structured.interval} {structured.frequency}"
            f"{'s' if structured.interval != 1 else ''}"
        )
    if structured.anchor == "completion":
        base += " after completion"
    if structured.end_date:
        base += f" until {structured.end_date}"
    elif structured.count:
        base += f" for {structured.count} times"
    return base


def _add_months(value: date, months: int) -> date:
    total = value.year * 12 + value.month - 1 + months
    year, month0 = divmod(total, 12)
    month = month0 + 1
    return date(year, month, min(value.day, calendar.monthrange(year, month)[1]))


def _candidate(rule: RecurrenceRule, after: date, inclusive: bool) -> date | None:
    cursor = after if inclusive else after + timedelta(days=1)
    if rule.frequency == "day":
        if rule.anchor == "fixed" and rule.anchor_date:
            value = date.fromisoformat(rule.anchor_date)
            while value < cursor:
                value += timedelta(days=max(1, rule.interval))
            return value
        return after if inclusive else after + timedelta(days=max(1, rule.interval))
    if rule.frequency == "week" and rule.weekdays:
        for offset in range(0 if inclusive else 1, 370):
            value = after + timedelta(days=offset)
            if _CANON[value.weekday()] in rule.weekdays:
                return value
        return None
    if rule.frequency == "week":
        if rule.anchor == "fixed" and rule.anchor_date:
            value = date.fromisoformat(rule.anchor_date)
            while value < cursor:
                value += timedelta(weeks=max(1, rule.interval))
            return value
        return after if inclusive else after + timedelta(weeks=max(1, rule.interval))
    if rule.frequency == "month":
        if not rule.month_day:
            if rule.anchor == "fixed" and rule.anchor_date:
                value = date.fromisoformat(rule.anchor_date)
                while value < cursor:
                    value = _add_months(value, max(1, rule.interval))
                return value
            return after if inclusive else _add_months(after, max(1, rule.interval))
        for offset in range(0, 36):
            month = _add_months(cursor.replace(day=1), offset)
            value = month.replace(
                day=min(rule.month_day, calendar.monthrange(month.year, month.month)[1])
            )
            if value >= cursor:
                return value
        return None
    if rule.frequency == "year" and rule.month and rule.month_day:
        for year in range(cursor.year, cursor.year + 5):
            value = date(
                year,
                rule.month,
                min(rule.month_day, calendar.monthrange(year, rule.month)[1]),
            )
            if value >= cursor:
                return value
        return None
    if rule.frequency == "year":
        if rule.anchor == "fixed" and rule.anchor_date:
            value = date.fromisoformat(rule.anchor_date)
            while value < cursor:
                year = value.year + max(1, rule.interval)
                value = date(
                    year,
                    value.month,
                    min(value.day, calendar.monthrange(year, value.month)[1]),
                )
            return value
        year = after.year + max(1, rule.interval)
        return date(year, after.month, min(after.day, calendar.monthrange(year, after.month)[1]))
    return None


def exhausted(rule: RecurrenceRule | None) -> bool:
    return bool(rule and rule.count is not None and rule.completed >= rule.count)


def next_due(
    rule: str | RecurrenceRule | None, after: date, inclusive: bool = False
) -> date | None:
    structured = parse(rule)
    if structured is None or exhausted(structured):
        return None
    cursor, include = after, inclusive
    for _ in range(400):
        value = _candidate(structured, cursor, include)
        if value is None:
            return None
        if structured.end_date and value > date.fromisoformat(structured.end_date):
            return None
        if value.isoformat() not in structured.exceptions:
            return value
        cursor, include = value, False
    return None


def completed(rule: RecurrenceRule) -> RecurrenceRule:
    return replace(rule, completed=rule.completed + 1)


def with_exception(rule: RecurrenceRule, occurrence: date) -> RecurrenceRule:
    exceptions = sorted(set(rule.exceptions + [occurrence.isoformat()]))
    return replace(rule, exceptions=exceptions)
