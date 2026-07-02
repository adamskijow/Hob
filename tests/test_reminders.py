# SPDX-License-Identifier: MIT
"""Intraday reminders: the store query and the ReminderService that pings at a
timed item's due moment."""
import asyncio
from datetime import datetime
from zoneinfo import ZoneInfo

from app import ReminderService
from adapters.store_sqlite import SqliteStore
from core.models import Item
from tests.fakes import FakeClock

TZ = ZoneInfo("America/New_York")


def item(id, task, due_date, due_time, status="open"):
    return Item(
        id=id, raw_text=task, task=task, due_date=due_date, due_time=due_time,
        status=status, source="capture", created_at="2026-06-30T08:00:00",
        updated_at="2026-06-30T08:00:00",
    )


class FakeSend:
    def __init__(self):
        self.calls = []

    async def __call__(self, chat, text):
        self.calls.append((chat, text))


def store_with(items, chat="42"):
    s = SqliteStore(":memory:")
    if chat is not None:
        s.set_meta("chat_id", chat)
    for it in items:
        s.add_item(it)
    return s


def test_due_reminders_query():
    s = store_with([
        item("a1", "call bob", "2026-06-30", "15:00"),     # due passed
        item("a2", "email sue", "2026-06-30", "17:00"),     # not yet
        item("a3", "no time", "2026-06-30", None),          # untimed -> never
        item("a4", "done one", "2026-06-30", "09:00", status="done"),  # closed
    ])
    due = s.due_reminders("2026-06-30T16:00")
    assert [i.id for i in due] == ["a1"]


def test_reminder_service_sends_and_marks_once():
    s = store_with([item("a1", "call bob", "2026-06-30", "15:00")])
    send = FakeSend()
    svc = ReminderService(s, FakeClock(datetime(2026, 6, 30, 15, 1, tzinfo=TZ)), send)

    asyncio.run(svc.check())
    assert send.calls == [(42, 'reminder: "call bob" at 15:00')]
    assert s.get_item("a1").reminded is True

    asyncio.run(svc.check())  # not re-sent
    assert len(send.calls) == 1


def test_reminder_fires_lead_minutes_early():
    s = store_with([item("a1", "standup", "2026-06-30", "15:00")])
    send = FakeSend()
    # 10-min lead: at 14:50 the 15:00 item is due for a heads-up.
    svc = ReminderService(s, FakeClock(datetime(2026, 6, 30, 14, 50, tzinfo=TZ)), send, 10)
    asyncio.run(svc.check())
    assert send.calls == [(42, 'reminder: "standup" at 15:00')]


def test_reminder_lead_not_yet_in_window():
    s = store_with([item("a1", "standup", "2026-06-30", "15:00")])
    send = FakeSend()
    # 10-min lead: at 14:49 the 15:00 item is still one minute early.
    svc = ReminderService(s, FakeClock(datetime(2026, 6, 30, 14, 49, tzinfo=TZ)), send, 10)
    asyncio.run(svc.check())
    assert send.calls == []


def test_reminder_does_nothing_without_chat():
    s = store_with([item("a1", "x", "2026-06-30", "15:00")], chat=None)
    send = FakeSend()
    asyncio.run(
        ReminderService(s, FakeClock(datetime(2026, 6, 30, 16, 0, tzinfo=TZ)), send).check()
    )
    assert send.calls == []


def test_snoozed_item_fires_at_snooze_until_not_due():
    it = item("a1", "call bob", "2026-06-30", "15:00")
    it.reminded = False
    it.snooze_until = "2026-06-30T15:20"
    s = store_with([it])
    # Past due but before snooze_until: quiet.
    assert s.due_reminders("2026-06-30T15:10", "2026-06-30T15:10") == []
    # snooze_until reached: fires.
    assert [i.id for i in s.due_reminders("2026-06-30T15:20", "2026-06-30T15:20")] == ["a1"]


def test_sent_refs_round_trip():
    s = store_with([])
    s.record_sent_ref(555, "a1")
    assert s.ref_for(555) == "a1"
    assert s.ref_for(556) is None


def test_reminder_records_ref_for_reply_anchoring():
    s = store_with([item("a1", "call bob", "2026-06-30", "15:00")])

    class SendWithId(FakeSend):
        async def __call__(self, chat, text):
            await super().__call__(chat, text)
            return 777  # telegram message id of the sent reminder

    send = SendWithId()
    svc = ReminderService(s, FakeClock(datetime(2026, 6, 30, 15, 1, tzinfo=TZ)), send)
    asyncio.run(svc.check())
    assert s.ref_for(777) == "a1"


def test_done_since():
    s = store_with([
        item("a1", "finished", "2026-06-30", None, status="done"),
        item("a2", "still open", "2026-06-30", None, status="open"),
    ])
    assert [i.id for i in s.done_since("2026-06-30")] == ["a1"]  # done only
    assert s.done_since("2026-07-01") == []  # before the window


def test_reminded_flag_survives_round_trip():
    s = store_with([item("a1", "x", "2026-06-30", "15:00")])
    it = s.get_item("a1")
    it.reminded = True
    s.update_item(it)
    assert s.get_item("a1").reminded is True
