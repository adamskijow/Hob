# SPDX-License-Identifier: MIT
"""Restart recovery: no reprocessed captures, no double-fired digest."""
from datetime import datetime
from zoneinfo import ZoneInfo

from app import MessageService
from adapters.scheduler import LAST_DIGEST_KEY, DigestScheduler
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage
from core.digest import digest_owed
from tests.fakes import FakeClock, FakeLlm

TZ = ZoneInfo("America/New_York")


def msg(text, message_id):
    return InboundMessage(text=text, chat_id=1, message_id=message_id, update_id=message_id)


def capture_llm(task):
    return FakeLlm({"actions": [{"type": "capture", "task": task, "raw": task}]})


def test_redelivered_message_not_reapplied():
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, capture_llm("buy milk"), "America/New_York")

    assert svc.handle(msg("buy milk", 100)) == 'got it: "buy milk"'
    # same telegram message redelivered after a crash mid-offset-write
    assert svc.handle(msg("buy milk", 100)) == ""
    assert len(store.open_items()) == 1  # not duplicated


def test_dedupe_survives_restart(tmp_path):
    db = str(tmp_path / "hob.db")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))

    store = SqliteStore(db)
    svc = MessageService(store, clock, capture_llm("call dentist"), "America/New_York")
    svc.handle(msg("call dentist", 200))
    store.close()

    # restart: fresh store and service on the same db; message redelivered
    store2 = SqliteStore(db)
    svc2 = MessageService(store2, clock, capture_llm("call dentist"), "America/New_York")
    assert svc2.handle(msg("call dentist", 200)) == ""
    assert len(store2.open_items()) == 1
    store2.close()


def test_distinct_messages_are_not_deduped():
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, capture_llm("thing"), "America/New_York")
    svc.handle(msg("thing", 1))
    svc.handle(msg("thing", 2))
    assert len(store.open_items()) == 2


def test_digest_not_double_fired_same_day_after_restart():
    # a restart on the same day must not refire a digest already sent
    store = SqliteStore(":memory:")
    store.set_meta(LAST_DIGEST_KEY, "2026-06-29")
    assert digest_owed(datetime(2026, 6, 29, 9, 0, tzinfo=TZ), "07:00", "2026-06-29") is False

    import asyncio

    fired = []
    sched = DigestScheduler(
        FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ)), store, lambda: fired.append(1), "07:00"
    )
    assert asyncio.run(sched.tick()) is False
    assert fired == []
