# SPDX-License-Identifier: MIT
from datetime import datetime
from zoneinfo import ZoneInfo

from core.digest import digest_owed

TZ = ZoneInfo("America/New_York")


def at(h, m=0, day=29):
    return datetime(2026, 6, day, h, m, tzinfo=TZ)


def test_owed_after_wake_not_yet_fired():
    assert digest_owed(at(7, 0), "07:00", "2026-06-28") is True


def test_not_owed_before_wake():
    assert digest_owed(at(6, 59), "07:00", "2026-06-28") is False


def test_not_owed_if_already_fired_today():
    assert digest_owed(at(8, 0), "07:00", "2026-06-29") is False


def test_owed_catch_up_after_sleep_past_wake():
    assert digest_owed(at(9, 30), "07:00", "2026-06-28") is True


def test_owed_when_never_fired():
    assert digest_owed(at(7, 0), "07:00", None) is True


def test_exactly_at_wake_time_is_owed():
    assert digest_owed(at(7, 0), "07:00", "2026-06-28") is True
