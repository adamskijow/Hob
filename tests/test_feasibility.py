# SPDX-License-Identifier: MIT
from datetime import date, datetime
from zoneinfo import ZoneInfo

from adapters.calendar_eventkit import EventKitCalendar
from core.feasibility import (
    BusyPeriod,
    CalendarSnapshot,
    PlanPreferences,
    build_day_plan,
    diff_day_plans,
    parse_plan_preferences,
)
from core.models import Item

TZ = ZoneInfo("America/New_York")
NOW = datetime(2026, 7, 11, 9, 0, tzinfo=TZ)


def item(item_id: str, task: str, **changes) -> Item:
    values = {
        "id": item_id,
        "raw_text": task,
        "task": task,
        "due_date": None,
        "due_time": None,
        "status": "open",
        "source": "capture",
        "created_at": f"2026-07-11T08:0{item_id[-1]}:00",
        "updated_at": f"2026-07-11T08:0{item_id[-1]}:00",
    }
    values.update(changes)
    return Item(**values)


def test_calendar_busy_break_and_fixed_commitment_are_respected():
    busy = BusyPeriod(
        datetime(2026, 7, 11, 10, 0, tzinfo=TZ),
        datetime(2026, 7, 11, 11, 0, tzinfo=TZ),
    )
    tasks = [
        item("a1", "write brief", duration_minutes=60, priority="high"),
        item("a2", "dentist", due_date="2026-07-11", due_time="14:00",
             duration_minutes=60, schedule_kind="fixed"),
        item("a3", "review notes", duration_minutes=45),
    ]

    plan = build_day_plan(
        tasks, CalendarSnapshot("authorized", [busy]), NOW, PlanPreferences()
    )

    dentist = next(block for block in plan.blocks if block.item_id == "a2")
    assert dentist.start.hour == 14 and dentist.fixed
    for block in plan.blocks:
        if block.item_id == "a2":
            continue
        assert not (block.start < busy.end and block.end > busy.start)
        assert not (block.start.hour == 12 or block.end.hour == 12 and block.end.minute)
        assert not (block.start < dentist.end and block.end > dentist.start)


def test_time_budget_is_a_hard_bound_and_unknown_duration_is_visible():
    tasks = [item("a1", "first"), item("a2", "second")]
    prefs = parse_plan_preferences("I have 40 minutes and low energy")

    plan = build_day_plan(tasks, CalendarSnapshot("unavailable"), NOW, prefs)

    assert len(plan.blocks) == 1
    assert plan.blocks[0].inferred_duration
    assert sum(int((block.end - block.start).total_seconds() / 60) for block in plan.blocks) <= 40
    assert any(deferred.reason == "does not fit the stated time budget" for deferred in plan.deferred)


def test_future_day_uses_that_days_full_window_not_todays_clock():
    task = item(
        "a1",
        "tomorrow briefing",
        due_date="2026-07-12",
        due_time="09:00",
        duration_minutes=30,
        schedule_kind="fixed",
    )

    plan = build_day_plan(
        [task],
        CalendarSnapshot("authorized"),
        NOW.replace(hour=23, minute=55),
        PlanPreferences(breaks=()),
        target_day=date(2026, 7, 12),
    )

    assert plan.day == "2026-07-12"
    assert plan.blocks[0].start.strftime("%Y-%m-%d %H:%M") == "2026-07-12 09:00"


def test_explicit_default_duration_and_transition_buffer_shape_the_plan():
    tasks = [item("a1", "first"), item("a2", "second")]
    plan = build_day_plan(
        tasks,
        CalendarSnapshot("authorized"),
        NOW,
        PlanPreferences(
            breaks=(),
            default_duration_minutes=45,
            transition_buffer_minutes=10,
        ),
    )
    assert [
        (block.start.strftime("%H:%M"), block.end.strftime("%H:%M"))
        for block in plan.blocks
    ] == [("09:00", "09:45"), ("09:55", "10:40")]
    assert all(block.inferred_duration for block in plan.blocks)


def test_transition_buffer_protects_both_sides_of_calendar_events():
    snapshot = CalendarSnapshot(
        "authorized",
        [BusyPeriod(
            datetime(2026, 7, 11, 10, 0, tzinfo=TZ),
            datetime(2026, 7, 11, 11, 0, tzinfo=TZ),
        )],
    )
    task = item("a1", "ninety minutes", duration_minutes=90)
    plan = build_day_plan(
        [task],
        snapshot,
        NOW,
        PlanPreferences(
            breaks=(),
            transition_buffer_minutes=10,
        ),
    )
    assert plan.blocks[0].start.strftime("%H:%M") == "11:10"


def test_fixed_commitment_inside_buffer_is_flagged_but_not_moved():
    snapshot = CalendarSnapshot(
        "authorized",
        [BusyPeriod(
            datetime(2026, 7, 11, 9, 0, tzinfo=TZ),
            datetime(2026, 7, 11, 10, 0, tzinfo=TZ),
        )],
    )
    fixed = item(
        "a1", "fixed call", due_date="2026-07-11", due_time="10:05",
        duration_minutes=30, schedule_kind="fixed",
    )
    plan = build_day_plan(
        [fixed],
        snapshot,
        NOW,
        PlanPreferences(breaks=(), transition_buffer_minutes=10),
    )
    assert plan.blocks[0].start.strftime("%H:%M") == "10:05"
    assert any("less than the configured transition buffer" in warning for warning in plan.warnings)


def test_replanning_constraints_parse_literal_day_changes():
    prefs = parse_plan_preferences("afternoon gone; I can work after 10")
    assert prefs.earliest_time == "10:00"
    assert prefs.latest_time == "12:00"
    assert parse_plan_preferences("free after 2 before 5").earliest_time == "14:00"
    assert parse_plan_preferences("free after 2 before 5").latest_time == "17:00"


def test_splittable_work_uses_real_gaps_without_overlaps():
    busy = [
        BusyPeriod(datetime(2026, 7, 11, 10, 0, tzinfo=TZ), datetime(2026, 7, 11, 11, 0, tzinfo=TZ)),
        BusyPeriod(datetime(2026, 7, 11, 11, 30, tzinfo=TZ), datetime(2026, 7, 11, 17, 30, tzinfo=TZ)),
    ]
    task = item("a1", "draft report", duration_minutes=90, splittable=True)

    plan = build_day_plan(
        [task],
        CalendarSnapshot("authorized", busy),
        NOW,
        PlanPreferences(breaks=()),
    )

    assert [(block.start.strftime("%H:%M"), block.end.strftime("%H:%M")) for block in plan.blocks] == [
        ("09:00", "10:00"),
        ("11:00", "11:30"),
    ]
    assert not plan.deferred


def test_dependencies_and_earliest_start_are_explained():
    tasks = [
        item("a1", "numbers"),
        item("a2", "deck", depends_on=["a1"]),
        item("a3", "future", earliest_start="2026-07-12"),
    ]
    plan = build_day_plan(tasks, CalendarSnapshot("authorized"), NOW, PlanPreferences())
    reasons = {deferred.item_id: deferred.reason for deferred in plan.deferred}
    assert reasons["a2"] == "blocked by a1"
    assert "not ready until" in reasons["a3"]
    assert {block.item_id for block in plan.blocks} == {"a1"}


def test_fixed_conflict_is_flagged_and_never_silently_moved():
    task = item(
        "a1", "appointment", due_date="2026-07-11", due_time="10:00",
        duration_minutes=60, schedule_kind="fixed",
    )
    snapshot = CalendarSnapshot(
        "authorized",
        [BusyPeriod(datetime(2026, 7, 11, 10, 30, tzinfo=TZ), datetime(2026, 7, 11, 11, 30, tzinfo=TZ))],
    )
    plan = build_day_plan([task], snapshot, NOW, PlanPreferences())
    assert plan.blocks[0].start.strftime("%H:%M") == "10:00"
    assert any("overlaps protected calendar time" in warning for warning in plan.warnings)


def test_plan_diff_reports_moves_and_deferrals():
    task = item("a1", "write", duration_minutes=30)
    old = build_day_plan([task], CalendarSnapshot("authorized"), NOW, PlanPreferences())
    later = datetime(2026, 7, 11, 10, 0, tzinfo=TZ)
    new = build_day_plan([task], CalendarSnapshot("authorized"), later, PlanPreferences())
    assert diff_day_plans(old.to_dict(), new) == ['moved "write" 09:00 → 10:00']


def test_replan_keeps_unaffected_blocks_stable():
    tasks = [
        item("a1", "first", duration_minutes=30),
        item("a2", "second", duration_minutes=30),
    ]
    old = build_day_plan(tasks, CalendarSnapshot("authorized"), NOW, PlanPreferences())
    changed_calendar = CalendarSnapshot(
        "authorized",
        [BusyPeriod(NOW, NOW.replace(minute=30))],
    )
    new = build_day_plan(
        tasks,
        changed_calendar,
        NOW,
        PlanPreferences(),
        previous=old.to_dict(),
    )
    times = {block.item_id: block.start.strftime("%H:%M") for block in new.blocks}
    assert times == {"a2": "09:30", "a1": "10:00"}
    assert diff_day_plans(old.to_dict(), new) == ['moved "first" 09:00 → 10:00']


def test_elapsed_timed_commitment_is_flagged_not_planned_in_the_past():
    now = datetime(2026, 7, 11, 15, 0, tzinfo=TZ)
    past = item(
        "a1", "morning call", due_date="2026-07-11", due_time="10:00",
        duration_minutes=30, schedule_kind="fixed",
    )
    plan = build_day_plan(
        [past], CalendarSnapshot("authorized"), now, PlanPreferences()
    )
    assert not plan.blocks
    assert plan.deferred[0].reason == "stated time has passed; it was not moved"
    assert any("missed stated time" in warning for warning in plan.warnings)


def test_eventkit_adapter_never_requires_event_titles(monkeypatch):
    calendar = EventKitCalendar("/unused")
    monkeypatch.setattr(
        calendar,
        "_run",
        lambda *args: {
            "status": "authorized",
            "events": [{
                "id": "opaque",
                "start": "2026-07-11T10:00:00-04:00",
                "end": "2026-07-11T11:00:00-04:00",
                "title": "must be ignored",
            }],
        },
    )
    snapshot = calendar.snapshot(NOW, NOW.replace(hour=17))
    assert snapshot.status == "authorized" and len(snapshot.busy) == 1
    assert not hasattr(snapshot.busy[0], "title")
