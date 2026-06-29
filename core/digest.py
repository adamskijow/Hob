# SPDX-License-Identifier: MIT
"""Digest: the pure decision of whether today's digest is owed, and (Phase 6)
the builder that turns open items plus today into an ordered digest with
rollovers.

No I/O. The "owed" decision is the heart of catch-up-on-wake: an in-process
timer does not fire while the Mac is asleep, so the scheduler re-evaluates this
predicate on startup and on every tick, firing once the time is past wake time
and today's digest has not yet gone out.
"""
from __future__ import annotations

from datetime import datetime, time

from core.models import Item


def digest_owed(
    now: datetime, wake_time: str, last_digest_date: str | None
) -> bool:
    """True if today's digest should fire now.

    Owed when the local time is at or past wake_time and today's digest has not
    already been sent. last_digest_date is the ISO date of the last sent digest
    (None if never). now is timezone-aware in the configured timezone.
    """
    hh, mm = wake_time.split(":")
    if now.time() < time(int(hh), int(mm)):
        return False
    return last_digest_date != now.date().isoformat()


def select_digest_items(open_items: list[Item], today: str) -> list[Item]:
    """Today's items plus undone rollovers, in reading order.

    Overdue first (oldest due first), then due today (earliest time first), then
    undated tasks (oldest capture first). Items due in the future are not shown.
    The returned order is exactly what gets presented and persisted, so ordinal
    references ("the third one") resolve against it.
    """
    overdue, due_today, undated = [], [], []
    for item in open_items:
        if item.due_date is None:
            undated.append(item)
        elif item.due_date < today:
            overdue.append(item)
        elif item.due_date == today:
            due_today.append(item)
        # future dates are intentionally omitted
    overdue.sort(key=lambda i: (i.due_date, i.created_at))
    due_today.sort(key=lambda i: (i.due_time or "99:99", i.created_at))
    undated.sort(key=lambda i: i.created_at)
    return overdue + due_today + undated


def render_digest(ordered: list[Item], today: str) -> str:
    """The morning message. Terse, one line per item."""
    if not ordered:
        return "morning. nothing on deck today."
    lines = ["morning. here is today:"]
    for item in ordered:
        if item.due_date and item.due_date < today:
            suffix = f" (overdue, {item.due_date})"
        elif item.due_time:
            suffix = f" ({item.due_time})"
        else:
            suffix = ""
        lines.append(f"{item.id}: {item.task}{suffix}")
    return "\n".join(lines)
