# SPDX-License-Identifier: MIT
"""Action log + /undo: a batch applied then reverted leaves state identical."""
import json
from datetime import datetime
from zoneinfo import ZoneInfo

from app import MessageService
from core.models import ActionLogEntry, Item
from core.undo import plan_undo
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage
from tests.fakes import FakeClock, FakeLlm

TZ = ZoneInfo("America/New_York")


def msg(text, message_id=1):
    return InboundMessage(text=text, chat_id=1, message_id=message_id, update_id=message_id)


def item(id, task, due=None, status="open", created="2026-06-20T08:00:00"):
    return Item(
        id=id,
        raw_text=task,
        task=task,
        due_date=due,
        due_time=None,
        status=status,
        source="capture",
        created_at=created,
        updated_at=created,
    )


def seeded_service(llm):
    store = SqliteStore(":memory:")
    store.add_item(item("a1", "org prez"))
    store.add_item(item("a2", "call pool"))
    store.add_item(item("a3", "review audit", due="2026-06-28"))
    store.set_meta("item_seq", "3")  # as if these came from next_item_id
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    return MessageService(store, clock, llm, "America/New_York"), store


def snapshot(store):
    return {i.id: i.to_dict() for i in [store.get_item(x) for x in ("a1", "a2", "a3")] if i}


# pure plan_undo --------------------------------------------------------------


def test_plan_undo_capture_is_delete():
    after = json.dumps(item("a9", "new").to_dict())
    batch = [ActionLogEntry(batch_id="b1", ts="t", action_type="capture", item_id="a9",
                            before_json=None, after_json=after)]
    ops = plan_undo(batch)
    assert ops[0].kind == "delete" and ops[0].item_id == "a9"


def test_plan_undo_change_is_restore_before():
    before = json.dumps(item("a1", "x", status="open").to_dict())
    after = json.dumps(item("a1", "x", status="done").to_dict())
    batch = [ActionLogEntry(batch_id="b1", ts="t", action_type="complete", item_id="a1",
                            before_json=before, after_json=after)]
    ops = plan_undo(batch)
    assert ops[0].kind == "restore"
    assert ops[0].item.status == "open"


# end to end ------------------------------------------------------------------


def test_capture_then_undo_removes_item():
    llm = FakeLlm({"actions": [{"type": "capture", "task": "buy milk", "raw": "buy milk"}]})
    svc, store = seeded_service(llm)
    svc.handle(msg("buy milk"))
    assert store.get_item("a4") is not None
    assert svc.handle(msg("/undo")) == "undid 1 change(s)"
    assert store.get_item("a4") is None


def test_multi_action_batch_undo_restores_exact_state():
    before = None
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
    svc, store = seeded_service(llm)
    before = snapshot(store)

    svc.handle(msg("did prez, drop pool, push audit to friday"))
    # state changed
    assert store.get_item("a1").status == "done"
    assert store.get_item("a3").due_date == "2026-07-03"

    out = svc.handle(msg("/undo", message_id=2))
    assert "undid 3" in out
    assert snapshot(store) == before  # byte-for-byte identical, including updated_at


def test_undo_walks_back_one_batch_at_a_time():
    svc, store = seeded_service(FakeLlm({"actions": [{"type": "complete", "target": "a1", "confidence": 0.9}]}))
    svc.handle(msg("did prez", message_id=1))  # batch 1: complete a1
    # second batch via a different llm response
    svc._llm = FakeLlm({"actions": [{"type": "complete", "target": "a2", "confidence": 0.9}]})
    svc.handle(msg("did pool", message_id=2))  # batch 2: complete a2

    assert store.get_item("a1").status == "done"
    assert store.get_item("a2").status == "done"

    svc.handle(msg("/undo", message_id=3))  # reverts batch 2
    assert store.get_item("a2").status == "open"
    assert store.get_item("a1").status == "done"

    svc.handle(msg("/undo", message_id=4))  # reverts batch 1
    assert store.get_item("a1").status == "open"


def test_undo_with_nothing_to_undo():
    svc, _ = seeded_service(FakeLlm({"actions": []}))
    assert svc.handle(msg("/undo")) == "nothing to undo"


def test_questions_do_not_create_an_undoable_batch():
    # ambiguous capture -> a question, no mutation, so nothing to undo
    svc, store = seeded_service(FakeLlm({"actions": [{"type": "capture", "task": "x", "raw": "Friday or Monday"}]}))
    svc.handle(msg("x friday or monday"))
    assert svc.handle(msg("/undo")) == "nothing to undo"
