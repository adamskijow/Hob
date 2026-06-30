# SPDX-License-Identifier: MIT
"""MessageService integration: commands plus interpreter-routed capture."""
import itertools
from datetime import datetime
from zoneinfo import ZoneInfo

from app import MessageService
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage
from tests.fakes import FakeClock, FakeLlm

TZ = ZoneInfo("America/New_York")
_ids = itertools.count(1)


def msg(text):
    # each call gets a fresh message id, as real Telegram messages do
    mid = next(_ids)
    return InboundMessage(text=text, chat_id=1, message_id=mid, update_id=mid)


def capture_json(task, raw=None, due=None):
    return {"actions": [{"type": "capture", "task": task, "raw": raw or task, "due": due}]}


def service(llm=None):
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    llm = llm or FakeLlm(capture_json("x"))
    return MessageService(store, clock, llm, "America/New_York"), store


def test_capture_stores_item_and_replies():
    svc, store = service(FakeLlm(capture_json("call the pool guy")))
    assert svc.handle(msg("call the pool guy")) == 'got it: "call the pool guy"'
    items = store.open_items()
    assert len(items) == 1
    assert items[0].task == "call the pool guy"
    assert items[0].status == "open"
    assert items[0].source == "capture"


def test_capture_with_date_end_to_end():
    svc, store = service(FakeLlm(capture_json("org prez", "org prez Monday", "2026-07-06")))
    assert svc.handle(msg("committed to the org prez Monday")) == 'got it: "org prez" for 2026-07-06'
    item = store.open_items()[0]
    assert item.task == "org prez"
    assert item.due_date == "2026-07-06"


def test_ambiguous_date_asks_and_stores_nothing():
    svc, store = service(FakeLlm(capture_json("thing", "Friday or Monday")))
    out = svc.handle(msg("thing Friday or Monday"))
    assert "when" in out.lower()
    assert store.open_items() == []


def test_today_lists_open_items():
    svc, store = service(FakeLlm([capture_json("first"), capture_json("second")]))
    svc.handle(msg("first"))
    svc.handle(msg("second"))
    assert svc.handle(msg("/today")) == "a1: first\na2: second"


def test_today_empty():
    svc, _ = service()
    assert svc.handle(msg("/today")) == "nothing on deck"


def test_help():
    svc, _ = service()
    assert "today" in svc.handle(msg("/help")).lower()


def test_throw_tasks_all_day():
    svc, store = service(FakeLlm(capture_json("t")))
    for _ in range(5):
        assert svc.handle(msg("a task")) == 'got it: "t"'
    assert len(store.open_items()) == 5
    assert svc.handle(msg("/today")).count("\n") == 4
