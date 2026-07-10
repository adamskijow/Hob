# SPDX-License-Identifier: MIT
"""Recurrence rule parsing and next-occurrence math."""
from datetime import date

from core.recurrence import describe, next_due, normalize


def test_normalize():
    assert normalize("daily") == "daily"
    assert normalize("WEEKDAYS") == "weekdays"
    assert normalize("weekly:monday") == "weekly:mon"
    assert normalize("weekly:TUE") == "weekly:tue"
    assert normalize("monthly") is None  # unsupported
    assert normalize(None) is None


def test_next_due_daily():
    tue = date(2026, 6, 30)
    assert next_due("daily", tue, inclusive=True) == tue
    assert next_due("daily", tue) == date(2026, 7, 1)


def test_next_due_weekly():
    tue = date(2026, 6, 30)
    assert next_due("weekly:mon", tue, inclusive=True) == date(2026, 7, 6)  # next Mon
    assert next_due("weekly:tue", tue, inclusive=True) == tue  # today is Tue
    assert next_due("weekly:tue", tue) == date(2026, 7, 7)  # strictly after


def test_next_due_weekdays_skips_weekend():
    fri = date(2026, 7, 3)
    assert next_due("weekdays", fri) == date(2026, 7, 6)  # -> Monday


def test_describe():
    assert describe("daily") == "daily"
    assert describe("weekdays") == "every weekday"
    assert describe("weekly:mon") == "every monday"


def test_multiple_weekdays_monthly_yearly_and_intervals():
    assert normalize("weekly:monday,friday") == "weekly:mon,fri"
    assert next_due("weekly:mon,fri", date(2026, 6, 29)) == date(2026, 7, 3)
    assert next_due("monthly:31", date(2026, 6, 29)) == date(2026, 6, 30)
    assert next_due("yearly:7-4", date(2026, 6, 29)) == date(2026, 7, 4)
    assert next_due("every:2:week", date(2026, 6, 29)) == date(2026, 7, 13)
    assert next_due("every:1:month", date(2026, 1, 31)) == date(2026, 2, 28)
