# SPDX-License-Identifier: MIT
"""MessageService integration: commands plus interpreter-routed capture."""
import itertools
from datetime import datetime
from zoneinfo import ZoneInfo

from app import MessageService
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage
from core.models import Item
from tests.fakes import FakeClock, FakeLlm

TZ = ZoneInfo("America/New_York")
_ids = itertools.count(1)


def msg(text):
    # each call gets a fresh message id, as real Telegram messages do
    mid = next(_ids)
    return InboundMessage(text=text, chat_id=1, message_id=mid, update_id=mid)


def capture_json(task, raw=None, when=None, time=None):
    action = {"type": "capture", "task": task, "raw": raw or task}
    if when is not None:
        action["when"] = when
    if time is not None:
        action["time"] = time
    return {"actions": [action]}


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
    svc, store = service(FakeLlm(
        capture_json("org prez", "org prez Monday", when={"kind": "weekday", "day": "mon"})
    ))
    assert svc.handle(msg("committed to the org prez Monday")) == 'got it: "org prez" for 2026-07-06 (in 7 days)'
    item = store.open_items()[0]
    assert item.task == "org prez"
    assert item.due_date == "2026-07-06"


def test_ambiguous_date_asks_and_stores_nothing():
    svc, store = service(FakeLlm(capture_json("thing", "Friday or Monday", when={"kind": "ambiguous"})))
    out = svc.handle(msg("thing Friday or Monday"))
    assert "when" in out.lower()
    assert store.open_items() == []


def test_today_lists_open_items():
    svc, store = service(FakeLlm([capture_json("first"), capture_json("second")]))
    svc.handle(msg("first"))
    svc.handle(msg("second"))
    assert svc.handle(msg("/today")) == "1: first\n2: second"


def test_today_empty():
    svc, _ = service()
    assert svc.handle(msg("/today")) == "nothing on deck"


def test_today_excludes_future_while_list_includes_it():
    svc, store = service()
    store.add_item(
        Item(
            id="a1",
            raw_text="future",
            task="future",
            due_date="2026-07-15",
            due_time=None,
            status="open",
            source="capture",
            created_at="2026-06-29T08:00:00",
            updated_at="2026-06-29T08:00:00",
        )
    )
    assert svc.handle(msg("/today")) == "nothing on deck"
    assert "future" in svc.handle(msg("/list"))


def test_help():
    svc, _ = service()
    assert "today" in svc.handle(msg("/help")).lower()


def test_start_welcomes_distinct_from_help():
    svc, _ = service()
    welcome = svc.handle(msg("/start"))
    assert "hob" in welcome.lower() and "digest" in welcome.lower()
    assert "07:00" in welcome  # mentions the wake time
    assert welcome != svc.handle(msg("/help"))


def test_model_ready_matching():
    from app import _model_ready

    class Llm:
        def installed_models(self):
            return ["qwen2.5:14b-instruct", "llama3.2:1b"]

    assert _model_ready(Llm(), "qwen2.5:14b-instruct")
    assert not _model_ready(Llm(), "qwen2.5:7b-instruct")


def test_relative_phrasing():
    from datetime import date
    from app import _relative
    t = date(2026, 6, 29)
    assert _relative("2026-06-29", t) == "today"
    assert _relative("2026-06-30", t) == "tomorrow"
    assert _relative("2026-07-03", t) == "in 4 days"
    assert _relative("2226-06-29", t) == "in 200 years"
    assert _relative("2026-06-28", t) == "yesterday"


def test_throw_tasks_all_day():
    svc, store = service(FakeLlm(capture_json("t")))
    for _ in range(5):
        assert svc.handle(msg("a task")) == 'got it: "t"'
    assert len(store.open_items()) == 5
    assert svc.handle(msg("/today")).count("\n") == 4
