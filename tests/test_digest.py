# SPDX-License-Identifier: MIT
import asyncio
from datetime import datetime
from zoneinfo import ZoneInfo

from app import DigestService
from core.digest import digest_owed, priority_mark, render_digest, select_digest_items
from core.models import Item
from adapters.store_sqlite import SqliteStore
from tests.fakes import FakeClock

TZ = ZoneInfo("America/New_York")


def at(h, m=0, day=29):
    return datetime(2026, 6, day, h, m, tzinfo=TZ)


def item(id, task, due=None, time=None, created="2026-06-29T08:00:00", priority="normal"):
    return Item(
        id=id,
        raw_text=task,
        task=task,
        due_date=due,
        due_time=time,
        status="open",
        source="capture",
        created_at=created,
        updated_at=created,
        priority=priority,
    )


def test_priority_floats_up_and_sinks():
    # date order is a1, a2, a3; priority re-ranks: high first, low last.
    items = [
        item("a1", "normal one"),
        item("a2", "urgent one", priority="high"),
        item("a3", "someday one", priority="low"),
    ]
    ordered = select_digest_items(items, "2026-06-29")
    assert [i.id for i in ordered] == ["a2", "a1", "a3"]


def test_priority_marks_render():
    out = render_digest(
        [item("a1", "urgent one", priority="high"), item("a2", "someday one", priority="low")],
        "2026-06-29",
    )
    assert "urgent one (!)" in out and "someday one (low)" in out
    assert priority_mark(item("a3", "plain")) == ""


class FakeSend:
    def __init__(self):
        self.calls = []

    async def __call__(self, chat_id, text):
        self.calls.append((chat_id, text))


def test_owed_after_wake_not_yet_fired():
    assert digest_owed(at(7, 0), "07:00", "2026-06-28") is True


def test_not_owed_before_wake():
    assert digest_owed(at(6, 59), "07:00", "2026-06-28") is False


def test_not_owed_if_already_fired_today():
    assert digest_owed(at(8, 0), "07:00", "2026-06-29") is False


def test_owed_catch_up_after_sleep_past_wake():
    # Mac asleep at 07:00, wakes at 09:30; yesterday's digest was the last one
    assert digest_owed(at(9, 30), "07:00", "2026-06-28") is True


def test_owed_when_never_fired():
    assert digest_owed(at(7, 0), "07:00", None) is True


def test_exactly_at_wake_time_is_owed():
    assert digest_owed(at(7, 0), "07:00", "2026-06-28") is True


# Phase 6: digest selection, rendering, delivery -------------------------------


def test_select_excludes_future_and_orders():
    items = [
        item("a1", "review audit", due="2026-06-27"),  # overdue
        item("a2", "org prez", due="2026-06-29"),  # today
        item("a3", "call pool"),  # undated
        item("a4", "future thing", due="2026-07-15"),  # future, excluded
    ]
    ordered = select_digest_items(items, "2026-06-29")
    assert [i.id for i in ordered] == ["a1", "a2", "a3"]


def test_select_orders_overdue_oldest_first():
    items = [
        item("a1", "newer", due="2026-06-28"),
        item("a2", "older", due="2026-06-20"),
    ]
    ordered = select_digest_items(items, "2026-06-29")
    assert [i.id for i in ordered] == ["a2", "a1"]


def test_render_empty():
    assert render_digest([], "2026-06-29") == "morning. nothing on deck today."


def test_render_markers():
    ordered = [
        item("a1", "x", due="2026-06-27"),
        item("a2", "y", due="2026-06-29", time="09:00"),
    ]
    out = render_digest(ordered, "2026-06-29")
    assert "1: x (overdue, 2026-06-27)" in out
    assert "2: y (09:00)" in out


def test_digest_service_sends_and_persists_order():
    store = SqliteStore(":memory:")
    store.set_meta("chat_id", "42")
    for it in [
        item("a1", "review audit", due="2026-06-27", created="2026-06-27T08:00:00"),
        item("a2", "org prez", due="2026-06-29", created="2026-06-29T07:00:00"),
        item("a3", "call pool", created="2026-06-28T07:00:00"),
        item("a4", "future thing", due="2026-07-15", created="2026-06-29T07:00:00"),
    ]:
        store.add_item(it)
    send = FakeSend()
    svc = DigestService(store, FakeClock(at(7, 0)), send)

    assert asyncio.run(svc.fire()) is True

    assert len(send.calls) == 1
    chat, text = send.calls[0]
    assert chat == 42
    assert "1: review audit (overdue, 2026-06-27)" in text
    assert "future thing" not in text
    # persisted in presented order, so ordinals resolve later
    assert [d.id for d in store.last_digest().items] == ["a1", "a2", "a3"]


def test_digest_service_no_chat_id_does_not_send_or_persist():
    store = SqliteStore(":memory:")
    store.add_item(item("a1", "x"))
    send = FakeSend()
    svc = DigestService(store, FakeClock(at(7, 0)), send)

    assert asyncio.run(svc.fire()) is False  # signals "not sent" to the scheduler

    assert send.calls == []
    assert store.last_digest() is None
