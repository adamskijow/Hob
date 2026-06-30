# SPDX-License-Identifier: MIT
"""Date-intent resolution (pure calendar math), leading-date detection, and time
parsing. Seeded with a fixed today (Mon 2026-06-29)."""
from datetime import date

from core.dates import leading_date, parse_time, resolve_intent
from core.models import When

TODAY = date(2026, 6, 29)  # Monday


def r(**kw):
    return resolve_intent(When(**kw), TODAY)


def test_simple_kinds():
    assert r(kind="none").date is None
    assert r(kind="today").date == "2026-06-29"
    assert r(kind="tomorrow").date == "2026-06-30"
    assert r(kind="yesterday").date == "2026-06-28"


def test_weekday():
    assert r(kind="weekday", day="mon").date == "2026-07-06"  # next monday
    assert r(kind="weekday", day="wed").date == "2026-07-01"
    assert r(kind="weekday", which="next", day="fri").date == "2026-07-03"


def test_offset():
    assert r(kind="offset", n=2, unit="day").date == "2026-07-01"
    assert r(kind="offset", n=3, unit="day").date == "2026-07-02"
    assert r(kind="offset", n=2, unit="week").date == "2026-07-13"


def test_weekend_and_week():
    assert r(kind="weekend", which="this").date == "2026-07-04"
    assert r(kind="weekend", which="next").date == "2026-07-11"
    assert r(kind="week", which="next").date == "2026-07-06"  # next monday
    assert r(kind="week", which="next", part="mid").date == "2026-07-08"


def test_month_boundaries():
    assert r(kind="month", which="this", anchor="end").date == "2026-06-30"
    assert r(kind="month", which="next", anchor="start").date == "2026-07-01"
    assert r(kind="month", which="next", anchor="end").date == "2026-07-31"


def test_explicit_days():
    assert r(kind="ordinal_day", day_num=15).date == "2026-07-15"
    assert r(kind="month_day", month=8, day_num=3).date == "2026-08-03"
    assert r(kind="absolute", date="2026-09-01").date == "2026-09-01"


def test_ambiguous_and_none():
    res = resolve_intent(When(kind="ambiguous"), TODAY)
    assert res.ambiguous is True and res.date is None
    assert resolve_intent(None, TODAY).date is None
    assert resolve_intent(When(kind="weekday", day="bogus"), TODAY).date is None


def test_leading_date_vs_trailing():
    assert leading_date("Tomorrow I need to do A, B, and C", TODAY) == "2026-06-30"
    assert leading_date("on monday do A and B", TODAY) == "2026-07-06"
    assert leading_date("call A and email B tomorrow", TODAY) is None  # trailing
    assert leading_date("dentist friday and call mom", TODAY) is None  # not at start


def test_parse_time():
    assert parse_time("6:30") == "06:30"
    assert parse_time("8") == "08:00"
    assert parse_time("8am") == "08:00"
    assert parse_time("6:30pm") == "18:30"
    assert parse_time("noon") is None  # not a clock format we accept
    assert parse_time("25:00") is None
    assert parse_time(None) is None
