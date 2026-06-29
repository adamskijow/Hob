# SPDX-License-Identifier: MIT
"""Deterministic date resolution, seeded with a fixed today (Mon 2026-06-29)."""
from datetime import date

from core.dates import resolve

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
