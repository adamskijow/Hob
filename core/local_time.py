# SPDX-License-Identifier: MIT
"""Deterministic classification of local wall times around DST transitions."""
from __future__ import annotations

from datetime import date, datetime, time, timezone


def wall_datetime(day: date, value: str, tzinfo, *, fold: int = 0) -> datetime:
    """Build a local wall time without pretending every clock reading exists."""
    return datetime.combine(
        day,
        time.fromisoformat(value),
        tzinfo=tzinfo,
    ).replace(fold=fold)


def wall_time_status(value: datetime) -> str:
    """Return valid, nonexistent, or ambiguous for an aware local datetime."""
    if value.tzinfo is None:
        return "valid"
    naive = value.replace(tzinfo=None)
    roundtrip = (
        value.astimezone(timezone.utc)
        .astimezone(value.tzinfo)
        .replace(tzinfo=None)
    )
    if roundtrip != naive:
        return "nonexistent"
    first = value.replace(fold=0)
    second = value.replace(fold=1)
    if first.utcoffset() != second.utcoffset():
        return "ambiguous"
    return "valid"
