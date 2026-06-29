# SPDX-License-Identifier: MIT
"""Phase 4: dumb capture + /today via MessageService."""
from datetime import datetime
from zoneinfo import ZoneInfo

from app import MessageService
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage
from tests.fakes import FakeClock

TZ = ZoneInfo("America/New_York")


def msg(text):
    return InboundMessage(text=text, chat_id=1, message_id=1, update_id=1)


def service():
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    return MessageService(store, clock), store


def test_capture_stores_item_and_replies():
    svc, store = service()
    assert svc.handle(msg("call the pool guy")) == "got it"
    items = store.open_items()
    assert len(items) == 1
    assert items[0].task == "call the pool guy"
    assert items[0].raw_text == "call the pool guy"
    assert items[0].status == "open"
    assert items[0].source == "capture"


def test_today_lists_open_items():
    svc, store = service()
    svc.handle(msg("first"))
    svc.handle(msg("second"))
    out = svc.handle(msg("/today"))
    assert out == "a1: first\na2: second"


def test_today_empty():
    svc, _ = service()
    assert svc.handle(msg("/today")) == "nothing on deck"


def test_help():
    svc, _ = service()
    assert "today" in svc.handle(msg("/help")).lower()


def test_throw_tasks_all_day():
    svc, store = service()
    for t in ["a", "b", "c", "d", "e"]:
        assert svc.handle(msg(t)) == "got it"
    assert len(store.open_items()) == 5
    assert svc.handle(msg("/today")).count("\n") == 4
