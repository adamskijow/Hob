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

from datetime import date, datetime, time

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
    on_deck = overdue + due_today + undated
    # Priority floats up (high) or sinks (low). A stable sort keeps the date
    # order above within each tier, so "urgent" rises without scrambling the day.
    on_deck.sort(key=lambda i: _PRIORITY_RANK.get(i.priority, 1))
    return on_deck


_PRIORITY_RANK = {"high": 0, "normal": 1, "low": 2}


def priority_mark(item: Item) -> str:
    """A terse marker so urgency is visible in any list view. Normal is unmarked."""
    if item.priority == "high":
        return " (!)"
    if item.priority == "low":
        return " (low)"
    return ""


def marks(item: Item) -> str:
    """All the inline badges for a list line: priority, then tag."""
    tag = f" [{item.tag}]" if item.tag else ""
    return priority_mark(item) + tag


def ordered_open(items: list[Item], today: str) -> list[Item]:
    """All open items in one canonical reading order: on-deck (overdue, due today,
    undated) first, then future-dated. Positions are numbered over this so every
    view and the morning digest agree on what "2" refers to."""
    on_deck = select_digest_items(items, today)
    seen = {i.id for i in on_deck}
    future = sorted(
        (i for i in items if i.id not in seen),
        key=lambda i: (i.due_date or "", i.created_at),
    )
    return on_deck + future


STALE_DAYS = 3  # rolled over this many days -> worth asking about


def _days_over(item: Item, today: str) -> int:
    """How many days this item has rolled past its due date (0 = not overdue)."""
    if not item.due_date or item.due_date >= today:
        return 0
    return (date.fromisoformat(today) - date.fromisoformat(item.due_date)).days


def render_digest(ordered: list[Item], today: str) -> str:
    """The morning message. Terse, one line per item. An item that keeps rolling
    over is marked with its day count, and the worst repeat offender gets one
    gentle question at the end so the list does not silently rot."""
    if not ordered:
        return "morning. nothing on deck today."
    lines = ["morning. here is today:"]
    for n, item in enumerate(ordered, start=1):
        over = _days_over(item, today)
        if over:
            suffix = f" (day {over + 1})"
        elif item.due_time:
            suffix = f" ({item.due_time})"
        else:
            suffix = ""
        lines.append(f"{n}: {item.task}{suffix}{marks(item)}")
    stale = max(ordered, key=lambda i: _days_over(i, today))
    worst = _days_over(stale, today)
    if worst >= STALE_DAYS:
        lines.append(
            f'"{stale.task}" has rolled over {worst + 1} days now. '
            "still on, or should i push or drop it?"
        )
    return "\n".join(lines)
