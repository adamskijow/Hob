# SPDX-License-Identifier: MIT
"""Deterministic date resolution, seeded with a fixed today (Mon 2026-06-29)."""
from datetime import date

from core.dates import parse_time, resolve

TODAY = date(2026, 6, 29)  # Monday


def test_weekday_resolves_to_next_occurrence():
    assert resolve("Monday", TODAY).date == "2026-07-06"
    assert resolve("Wednesday", TODAY).date == "2026-07-01"


def test_next_friday():
    assert resolve("next Friday", TODAY).date == "2026-07-03"


def test_tomorrow_has_no_time():
    r = resolve("tomorrow", TODAY)
    assert r.date == "2026-06-30"
    assert r.time is None


def test_ordinal_day_of_month():
    # dateparser misreads "the 3rd" as a month; our handler fixes it.
    assert resolve("the 3rd", TODAY).date == "2026-07-03"
    assert resolve("submit the form on the 3rd", TODAY).date == "2026-07-03"


def test_bare_time_today():
    r = resolve("call at 3pm", TODAY)
    assert r.time == "15:00"
    assert r.date == "2026-06-29"


def test_explicit_date_and_time():
    r = resolve("Friday at 3pm", TODAY)
    assert r.date == "2026-07-03"
    assert r.time == "15:00"


def test_no_date_is_not_ambiguous():
    r = resolve("review the SR audit before standup", TODAY)
    assert r.date is None and r.time is None and r.ambiguous is False


def test_ambiguous_phrase_is_flagged_never_guessed():
    r = resolve("Friday or Monday", TODAY)
    assert r.ambiguous is True
    assert r.date is None


def test_phrase_inside_sentence():
    assert resolve("committed to the org prez Monday", TODAY).date == "2026-07-06"


def test_fuzzy_relative_phrases():
    assert resolve("next week", TODAY).date == "2026-07-06"  # next Monday
    assert resolve("early next week", TODAY).date == "2026-07-06"
    assert resolve("mid next week", TODAY).date == "2026-07-08"  # Wednesday
    assert resolve("this weekend", TODAY).date == "2026-07-04"  # Saturday
    assert resolve("next weekend", TODAY).date == "2026-07-11"
    assert resolve("a couple days", TODAY).date == "2026-07-01"  # +2
    assert resolve("in a few days", TODAY).date == "2026-07-02"  # +3
    assert resolve("in a couple weeks", TODAY).date == "2026-07-13"  # +14


def test_fuzzy_month_boundaries():
    assert resolve("end of the month", TODAY).date == "2026-06-30"
    assert resolve("by end of month", TODAY).date == "2026-06-30"
    assert resolve("beginning of next month", TODAY).date == "2026-07-01"
    assert resolve("end of next month", TODAY).date == "2026-07-31"


def test_fuzzy_keeps_explicit_time():
    r = resolve("this weekend at 3pm", TODAY)
    assert r.date == "2026-07-04" and r.time == "15:00"


def test_parse_time():
    assert parse_time("6:30") == "06:30"
    assert parse_time("8") == "08:00"
    assert parse_time("8am") == "08:00"
    assert parse_time("6:30pm") == "18:30"
    assert parse_time("noon") is None  # not a clock format we accept
    assert parse_time("25:00") is None
