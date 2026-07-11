# SPDX-License-Identifier: MIT
from datetime import datetime
from zoneinfo import ZoneInfo

from core.feasibility import BusyPeriod, CalendarSnapshot, PlanPreferences
from core.forecast import build_week_forecast
from core.models import Item, PlanSession

TZ = ZoneInfo("America/New_York")
NOW = datetime(2026, 7, 13, 9, 0, tzinfo=TZ)  # Monday


def item(item_id: str, task: str, **changes) -> Item:
    values = {
        "id": item_id,
        "raw_text": task,
        "task": task,
        "due_date": None,
        "due_time": None,
        "status": "open",
        "source": "capture",
        "created_at": "2026-07-13T08:00:00-04:00",
        "updated_at": "2026-07-13T08:00:00-04:00",
    }
    values.update(changes)
    return Item(**values)


def snapshots(now=NOW, days=7):
    return {
        now.date().fromordinal(now.date().toordinal() + offset).isoformat():
        CalendarSnapshot("unavailable")
        for offset in range(days)
    }


def allocated_minutes(forecast, item_id):
    return sum(
        int((block.end - block.start).total_seconds() // 60)
        for day in forecast.days
        for block in day.blocks
        if block.item_id == item_id
    )


def test_week_forecast_counts_effort_once_and_exposes_deadline_overload():
    tasks = [
        item(
            "a1", "split report", duration_minutes=90, splittable=True,
            deadline_date="2026-07-14",
        ),
        item(
            "a2", "long review", duration_minutes=120,
            deadline_date="2026-07-14",
        ),
    ]
    before = [task.to_dict() for task in tasks]

    forecast = build_week_forecast(
        tasks,
        snapshots(),
        NOW,
        PlanPreferences(work_start="09:00", work_end="10:00", breaks=()),
    )

    assert allocated_minutes(forecast, "a1") == 90
    assert allocated_minutes(forecast, "a2") == 0
    risk = next(risk for risk in forecast.risks if risk.item_id == "a2")
    assert risk.remaining_minutes == 120 and "deadline 2026-07-14" in risk.reason
    assert [task.to_dict() for task in tasks] == before


def test_dependency_may_start_next_forecast_day_but_cycle_stays_blocked():
    tasks = [
        item("a1", "prepare numbers", duration_minutes=60),
        item(
            "a2", "write summary", duration_minutes=30,
            deadline_date="2026-07-15", depends_on=["a1"],
        ),
        item(
            "a3", "cycle one", duration_minutes=15,
            deadline_date="2026-07-15", depends_on=["a4"],
        ),
        item(
            "a4", "cycle two", duration_minutes=15,
            deadline_date="2026-07-15", depends_on=["a3"],
        ),
    ]

    forecast = build_week_forecast(
        tasks,
        snapshots(),
        NOW,
        PlanPreferences(work_start="09:00", work_end="10:00", breaks=()),
    )

    prereq_day = next(
        day.day for day in forecast.days if any(b.item_id == "a1" for b in day.blocks)
    )
    dependent_day = next(
        day.day for day in forecast.days if any(b.item_id == "a2" for b in day.blocks)
    )
    assert prereq_day == "2026-07-13" and dependent_day == "2026-07-14"
    assert {risk.item_id for risk in forecast.risks} >= {"a3", "a4"}
    assert all("blocked by" in risk.reason for risk in forecast.risks if risk.item_id in {"a3", "a4"})


def test_adopted_session_is_reserved_and_not_allocated_twice():
    tasks = [
        item("a1", "already planned", duration_minutes=30),
        item("a2", "new work", duration_minutes=30),
    ]
    adopted = [PlanSession(
        "p1:s1", "p1", "a1", "already planned",
        "2026-07-13T09:00:00-04:00", "2026-07-13T09:30:00-04:00",
        status="planned",
    )]

    forecast = build_week_forecast(
        tasks,
        snapshots(),
        NOW,
        PlanPreferences(work_start="09:00", work_end="11:00", breaks=()),
        adopted_sessions=adopted,
    )

    assert allocated_minutes(forecast, "a1") == 30
    assert allocated_minutes(forecast, "a2") == 30
    monday = forecast.days[0]
    first, second = [block for block in monday.blocks if block.item_id in {"a1", "a2"}]
    assert first.end <= second.start


def test_adopted_session_with_missing_task_still_reserves_capacity():
    adopted = [PlanSession(
        "p1:s1", "p1", "missing", "removed but adopted",
        "2026-07-13T09:00:00-04:00", "2026-07-13T09:30:00-04:00",
        status="planned",
    )]

    forecast = build_week_forecast(
        [item("a1", "new work", duration_minutes=60)],
        snapshots(),
        NOW,
        PlanPreferences(work_start="09:00", work_end="10:00", breaks=()),
        adopted_sessions=adopted,
    )

    monday = forecast.days[0]
    assert [(block.item_id, block.start.strftime("%H:%M")) for block in monday.blocks] == [
        ("missing", "09:00")
    ]
    assert allocated_minutes(forecast, "a1") == 60
    assert next(
        day.day for day in forecast.days if any(b.item_id == "a1" for b in day.blocks)
    ) == "2026-07-14"


def test_calendar_break_and_buffer_reduce_capacity_on_each_day():
    calendar = snapshots()
    calendar["2026-07-13"] = CalendarSnapshot("authorized", [BusyPeriod(
        datetime(2026, 7, 13, 11, 30, tzinfo=TZ),
        datetime(2026, 7, 13, 12, 0, tzinfo=TZ),
    )])
    tasks = [item("a1", "focused task", duration_minutes=60, due_date="2026-07-13")]

    forecast = build_week_forecast(
        tasks,
        calendar,
        NOW,
        PlanPreferences(
            work_start="09:00",
            work_end="12:00",
            breaks=(("10:00", "11:00"),),
            transition_buffer_minutes=10,
        ),
    )

    assert allocated_minutes(forecast, "a1") == 0
    assert forecast.risks[0].item_id == "a1"
    assert forecast.days[0].calendar_status == "authorized"


def test_fixed_time_conflict_remains_visible_and_is_not_moved():
    calendar = snapshots()
    calendar["2026-07-15"] = CalendarSnapshot("authorized", [BusyPeriod(
        datetime(2026, 7, 15, 10, 0, tzinfo=TZ),
        datetime(2026, 7, 15, 11, 0, tzinfo=TZ),
    )])
    task = item(
        "a1", "fixed review", due_date="2026-07-15", due_time="10:00",
        duration_minutes=30, schedule_kind="fixed",
    )

    forecast = build_week_forecast(
        [task],
        calendar,
        NOW,
        PlanPreferences(work_start="09:00", work_end="17:00", breaks=()),
    )

    block = next(
        block
        for day in forecast.days
        for block in day.blocks
        if block.item_id == "a1"
    )
    assert block.start.isoformat() == "2026-07-15T10:00:00-04:00"
    assert any(
        '"fixed review" overlaps protected calendar time' in warning
        for warning in forecast.days[2].warnings
    )


def test_timezone_boundary_does_not_steal_tomorrows_window():
    late = datetime(2026, 7, 12, 23, 55, tzinfo=TZ)  # Sunday
    task = item("a1", "monday task", duration_minutes=60, due_date="2026-07-13")

    forecast = build_week_forecast(
        [task],
        snapshots(late),
        late,
        PlanPreferences(work_start="09:00", work_end="10:00", breaks=()),
    )

    assert forecast.days[0].blocks == []
    monday = next(day for day in forecast.days if day.day == "2026-07-13")
    assert monday.blocks[0].start.strftime("%H:%M") == "09:00"


def test_weekends_are_not_counted_when_profile_is_weekdays_only():
    task = item("a1", "large flexible task", duration_minutes=420, splittable=True)

    forecast = build_week_forecast(
        [task],
        snapshots(),
        NOW,
        PlanPreferences(
            work_start="09:00", work_end="10:00", work_days=(0, 1, 2, 3, 4),
            breaks=(),
        ),
    )

    assert allocated_minutes(forecast, "a1") == 300
    assert all(day.blocks == [] and day.free_minutes == 0 for day in forecast.days[5:])
    assert forecast.unplaced[0].remaining_minutes == 120


def test_weekly_what_if_budget_is_counted_once_across_the_horizon():
    tasks = [
        item("a1", "first", duration_minutes=60),
        item(
            "a2", "tomorrow", due_date="2026-07-14", duration_minutes=60,
        ),
    ]

    forecast = build_week_forecast(
        tasks,
        snapshots(),
        NOW,
        PlanPreferences(
            work_start="09:00", work_end="17:00", breaks=(),
            budget_minutes=90, budget_scope="horizon",
        ),
    )

    assert forecast.used_minutes == 60
    assert forecast.free_minutes == 30
    assert allocated_minutes(forecast, "a2") == 0
    assert next(risk for risk in forecast.risks if risk.item_id == "a2").remaining_minutes == 60


def test_daily_what_if_budget_caps_each_days_reported_capacity():
    forecast = build_week_forecast(
        [item("a1", "first", duration_minutes=60)],
        snapshots(),
        NOW,
        PlanPreferences(
            work_start="09:00", work_end="17:00", breaks=(),
            budget_minutes=90, budget_scope="day",
        ),
    )

    assert forecast.days[0].free_minutes == 30
    assert all(day.free_minutes == 90 for day in forecast.days[1:])
    assert forecast.free_minutes == 570
