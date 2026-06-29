# SPDX-License-Identifier: MIT
"""The spine end to end: one message, several actions, through MessageService.

Every inbound message (captures, EOD reports, corrections, queries) takes the
same path: interpret -> reconcile -> apply.
"""
from datetime import datetime
from zoneinfo import ZoneInfo

from app import MessageService
from core.models import Item
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage
from tests.fakes import FakeClock, FakeLlm

TZ = ZoneInfo("America/New_York")


def msg(text, message_id=1):
    return InboundMessage(text=text, chat_id=1, message_id=message_id, update_id=message_id)


def seed(store):
    base = [
        ("a1", "org prez", None, "2026-06-25T08:00:00"),
        ("a2", "call the pool guy", None, "2026-06-26T08:00:00"),
        ("a3", "review SR audit", "2026-06-28", "2026-06-27T08:00:00"),
    ]
    for id, task, due, created in base:
        store.add_item(
            Item(
                id=id,
                raw_text=task,
                task=task,
                due_date=due,
                due_time=None,
                status="open",
                source="capture",
                created_at=created,
                updated_at=created,
            )
        )


def service(llm):
    store = SqliteStore(":memory:")
    seed(store)
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))  # Monday
    return MessageService(store, clock, llm, "America/New_York"), store


def test_multi_action_correction_applies_all():
    llm = FakeLlm(
        {
            "actions": [
                {"type": "complete", "target": "a1", "confidence": 0.95},
                {"type": "drop", "target": "a2", "confidence": 0.95},
                {"type": "reschedule", "target": "a3", "raw": "to Friday",
                 "due": "2026-07-03", "confidence": 0.95},
            ]
        }
    )
    svc, store = service(llm)

    out = svc.handle(msg("already did the prez one, drop the pool call, push the audit to Friday"))

    assert store.get_item("a1").status == "done"
    assert store.get_item("a2").status == "dropped"
    assert store.get_item("a3").due_date == "2026-07-03"
    assert "done: org prez" in out
    assert "dropped: call the pool guy" in out
    assert "moved review SR audit to 2026-07-03" in out
    # only the rescheduled item remains open
    assert [i.id for i in store.open_items()] == ["a3"]


def test_unresolved_reference_asks_and_changes_nothing():
    llm = FakeLlm({"actions": [{"type": "complete", "target": "a9", "confidence": 0.95}]})
    svc, store = service(llm)

    out = svc.handle(msg("did the thing"))

    assert "could not find" in out.lower()
    assert store.get_item("a1").status == "open"  # nothing mutated
    assert len(store.open_items()) == 3


def test_low_confidence_reference_asks():
    llm = FakeLlm({"actions": [{"type": "complete", "target": "a1", "confidence": 0.2}]})
    svc, store = service(llm)

    out = svc.handle(msg("maybe the prez"))

    assert "did you mean: org prez" in out
    assert store.get_item("a1").status == "open"


def test_eod_report_completes_multiple():
    llm = FakeLlm(
        {
            "actions": [
                {"type": "complete", "target": "a1", "confidence": 0.9},
                {"type": "complete", "target": "a3", "confidence": 0.9},
            ]
        }
    )
    svc, store = service(llm)

    svc.handle(msg("did the prez and the audit"))

    assert store.get_item("a1").status == "done"
    assert store.get_item("a3").status == "done"


def test_pending_clarification_resume():
    # Turn 1 asks about an ambiguous date and persists the pending capture; turn 2
    # answers it, and the prompt for turn 2 carries the pending context.
    llm = FakeLlm(
        [
            {"actions": [{"type": "capture", "task": "lunch with sam",
                          "raw": "lunch with sam thursday or friday"}]},
            {"actions": [{"type": "capture", "task": "lunch with sam",
                          "raw": "thursday"}]},
        ]
    )
    store = SqliteStore(":memory:")  # unseeded, so the capture gets a clean id
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))  # Monday
    svc = MessageService(store, clock, llm, "America/New_York")

    out1 = svc.handle(msg("lunch with sam thursday or friday"))
    assert "more than one date" in out1
    assert store.get_meta("pending")  # persisted
    assert not store.open_items()  # nothing captured yet

    out2 = svc.handle(msg("oh yeah thursday", message_id=2))
    assert "Pending question" in llm.calls[1][0]  # follow-up prompt carried it
    lunch = store.open_items()
    assert len(lunch) == 1 and lunch[0].task == "lunch with sam"
    assert lunch[0].due_date == "2026-07-02"  # Thursday after Mon 2026-06-29
    assert not store.get_meta("pending")  # cleared


def test_bulk_drop_all_clears_the_list():
    llm = FakeLlm({"actions": [{"type": "bulk", "op": "drop", "scope": "all"}]})
    svc, store = service(llm)  # seeded a1, a2, a3, all open

    out = svc.handle(msg("delete everything"))

    assert store.open_items() == []
    assert "dropped" in out


def test_query_today_lists_items():
    llm = FakeLlm({"actions": [{"type": "query", "kind": "today"}]})
    svc, store = service(llm)

    out = svc.handle(msg("what's on today?"))

    assert "today:" in out
    assert "a3: review SR audit" in out  # overdue rolls into today
