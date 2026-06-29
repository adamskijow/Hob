# SPDX-License-Identifier: MIT
import asyncio
from datetime import datetime
from zoneinfo import ZoneInfo

from adapters.scheduler import LAST_DIGEST_KEY, DigestScheduler
from adapters.store_sqlite import SqliteStore
from tests.fakes import FakeClock

TZ = ZoneInfo("America/New_York")


def at(h, m=0, day=29):
    return datetime(2026, 6, day, h, m, tzinfo=TZ)


def test_tick_fires_once_per_day():
    store = SqliteStore(":memory:")
    clock = FakeClock(at(7, 0))
    fired = []
    sched = DigestScheduler(clock, store, lambda: fired.append(1), "07:00")

    assert asyncio.run(sched.tick()) is True
    assert store.get_meta(LAST_DIGEST_KEY) == "2026-06-29"
    # second tick same day does nothing
    assert asyncio.run(sched.tick()) is False
    assert len(fired) == 1


def test_before_wake_does_not_fire():
    store = SqliteStore(":memory:")
    sched = DigestScheduler(FakeClock(at(6, 59)), store, lambda: 1 / 0, "07:00")
    assert asyncio.run(sched.tick()) is False


def test_catch_up_on_wake_fires_on_first_tick():
    # Mac asleep through 07:00, wakes at 09:30; last digest was yesterday
    store = SqliteStore(":memory:")
    store.set_meta(LAST_DIGEST_KEY, "2026-06-28")
    clock = FakeClock(at(9, 30))
    fired = []
    sched = DigestScheduler(clock, store, lambda: fired.append(1), "07:00")

    assert asyncio.run(sched.tick()) is True
    assert len(fired) == 1
    assert store.get_meta(LAST_DIGEST_KEY) == "2026-06-29"


def test_fires_again_next_day():
    store = SqliteStore(":memory:")
    store.set_meta(LAST_DIGEST_KEY, "2026-06-28")
    clock = FakeClock(at(7, 0, day=29))
    fired = []
    sched = DigestScheduler(clock, store, lambda: fired.append(1), "07:00")

    assert asyncio.run(sched.tick()) is True
    clock.set(at(7, 0, day=30))
    assert asyncio.run(sched.tick()) is True
    assert len(fired) == 2


def test_fire_returning_false_does_not_mark_the_day():
    # e.g. digest owed but no chat id yet: must not consume the day's digest.
    store = SqliteStore(":memory:")
    clock = FakeClock(at(7, 0))
    calls = []

    def fire():
        calls.append(1)
        return False if len(calls) == 1 else True

    sched = DigestScheduler(clock, store, fire, "07:00")
    assert asyncio.run(sched.tick()) is False  # not sent
    assert store.get_meta(LAST_DIGEST_KEY) is None  # day left unmarked
    # next tick retries and, now that fire succeeds, marks the day
    assert asyncio.run(sched.tick()) is True
    assert store.get_meta(LAST_DIGEST_KEY) == "2026-06-29"
    assert len(calls) == 2


def test_async_fire_callback_awaited():
    store = SqliteStore(":memory:")
    fired = []

    async def fire():
        fired.append(1)

    sched = DigestScheduler(FakeClock(at(7, 0)), store, fire, "07:00")
    assert asyncio.run(sched.tick()) is True
    assert fired == [1]
