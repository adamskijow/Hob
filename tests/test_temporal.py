# SPDX-License-Identifier: MIT
"""Schema-9 temporal constraints through the full message spine."""
from datetime import datetime
from zoneinfo import ZoneInfo

from app import MessageService
from adapters.store_sqlite import SCHEMA_VERSION, SqliteStore
from adapters.telegram_bot import InboundMessage
from core.models import Item, RecurrenceRule
from core.recurrence import next_due
from tests.fakes import FakeClock, FakeLlm

TZ = ZoneInfo("America/New_York")


def message(text: str, message_id: int = 1) -> InboundMessage:
    return InboundMessage(text, 1, message_id, message_id)


def setup(responses):
    store = SqliteStore(":memory:")
    store.add_item(
        Item(
            id="a1", raw_text="outline deck", task="outline deck",
            due_date=None, due_time=None, status="open", source="capture",
            created_at="2026-06-29T08:00:00", updated_at="2026-06-29T08:00:00",
        )
    )
    store.add_item(
        Item(
            id="a2", raw_text="get numbers", task="get numbers",
            due_date=None, due_time=None, status="open", source="capture",
            created_at="2026-06-29T08:01:00", updated_at="2026-06-29T08:01:00",
        )
    )
    store.set_meta("item_seq", "2")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    return MessageService(store, clock, FakeLlm(responses), "America/New_York"), store, clock


def test_capture_distinguishes_plan_from_deadline_and_keeps_effort_constraints():
    service, store, _ = setup(
        {"actions": [{
            "type": "capture", "task": "finish board deck", "raw": "finish board deck",
            "when": {"kind": "weekday", "which": "next", "day": "fri"},
            "deadline": {"kind": "absolute", "date": "2026-07-06"},
            "duration_minutes": 180, "duration_confidence": 1,
            "schedule_kind": "flexible", "splittable": True,
            "earliest": {"kind": "tomorrow"}, "preferred_window": "morning",
            "parent": "a1", "depends_on": ["a2"],
            "reminder_offsets": [60, 10],
        }]}
    )
    reply = service.handle(message("work on the deck Friday; due Monday, three hours"))
    item = store.get_item("a3")
    assert item.due_date == "2026-07-03"
    assert item.deadline_date == "2026-07-06"
    assert item.duration_minutes == 180 and item.duration_confidence == 1
    assert item.splittable and item.earliest_start == "2026-06-30"
    assert item.preferred_window == "morning"
    assert item.parent_id == "a1" and item.depends_on == ["a2"]
    assert item.reminder_offsets == [60, 10]
    assert "deadline 2026-07-06" in reply and "3h" in reply


def test_schedule_edit_is_undoable_and_dependency_cycles_are_rejected():
    service, store, _ = setup([
        {"actions": [{
            "type": "schedule", "target": "a1",
                "deadline": {"kind": "absolute", "date": "2026-07-02"},
            "duration_minutes": 90, "duration_confidence": 0.8,
            "schedule_kind": "fixed", "splittable": False,
            "preferred_window": "13:00-15:00", "depends_on": ["a2"],
            "reminder_offsets": [30, 5],
        }]},
        {"actions": [{"type": "undo"}]},
    ])
    reply = service.handle(message("deck is due Thursday and takes 90 minutes"))
    item = store.get_item("a1")
    assert item.deadline_date == "2026-07-02" and item.duration_minutes == 90
    assert item.schedule_kind == "fixed" and item.depends_on == ["a2"]
    assert "updated schedule" in reply

    service.handle(message("undo", 2))
    restored = store.get_item("a1")
    assert restored.deadline_date is None and restored.depends_on == []

    a2 = store.get_item("a2")
    a2.depends_on = ["a1"]
    store.update_item(a2)
    cycle_service = MessageService(
        store,
        FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ)),
        FakeLlm({"actions": [{"type": "schedule", "target": "a1", "depends_on": ["a2"]}]}),
        "America/New_York",
    )
    reply = cycle_service.handle(message("do deck after numbers", 3))
    assert "conflict" in reply and store.get_item("a1").depends_on == []


def test_structured_recurrence_preserves_fixed_cadence_and_count():
    service, store, clock = setup([
        {"actions": [{
            "type": "capture", "task": "water plants", "raw": "water plants",
            "when": {"kind": "none"}, "repeat": "every:2:week",
            "repeat_anchor": "fixed", "repeat_count": 3,
        }]},
        {"actions": [{
            "type": "reschedule", "target": "a3",
            "when": {"kind": "absolute", "date": "2026-07-02"},
        }]},
        {"actions": [{"type": "complete", "target": "a3"}]},
    ])
    service.handle(message("water plants every two weeks"))
    item = store.get_item("a3")
    assert isinstance(item.recurrence, RecurrenceRule)
    assert item.recurrence.anchor_date == "2026-06-29"
    assert item.recurrence.count == 3

    service.handle(message("move water plants to July 2", 2))
    clock.set(datetime(2026, 7, 2, 9, 0, tzinfo=TZ))
    service.handle(message("watered plants", 3))
    item = store.get_item("a3")
    assert item.due_date == "2026-07-13"  # fixed series did not shift from June 29
    assert item.recurrence.completed == 1


def test_recurrence_skip_completion_anchor_and_end_count():
    rule = RecurrenceRule(
        frequency="day", anchor="completion", anchor_date="2026-06-29",
        count=2,
    )
    assert next_due(rule, datetime(2026, 7, 3).date()) == datetime(2026, 7, 4).date()

    service, store, _ = setup({"actions": [{"type": "recur", "target": "a1", "op": "skip"}]})
    item = store.get_item("a1")
    item.due_date = "2026-06-29"
    item.repeat = "daily"
    item.recurrence = RecurrenceRule(
        frequency="day", anchor_date="2026-06-29"
    )
    store.update_item(item)
    service.handle(message("skip the next deck occurrence"))
    skipped = store.get_item("a1")
    assert skipped.due_date == "2026-06-30"
    assert skipped.recurrence.exceptions == ["2026-06-29"]


def test_recurrence_count_closes_series_and_stop_keeps_current_occurrence():
    service, store, _ = setup([
        {"actions": [{"type": "complete", "target": "a1"}]},
        {"actions": [{"type": "recur", "target": "a2", "op": "stop"}]},
    ])
    first = store.get_item("a1")
    first.due_date = "2026-06-29"
    first.recurrence = RecurrenceRule(
        frequency="day", anchor_date="2026-06-29", count=1
    )
    first.repeat = "daily"
    store.update_item(first)
    second = store.get_item("a2")
    second.due_date = "2026-06-29"
    second.recurrence = RecurrenceRule(frequency="day", anchor_date="2026-06-29")
    second.repeat = "daily"
    store.update_item(second)

    service.handle(message("finished the outline", 1))
    assert store.get_item("a1").status == "done"
    service.handle(message("stop repeating numbers", 2))
    stopped = store.get_item("a2")
    assert stopped.status == "open" and stopped.recurrence is None
    assert stopped.repeat is None


def test_temporal_fields_and_recurrence_round_trip():
    store = SqliteStore(":memory:")
    item = Item(
        id="a1", raw_text="x", task="x", due_date="2026-07-01", due_time="09:00",
        status="open", source="capture", created_at="2026-06-29T08:00:00",
        updated_at="2026-06-29T08:00:00", deadline_date="2026-07-02",
        duration_minutes=45, duration_confidence=0.75, schedule_kind="fixed",
        splittable=True, earliest_start="2026-06-30T10:00",
        preferred_window="morning", parent_id="a9", depends_on=["a8"],
        reminder_offsets=[60, 10], reminded_offsets=[60],
        recurrence=RecurrenceRule(frequency="week", weekdays=["wed"]),
    )
    store.add_item(item)
    restored = store.get_item("a1")
    assert restored.deadline_date == item.deadline_date
    assert restored.duration_minutes == item.duration_minutes
    assert restored.depends_on == item.depends_on
    assert restored.reminder_offsets == item.reminder_offsets
    assert restored.recurrence == item.recurrence


def test_v8_release_fixture_migrates_to_structured_recurrence(tmp_path):
    import sqlite3
    from pathlib import Path

    db = tmp_path / "hob.db"
    fixture = Path(__file__).parent / "fixtures" / "schema_v8.sql"
    conn = sqlite3.connect(db)
    conn.executescript(fixture.read_text(encoding="utf-8"))
    conn.close()
    with SqliteStore(str(db)) as store:
        item = store.get_item("a1")
        assert store.schema_version == SCHEMA_VERSION
        assert item.recurrence.frequency == "week" and item.recurrence.interval == 2
        assert item.duration_minutes is None and item.depends_on == []
    assert len(list(tmp_path.glob("hob.db.pre-v8-to-v10-*.bak"))) == 1
