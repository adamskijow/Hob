# SPDX-License-Identifier: MIT
import asyncio
from datetime import datetime
from zoneinfo import ZoneInfo

from app import DigestService, INSTALL_VERSION_KEY, RELEASE_NOTICE_KEY
from core.digest import (
    digest_nudge_item,
    digest_owed,
    priority_mark,
    render_digest,
    select_digest_items,
)
from core.models import Item
from adapters.store_sqlite import SqliteStore
from tests.fakes import FakeClock
from core.version import __version__

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
    assert "1: x (day 3)" in out  # due 06-27, today 06-29: third day on the list
    assert "2: y (09:00)" in out


def test_waiting_items_leave_the_deck_but_stay_referenceable():
    from core.digest import ordered_open

    a = item("a1", "normal one")
    b = item("a2", "parked one")
    b.waiting_since = "2026-06-27"
    assert [i.id for i in select_digest_items([a, b], "2026-06-29")] == ["a1"]
    ordered = ordered_open([a, b], "2026-06-29")
    assert [i.id for i in ordered] == ["a1", "a2"]  # waiting last, still numbered


def test_render_still_waiting_nudge():
    a = item("a1", "normal one")
    w = item("a2", "contract from jerry")
    w.waiting_since = "2026-06-25"  # 4 days by 06-29
    out = render_digest([a], "2026-06-29", waiting=[w])
    assert 'still waiting: "contract from jerry" (4d)' in out
    fresh = item("a3", "new wait")
    fresh.waiting_since = "2026-06-28"
    quiet = render_digest([a], "2026-06-29", waiting=[fresh])
    assert "still waiting" not in quiet  # under the threshold


def test_eod_service_lists_on_deck_or_skips():
    from app import EODService

    store = SqliteStore(":memory:")
    store.set_meta("chat_id", "42")
    store.add_item(item("a1", "call pool"))
    send = FakeSend()
    svc = EODService(store, FakeClock(at(20, 30)), send)
    assert asyncio.run(svc.fire()) is True
    assert "what got done today" in send.calls[0][1]
    assert "1: call pool" in send.calls[0][1]

    empty = SqliteStore(":memory:")
    empty.set_meta("chat_id", "42")
    quiet = FakeSend()
    assert asyncio.run(EODService(empty, FakeClock(at(20, 30)), quiet).fire()) is True
    assert quiet.calls == []  # nothing on deck: no message, day still marked


def test_render_stale_nudge():
    out = render_digest(
        [item("a1", "x", due="2026-06-26", created="2026-06-26T08:00:00")],
        "2026-06-29",
    )
    assert "(day 4)" in out
    assert 'has been on deck 4 days' in out  # the worst offender gets a question
    # under the threshold: marked but not nagged
    quiet = render_digest([item("a1", "x", due="2026-06-28")], "2026-06-29")
    assert "(day 2)" in quiet and "has been on deck" not in quiet


def test_undated_items_age_and_keep_resets_the_nudge():
    old = item("a1", "call pool", created="2026-06-25T08:00:00")
    out = render_digest([old], "2026-06-29")
    assert "(day 5)" in out and "reply keep" in out
    assert digest_nudge_item([old], "2026-06-29") is old

    old.updated_at = "2026-06-29T07:00:00"
    quiet = render_digest([old], "2026-06-29")
    assert "reply keep" not in quiet
    assert digest_nudge_item([old], "2026-06-29") is None


def test_digest_records_one_actionable_reply_anchor():
    class SendWithId(FakeSend):
        async def __call__(self, chat_id, text):
            await super().__call__(chat_id, text)
            return 777

    store = SqliteStore(":memory:")
    store.set_meta("chat_id", "42")
    store.add_item(item("a1", "old task", created="2026-06-25T08:00:00"))
    send = SendWithId()
    asyncio.run(DigestService(store, FakeClock(at(7, 0)), send).fire())
    assert store.ref_for(777) == "a1"


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
    assert "1: review audit (day 3)" in text
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


def test_upgraded_owner_gets_one_digest_discovery_note_but_fresh_install_does_not():
    upgraded = SqliteStore(":memory:")
    upgraded.set_meta("chat_id", "42")
    upgraded.add_item(item("a1", "real task"))
    sent = FakeSend()
    service = DigestService(upgraded, FakeClock(at(7, 0)), sent)

    asyncio.run(service.fire())
    asyncio.run(service.fire())

    assert "new in hob" in sent.calls[0][1]
    assert "new in hob" not in sent.calls[1][1]
    assert upgraded.get_meta(RELEASE_NOTICE_KEY) == __version__

    fresh = SqliteStore(":memory:")
    fresh.set_meta("chat_id", "42")
    fresh.set_meta(INSTALL_VERSION_KEY, __version__)
    fresh.set_meta(RELEASE_NOTICE_KEY, __version__)
    fresh.add_item(item("a1", "first task"))
    fresh_send = FakeSend()
    asyncio.run(DigestService(fresh, FakeClock(at(7, 0)), fresh_send).fire())
    assert "new in hob" not in fresh_send.calls[0][1]
