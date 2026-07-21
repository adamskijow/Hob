# SPDX-License-Identifier: MIT
"""The spine end to end: one message, several actions, through MessageService.

Every inbound message (captures, EOD reports, corrections, queries) takes the
same path: interpret -> reconcile -> apply.
"""
import json
from datetime import datetime
from zoneinfo import ZoneInfo

from app import (
    DIGEST_DECISION_KEY,
    FOCUS_KEY,
    PENDING_KEY,
    PINNED_KEY,
    PRESENTED_LIST_KEY,
    MessageService,
)
from core.models import Digest, DigestItem, Item, PlanRun, PlanSession
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage
from tests.fakes import FakeClock, FakeLlm

TZ = ZoneInfo("America/New_York")


def msg(text, message_id=1, reply_to=None):
    return InboundMessage(
        text=text,
        chat_id=1,
        message_id=message_id,
        update_id=message_id,
        reply_to=reply_to,
    )


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
    # Advance the id counter past the seeded ids so a later capture gets a4, not
    # a1 (production ids always come from next_item_id, which bumps this).
    store.set_meta("item_seq", str(len(base)))


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
                {"type": "reschedule", "target": "a3",
                 "when": {"kind": "weekday", "which": "next", "day": "fri"},
                 "confidence": 0.95},
            ]
        }
    )
    svc, store = service(llm)

    out = svc.handle(msg("already did the prez one, drop the pool call, push the audit to Friday"))

    assert store.get_item("a1").status == "done"
    assert store.get_item("a2").status == "dropped"
    assert store.get_item("a3").due_date == "2026-07-03"
    assert 'done: "org prez"' in out
    assert 'dropped: "call the pool guy"' in out
    assert 'moved "review SR audit" to 2026-07-03' in out
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

    assert 'did you mean "org prez"' in out
    assert store.get_meta("pending_confirm")
    assert store.get_item("a1").status == "open"


def test_low_confidence_confirmation_resumes_on_yes_and_cancels_on_no():
    llm = FakeLlm([
        {"actions": [{"type": "complete", "target": "a1", "confidence": 0.2}]},
        {"actions": [{"type": "confirmation_decision", "decision": "approve"}]},
        {"outcome": "approve", "confidence": 1.0},
    ])
    svc, store = service(llm)

    first = svc.handle(msg("maybe the prez"))
    assert "whether to mark it done" in first
    confirmed = svc.handle(msg("yes", message_id=2))
    assert 'done: "org prez"' in confirmed
    assert store.get_item("a1").status == "done"

    llm2 = FakeLlm([
        {"actions": [{"type": "drop", "target": "a2", "confidence": 0.2}]},
        {"actions": [{"type": "confirmation_decision", "decision": "reject"}]},
        {"outcome": "reject", "confidence": 1.0},
    ])
    svc2, store2 = service(llm2)
    svc2.handle(msg("maybe drop the pool one"))
    assert svc2.handle(msg("no", message_id=2)) == "canceled. nothing changed."
    assert store2.get_item("a2").status == "open"


def test_confirmation_requires_semantic_approval_not_a_yes_prefix():
    llm = FakeLlm([
        {"actions": [{"type": "complete", "target": "a1", "confidence": 0.2}]},
        {"actions": [{
            "type": "capture",
            "task": "review yesterday notes",
            "raw": "yesterday notes need review",
            "when": {"kind": "none"},
        }]},
        {"outcome": "other", "confidence": 1.0},
    ])
    svc, store = service(llm)

    svc.handle(msg("maybe the prez"))
    out = svc.handle(msg("yesterday notes need review", message_id=2))

    assert store.get_item("a1").status == "open"
    assert any(item.task == "review yesterday notes" for item in store.open_items())
    assert "got it" in out
    assert store.get_meta("pending_confirm") == ""


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


def test_eod_zero_completion_report_is_model_interpreted_and_mutation_free():
    llm = FakeLlm([
        {"actions": [{"type": "recap", "outcome": "none", "confidence": 1.0}]},
        {"outcome": "none", "confidence": 1.0},
    ])
    svc, store = service(llm)
    store.set_meta(
        PRESENTED_LIST_KEY,
        json.dumps(
            {
                "ts": "2026-06-29T08:30:00-04:00",
                "kind": "eod",
                "items": [
                    {"id": "a1", "label": "org prez"},
                    {"id": "a2", "label": "call the pool guy"},
                ],
            }
        ),
    )

    out = svc.handle(msg("Nothing got done"))

    assert out == "okay. nothing marked done. both items stay open on deck."
    assert store.get_item("a1").status == "open"
    assert store.get_item("a2").status == "open"
    assert store.last_batch() == []
    assert len(llm.calls) == 2
    assert "kind: evening recap" in llm.calls[0][0]


def test_eod_zero_completion_idiom_is_semantically_recovered_by_model():
    llm = FakeLlm([
        {"actions": [{"type": "chitchat", "reply": "got it"}]},
        {"outcome": "none", "confidence": 0.96},
    ])
    svc, store = service(llm)
    store.set_meta(
        PRESENTED_LIST_KEY,
        json.dumps(
            {
                "ts": "2026-06-29T08:30:00-04:00",
                "kind": "eod",
                "items": [
                    {"id": "a1", "label": "org prez"},
                    {"id": "a2", "label": "call the pool guy"},
                ],
            }
        ),
    )

    out = svc.handle(msg("nada"))

    assert out == "okay. nothing marked done. both items stay open on deck."
    assert all(item.status == "open" for item in store.open_items())
    assert store.last_batch() == []
    assert len(llm.calls) == 2


def test_eod_ambiguous_recap_outage_preserves_safe_main_result():
    class StopsOnAdjudication:
        def __init__(self):
            self.calls = 0

        def complete_json(self, prompt, schema, temperature=0.0):
            self.calls += 1
            if self.calls == 1:
                return {"actions": [{"type": "unknown", "note": "unclear"}]}
            raise RuntimeError("model stopped between passes")

    llm = StopsOnAdjudication()
    svc, store = service(llm)
    store.set_meta(
        PRESENTED_LIST_KEY,
        json.dumps(
            {
                "ts": "2026-06-29T08:30:00-04:00",
                "kind": "eod",
                "items": [{"id": "a1", "label": "org prez"}],
            }
        ),
    )

    out = svc.handle(msg("the scoreboard stayed empty"))

    assert "did not catch" in out
    assert all(item.status == "open" for item in store.open_items())
    assert store.last_batch() == []


def test_chitchat_after_eod_survives_semantic_adjudication():
    llm = FakeLlm([
        {"actions": [{"type": "chitchat", "reply": "anytime"}]},
        {"outcome": "social", "confidence": 1.0},
        {"reply": "always happy to help"},
    ])
    svc, store = service(llm)
    store.set_meta(
        PRESENTED_LIST_KEY,
        json.dumps(
            {
                "ts": "2026-06-29T08:30:00-04:00",
                "kind": "eod",
                "items": [{"id": "a1", "label": "org prez"}],
            }
        ),
    )

    out = svc.handle(msg("thanks hob"))

    assert out == "always happy to help"
    assert len(llm.calls) == 3
    assert llm.calls[2][2] > 0.0
    assert store.get_item("a1").status == "open"


def test_zero_completion_report_preserves_previous_batch_for_undo():
    llm = FakeLlm([
        {"actions": [{"type": "complete", "target": "a1", "confidence": 1.0}]},
        {"actions": [{"type": "recap", "outcome": "none", "confidence": 1.0}]},
        {"outcome": "none", "confidence": 1.0},
    ])
    svc, store = service(llm)
    svc.handle(msg("did the prez", message_id=1))
    assert store.get_item("a1").status == "done"
    store.set_meta(
        PRESENTED_LIST_KEY,
        json.dumps(
            {
                "ts": "2026-06-29T08:30:00-04:00",
                "kind": "eod",
                "items": [
                    {"id": "a2", "label": "call the pool guy"},
                    {"id": "a3", "label": "review SR audit"},
                ],
            }
        ),
    )

    out = svc.handle(msg("Nothing got done", message_id=2))
    undone = svc.handle(msg("/undo", message_id=3))

    assert out == "okay. nothing marked done. both items stay open on deck."
    assert "undid 1 change" in undone
    assert store.get_item("a1").status == "open"
    assert len(llm.calls) == 3


def test_eod_zero_completion_report_degrades_honestly_when_model_is_down():
    store = SqliteStore(":memory:")
    seed(store)
    store.set_meta(
        PRESENTED_LIST_KEY,
        json.dumps(
            {
                "ts": "2026-06-29T08:30:00-04:00",
                "kind": "eod",
                "items": [
                    {"id": "a1", "label": "org prez"},
                    {"id": "a2", "label": "call the pool guy"},
                ],
            }
        ),
    )
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, _BoomLlm(), "America/New_York")

    out = svc.handle(msg("nada"))

    assert "can't reach the model" in out
    assert all(item.status == "open" for item in store.open_items())
    assert store.last_batch() == []


def test_completion_report_uses_model_owned_coordinated_tense():
    llm = FakeLlm(
        {
            "actions": [
                {"type": "complete", "target": "a2", "confidence": 0.95},
                {"type": "complete", "target": "a3", "confidence": 0.95},
            ]
        }
    )
    svc, store = service(llm)

    out = svc.handle(msg("I did the pool call and reviewed the audit"))

    assert store.get_item("a2").status == "done"
    assert store.get_item("a3").status == "done"
    assert 'done: "call the pool guy"' in out
    assert 'done: "review SR audit"' in out
    assert "not marked it done" not in out


def test_numbered_digest_exclusions_are_typed_end_to_end():
    llm = FakeLlm([
        {"actions": [{
            "type": "bulk", "op": "complete", "scope": "today",
            "except": ["a1", "a6"],
        }]},
        {"scope": "today", "confidence": 1.0},
    ])
    svc, store = service(llm)
    third = store.get_item("a3")
    third.status = "done"
    store.update_item(third)
    for item_id, label, status in (
        ("a4", "business case", "open"),
        ("a5", "home insurance", "done"),
        ("a6", "add two paths", "open"),
    ):
        store.add_item(
            Item(
                id=item_id,
                raw_text=label,
                task=label,
                due_date=None,
                due_time=None,
                status=status,
                source="capture",
                created_at="2026-06-25T08:00:00-04:00",
                updated_at="2026-06-25T08:00:00-04:00",
            )
        )
    store.set_meta("item_seq", "6")
    store.save_digest(
        Digest(
            sent_at="2026-06-29T07:00:00-04:00",
            items=[
                DigestItem(id="a1", label="org prez"),
                DigestItem(id="a2", label="call the pool guy"),
                DigestItem(id="a3", label="review SR audit"),
                DigestItem(id="a4", label="business case"),
                DigestItem(id="a5", label="home insurance"),
                DigestItem(id="a6", label="add two paths"),
            ],
        )
    )

    out = svc.handle(msg("Finished it all except 1 and 6"))

    assert store.get_item("a1").status == "open"
    assert store.get_item("a2").status == "done"
    assert store.get_item("a3").status == "done"
    assert store.get_item("a4").status == "done"
    assert store.get_item("a4").note is None
    assert store.get_item("a5").status == "done"
    assert store.get_item("a6").status == "open"
    assert set(out.splitlines()) == {
        'done: "call the pool guy"',
        'done: "business case"',
    }


def test_plain_keep_uses_single_use_digest_decision_without_reply_metadata():
    llm = FakeLlm({"actions": [{
        "type": "nudge_decision", "decision": "keep", "confidence": 1.0,
    }]})
    svc, store = service(llm)
    store.set_meta(
        DIGEST_DECISION_KEY,
        json.dumps(
            {
                "item_id": "a1",
                "sent_at": "2026-06-29T07:00:00-04:00",
                "kind": "stale_task",
            }
        ),
    )

    out = svc.handle(msg("Keep"))

    kept = store.get_item("a1")
    assert kept.status == "open"
    assert kept.updated_at == "2026-06-29T09:00:00-04:00"
    assert out == 'keeping: "org prez". i will check again later.'
    assert store.get_meta(DIGEST_DECISION_KEY) == ""
    assert len(llm.calls) == 2

    # The proactive prompt was consumed; the same bare word cannot act twice.
    assert "current digest question" in svc.handle(msg("Keep", message_id=2))
    assert len(llm.calls) == 3


def test_natural_digest_answer_overrides_a_bad_setting_guess_safely():
    llm = FakeLlm([
        {"actions": [{
            "type": "setting",
            "key": "eod_time",
            "raw": "stay on",
            "time": "20:00",
            "confidence": 0.9,
        }]},
        {"outcome": "keep", "confidence": 0.98},
    ])
    svc, store = service(llm)
    store.set_meta(
        DIGEST_DECISION_KEY,
        json.dumps({
            "item_id": "a1",
            "sent_at": "2026-06-29T07:00:00-04:00",
            "kind": "stale_task",
        }),
    )

    out = svc.handle(msg("It needs to stay on"))

    assert out == 'keeping: "org prez". i will check again later.'
    assert store.get_meta("eod_time") is None
    assert store.get_meta(DIGEST_DECISION_KEY) == ""
    assert "Active morning digest nudge" in llm.calls[0][0]


def test_plain_digest_tomorrow_and_drop_apply_to_the_prompted_item():
    tomorrow_llm = FakeLlm({"actions": [{
        "type": "nudge_decision", "decision": "tomorrow", "confidence": 1.0,
    }]})
    tomorrow_svc, tomorrow_store = service(tomorrow_llm)
    tomorrow_store.set_meta(
        DIGEST_DECISION_KEY,
        json.dumps(
            {
                "item_id": "a2",
                "sent_at": "2026-06-29T07:00:00-04:00",
                "kind": "stale_task",
            }
        ),
    )
    moved = tomorrow_svc.handle(msg("tomorrow"))
    assert tomorrow_store.get_item("a2").due_date == "2026-06-30"
    assert 'moved "call the pool guy" to 2026-06-30' in moved
    assert len(tomorrow_llm.calls) == 2

    drop_llm = FakeLlm({"actions": [{
        "type": "nudge_decision", "decision": "drop", "confidence": 1.0,
    }]})
    drop_svc, drop_store = service(drop_llm)
    drop_store.set_meta(
        DIGEST_DECISION_KEY,
        json.dumps(
            {
                "item_id": "a3",
                "sent_at": "2026-06-29T07:00:00-04:00",
                "kind": "stale_task",
            }
        ),
    )
    dropped = drop_svc.handle(msg("drop"))
    assert drop_store.get_item("a3").status == "dropped"
    assert dropped == 'dropped: "review SR audit"'
    assert len(drop_llm.calls) == 2


def test_digest_decision_is_same_day_and_newer_task_focus_wins():
    expired_llm = FakeLlm({"actions": [{"type": "unknown"}]})
    expired_svc, expired_store = service(expired_llm)
    expired_store.set_meta(
        DIGEST_DECISION_KEY,
        json.dumps(
            {
                "item_id": "a1",
                "sent_at": "2026-06-28T07:00:00-04:00",
                "kind": "stale_task",
            }
        ),
    )
    assert "did not catch" in expired_svc.handle(msg("Keep"))
    assert expired_store.get_item("a1").updated_at == "2026-06-25T08:00:00"

    focused_llm = FakeLlm({"actions": [{"type": "unknown"}]})
    focused_svc, focused_store = service(focused_llm)
    focused_store.set_meta(
        DIGEST_DECISION_KEY,
        json.dumps(
            {
                "item_id": "a1",
                "sent_at": "2026-06-29T07:00:00-04:00",
                "kind": "stale_task",
            }
        ),
    )
    focused_store.set_meta(
        FOCUS_KEY,
        json.dumps(
            {
                "ts": "2026-06-29T08:00:00-04:00",
                "items": [{"id": "a2", "label": "call the pool guy"}],
            }
        ),
    )
    assert "did not catch" in focused_svc.handle(msg("drop"))
    assert focused_store.get_item("a1").status == "open"


def test_upgrade_uses_todays_pinned_digest_anchor_for_plain_keep():
    llm = FakeLlm({"actions": [{
        "type": "nudge_decision", "decision": "keep", "confidence": 1.0,
    }]})
    svc, store = service(llm)
    store.save_digest(
        Digest(
            sent_at="2026-06-29T07:00:00-04:00",
            items=[DigestItem(id="a1", label="org prez")],
        )
    )
    store.record_sent_ref(777, "a1")
    store.set_meta(PINNED_KEY, "777")

    out = svc.handle(msg("Keep"))

    assert out == 'keeping: "org prez". i will check again later.'
    assert store.get_item("a1").updated_at == "2026-06-29T09:00:00-04:00"
    assert store.get_meta(DIGEST_DECISION_KEY) == ""
    assert len(llm.calls) == 2


def test_plain_back_on_resolves_the_waiting_digest_prompt():
    llm = FakeLlm({"actions": [{
        "type": "nudge_decision", "decision": "resume", "confidence": 1.0,
    }]})
    svc, store = service(llm)
    waiting = store.get_item("a2")
    waiting.waiting_since = "2026-06-25"
    store.update_item(waiting)
    store.set_meta(
        DIGEST_DECISION_KEY,
        json.dumps(
            {
                "item_id": "a2",
                "sent_at": "2026-06-29T07:00:00-04:00",
                "kind": "waiting",
            }
        ),
    )

    out = svc.handle(msg("back on"))

    assert out == 'back on: "call the pool guy"'
    assert store.get_item("a2").waiting_since is None
    assert store.get_meta(DIGEST_DECISION_KEY) == ""
    assert len(llm.calls) == 2


def test_plain_digest_decisions_fail_closed_on_invalid_or_competing_context():
    llm = FakeLlm({"actions": [{"type": "unknown"}]})
    svc, store = service(llm)

    store.set_meta(DIGEST_DECISION_KEY, "not json")
    assert "did not catch" in svc.handle(msg("Keep"))
    assert store.get_item("a1").updated_at == "2026-06-25T08:00:00"

    store.set_meta(
        DIGEST_DECISION_KEY,
        json.dumps(
            {
                "item_id": "a1",
                "sent_at": 123,
                "kind": "stale_task",
            }
        ),
    )
    assert "did not catch" in svc.handle(msg("Keep", message_id=2))
    assert store.get_item("a1").updated_at == "2026-06-25T08:00:00"

    store.set_meta(
        DIGEST_DECISION_KEY,
        json.dumps(
            {
                "item_id": "a1",
                "sent_at": "2026-06-29T07:00:00-04:00",
                "kind": "waiting",
            }
        ),
    )
    assert "did not catch" in svc.handle(msg("back on", message_id=3))
    assert store.get_item("a1").waiting_since is None

    store.set_meta(
        DIGEST_DECISION_KEY,
        json.dumps(
            {
                "item_id": "a1",
                "sent_at": "2026-06-29T07:00:00-04:00",
                "kind": "stale_task",
            }
        ),
    )
    store.set_meta(PENDING_KEY, "[]")
    assert "did not catch" in svc.handle(msg("Keep", message_id=4))
    assert store.get_item("a1").updated_at == "2026-06-25T08:00:00"


def test_pending_clarification_resume():
    # Turn 1 asks about an ambiguous date and persists the pending capture; turn 2
    # answers it, and the prompt for turn 2 carries the pending context.
    llm = FakeLlm(
        [
            {"actions": [{"type": "capture", "task": "lunch with sam",
                          "raw": "lunch with sam thursday or friday",
                          "when": {"kind": "ambiguous"}}]},
            {"actions": [{"type": "capture", "task": "lunch with sam",
                          "raw": "thursday", "when": {"kind": "weekday", "day": "thu"}}]},
        ]
    )
    store = SqliteStore(":memory:")  # unseeded, so the capture gets a clean id
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))  # Monday
    svc = MessageService(store, clock, llm, "America/New_York")

    out1 = svc.handle(msg("lunch with sam thursday or friday"))
    assert "not clear" in out1
    assert store.get_meta("pending")  # persisted
    assert not store.open_items()  # nothing captured yet

    out2 = svc.handle(msg("oh yeah thursday", message_id=2))
    assert any("Pending question" in prompt for prompt, _, _ in llm.calls)
    lunch = store.open_items()
    assert len(lunch) == 1 and lunch[0].task == "lunch with sam"
    assert lunch[0].due_date == "2026-07-02"  # Thursday after Mon 2026-06-29
    assert not store.get_meta("pending")  # cleared


class _BoomLlm:
    def complete_json(self, prompt, schema):
        raise RuntimeError("ollama down")


def test_model_unreachable_says_so_and_preserves_pending():
    store = SqliteStore(":memory:")
    store.set_meta("pending", '[{"kind": "capture", "question": "q", "task": "lunch"}]')
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, _BoomLlm(), "America/New_York")

    out = svc.handle(msg("thursday"))

    assert "can't reach the model" in out
    assert store.open_items() == []  # nothing applied
    assert store.get_meta("pending")  # an outage must not clear a pending question


def test_recurring_complete_advances_instead_of_closing():
    store = SqliteStore(":memory:")
    store.add_item(
        Item(id="a1", raw_text="water plants", task="water plants",
             due_date="2026-06-29", due_time=None, status="open", source="capture",
             created_at="2026-06-29T08:00:00", updated_at="2026-06-29T08:00:00",
             repeat="daily")
    )
    store.set_meta("item_seq", "1")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))  # Monday
    llm = FakeLlm({"actions": [{"type": "complete", "target": "1"}]})
    svc = MessageService(store, clock, llm, "America/New_York")

    out = svc.handle(msg("did the first one"))

    item = store.get_item("a1")
    assert item.status == "open"  # recurring: not closed
    assert item.due_date == "2026-06-30"  # advanced to the next day
    assert "next 2026-06-30" in out


def test_undo_via_natural_language():
    llm = FakeLlm([
        {"actions": [{"type": "capture", "task": "x", "raw": "x"}]},
        {"actions": [{"type": "undo"}]},
    ])
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")
    svc.handle(msg("x"))
    assert len(store.open_items()) == 1

    out = svc.handle(msg("scratch that", message_id=2))
    assert "undid" in out and store.open_items() == []


def test_immediate_nevermind_retracts_capture_instead_of_becoming_chitchat():
    llm = FakeLlm([
        {"actions": [{
            "type": "capture",
            "task": "hit the grift",
            "raw": "Tomorrow I got to hit the grift",
            "when": {"kind": "tomorrow"},
        }]},
        {"actions": [{"type": "undo"}]},
    ])
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    svc.handle(msg("Tomorrow I got to hit the grift"))
    assert any(item.task == "hit the grift" for item in store.open_items())

    out = svc.handle(msg("Nevermind I'm good", message_id=2))

    assert out == "undid 1 change(s)"
    assert all(item.task != "hit the grift" for item in store.open_items())


def test_done_query_lists_finished():
    llm = FakeLlm([
        {"actions": [{"type": "complete", "target": "1"}]},
        {"actions": [{"type": "query", "kind": "done"}]},
    ])
    store = SqliteStore(":memory:")
    store.add_item(Item(id="a1", raw_text="prez", task="prez", due_date=None,
                        due_time=None, status="open", source="capture",
                        created_at="2026-06-29T08:00:00", updated_at="2026-06-29T08:00:00"))
    store.set_meta("item_seq", "1")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")
    svc.handle(msg("did the first one"))

    out = svc.handle(msg("what did i finish today", message_id=2))
    assert "done:" in out and "prez" in out


def test_capture_with_priority_then_reprioritize():
    llm = FakeLlm([
        {"actions": [{"type": "capture", "task": "call plumber",
                      "raw": "call plumber urgent", "priority": "high"}]},
        {"actions": [{"type": "prioritize", "target": "1", "level": "low"}]},
    ])
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    out1 = svc.handle(msg("call the plumber, it's urgent"))
    assert "urgent" in out1
    it = store.open_items()[0]
    assert it.priority == "high"

    out2 = svc.handle(msg("actually the plumber can wait", message_id=2))
    assert 'marked "call plumber" low priority' in out2
    assert store.get_item(it.id).priority == "low"


def test_tags_capture_and_query():
    llm = FakeLlm([
        {"actions": [
            {"type": "capture", "task": "book caterer", "raw": "book caterer", "tag": "wedding"},
            {"type": "capture", "task": "order flowers", "raw": "order flowers", "tag": "wedding"},
        ]},
        {"actions": [{"type": "query", "kind": "tag", "tag": "wedding"}]},
    ])
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    svc.handle(msg("for the wedding: book the caterer, order flowers"))
    assert {i.tag for i in store.open_items()} == {"wedding"}

    out = svc.handle(msg("what's left for the wedding", message_id=2))
    assert 'for "wedding":' in out and "book caterer" in out and "order flowers" in out


def test_setting_wake_time_persists_and_scheduler_reads_it():
    from adapters.scheduler import DigestScheduler, WAKE_TIME_KEY

    llm = FakeLlm({"actions": [{
        "type": "setting", "key": "wake_time", "raw": "6:30", "time": "06:30",
    }]})
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    out = svc.handle(msg("send the morning digest at 6:30"))
    assert "06:30" in out
    assert store.get_meta(WAKE_TIME_KEY) == "06:30"

    # the scheduler reads the override, not the configured default
    sched = DigestScheduler(clock, store, fire=lambda: True, wake_time="07:00")
    assert sched._wake_time() == "06:30"


def test_setting_is_undoable_in_same_batch_as_task_changes():
    llm = FakeLlm(
        {
            "actions": [
                {"type": "capture", "task": "buy milk", "raw": "buy milk"},
                {"type": "setting", "key": "wake_time", "raw": "6:30", "time": "06:30"},
            ]
        }
    )
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    svc.handle(msg("buy milk and send my digest at 6:30"))
    assert store.open_items()[0].task == "buy milk"
    assert store.get_meta("wake_time") == "06:30"
    assert "2 change" in svc.handle(msg("/undo", message_id=2))
    assert store.open_items() == []
    assert store.get_meta("wake_time") is None


def test_invalid_setting_question_is_resumable():
    llm = FakeLlm(
        [
            {"actions": [{"type": "setting", "key": "wake_time", "raw": "whenever"}]},
            {"actions": [{"type": "setting", "key": "wake_time", "raw": "8am", "time": "08:00"}]},
        ]
    )
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    assert "what time" in svc.handle(msg("change the digest time"))
    assert store.get_meta("pending")
    out = svc.handle(msg("8am", message_id=2))
    assert any("Pending question" in prompt for prompt, _, _ in llm.calls)
    assert "08:00" in out and store.get_meta("wake_time") == "08:00"


def test_work_hours_and_break_are_chat_configurable_and_undoable():
    llm = FakeLlm(
        {
            "actions": [
                    {"type": "setting", "key": "work_hours", "raw": "9 to 5", "start_time": "09:00", "end_time": "17:00"},
                    {"type": "setting", "key": "work_days", "raw": "Monday through Saturday", "days": ["mon", "tue", "wed", "thu", "fri", "sat"]},
                    {"type": "setting", "key": "break_window", "raw": "noon to 1", "start_time": "12:00", "end_time": "13:00"},
            ]
        }
    )
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")
    out = svc.handle(msg("plan Monday through Saturday from 9 to 5 and protect lunch noon to 1"))
    assert "09:00-17:00" in out and "12:00-13:00" in out and "mon,tue" in out
    assert store.get_meta("work_hours") == "09:00-17:00"
    assert store.get_meta("work_days") == "mon,tue,wed,thu,fri,sat"
    assert store.get_meta("breaks") == "12:00-13:00"
    settings = svc.handle(msg("/settings", message_id=2))
    assert "planning hours: 09:00-17:00" in settings
    assert "planning days: mon,tue,wed,thu,fri,sat" in settings
    assert "protected breaks: 12:00-13:00" in settings
    assert "3 change" in svc.handle(msg("/undo", message_id=3))
    assert store.get_meta("work_hours") is None
    assert store.get_meta("breaks") is None
    assert store.get_meta("work_days") is None


def test_default_effort_and_buffer_are_visible_and_undoable_together():
    llm = FakeLlm({"actions": [
        {"type": "setting", "key": "default_duration", "raw": "45 minutes", "minutes": 45},
        {"type": "setting", "key": "transition_buffer", "raw": "10 minute", "minutes": 10},
    ]})
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")
    out = svc.handle(msg("assume 45 minutes and leave a 10 minute buffer"))
    assert "45 minutes" in out and "10 minutes" in out
    settings = svc.handle(msg("/settings", message_id=2))
    assert "default estimate: 45m" in settings
    assert "transition buffer: 10m" in settings
    assert "2 change" in svc.handle(msg("/undo", message_id=3))
    assert store.get_meta("default_duration") is None
    assert store.get_meta("transition_buffer") is None


def test_fresh_start_runs_resumable_guided_setup_to_completion():
    from app import (
        INSTALL_VERSION_KEY,
        ONBOARDING_DONE_KEY,
        ONBOARDING_STAGE_KEY,
        RELEASE_NOTICE_KEY,
    )
    from core.version import __version__

    llm = FakeLlm([
        {"actions": [{"type": "setting", "key": "work_hours", "raw": "9 to 5", "start_time": "09:00", "end_time": "17:00"}]},
        {"outcome": "other", "confidence": 1.0},
        {"actions": [{"type": "setting", "key": "work_days", "raw": "weekdays", "days": ["mon", "tue", "wed", "thu", "fri"]}]},
        {"outcome": "other", "confidence": 1.0},
        {"actions": [{"type": "setting", "key": "break_window", "raw": "no break", "clear": True}]},
        {"outcome": "other", "confidence": 1.0},
        {"actions": [{"type": "setting", "key": "default_duration", "raw": "45 minutes", "minutes": 45}]},
        {"outcome": "other", "confidence": 1.0},
        {"actions": [{"type": "setting", "key": "transition_buffer", "raw": "10 minutes", "minutes": 10}]},
        {"outcome": "other", "confidence": 1.0},
    ])
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    start = svc.handle(InboundMessage("/start", 10, 1, 1, user_id=42))
    assert "setup 1/5" in start and store.get_meta(ONBOARDING_STAGE_KEY) == "work_hours"
    assert store.get_meta("pending")
    assert store.get_meta(INSTALL_VERSION_KEY) == __version__
    assert store.get_meta(RELEASE_NOTICE_KEY) == __version__

    first = svc.handle(InboundMessage("plan work from 9 to 5", 10, 2, 2, user_id=42))
    assert "setup 2/5" in first and store.get_meta("work_hours") == "09:00-17:00"
    second = svc.handle(InboundMessage("weekdays", 10, 3, 3, user_id=42))
    assert "setup 3/5" in second and store.get_meta("work_days") == "mon,tue,wed,thu,fri"
    third = svc.handle(InboundMessage("no break", 10, 4, 4, user_id=42))
    assert "setup 4/5" in third and store.get_meta("breaks") == "none"
    fourth = svc.handle(InboundMessage("assume 45 minutes", 10, 5, 5, user_id=42))
    assert "setup 5/5" in fourth and store.get_meta("default_duration") == "45"
    done = svc.handle(InboundMessage("leave 10 minutes", 10, 6, 6, user_id=42))
    assert "setup complete" in done
    assert store.get_meta("transition_buffer") == "10"
    assert store.get_meta(ONBOARDING_DONE_KEY)
    assert store.get_meta(ONBOARDING_STAGE_KEY) == ""
    assert store.get_meta("pending") == ""
    settings = svc.handle(InboundMessage("/settings", 10, 7, 7, user_id=42))
    assert "default estimate: 45m" in settings
    assert "transition buffer: 10m" in settings
    assert "setup: complete" in settings
    assert "first plan: not yet" in settings


def test_setup_resumes_after_restart_and_can_skip_or_cancel():
    from app import ONBOARDING_STAGE_KEY

    store = SqliteStore(":memory:")
    store.set_meta("telegram_owner_user_id", "42")
    store.set_meta(ONBOARDING_STAGE_KEY, "break_window")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    restarted = MessageService(
        store,
        clock,
        FakeLlm({"actions": [{
            "type": "onboarding_decision", "decision": "skip", "confidence": 1.0,
        }]}),
        "America/New_York",
    )
    resumed = restarted.handle(InboundMessage("/setup", 10, 1, 1, user_id=42))
    assert "setup 3/5" in resumed
    skipped = restarted.handle(InboundMessage("skip", 10, 2, 2, user_id=42))
    assert "setup 4/5" in skipped
    restarted._llm = FakeLlm({"actions": [{
        "type": "onboarding_decision", "decision": "cancel", "confidence": 1.0,
    }]})
    canceled = restarted.handle(InboundMessage("cancel setup", 10, 3, 3, user_id=42))
    assert "setup paused" in canceled
    assert store.get_meta(ONBOARDING_STAGE_KEY) == "default_duration"
    assert store.get_meta("pending") == ""
    resumed_again = restarted.handle(InboundMessage("/setup", 10, 4, 4, user_id=42))
    assert "setup 4/5" in resumed_again


def test_workday_onboarding_skip_records_displayed_default():
    from app import INSTALL_VERSION_KEY, ONBOARDING_STAGE_KEY
    from core.version import __version__

    store = SqliteStore(":memory:")
    store.set_meta("telegram_owner_user_id", "42")
    store.set_meta(INSTALL_VERSION_KEY, __version__)
    store.set_meta(ONBOARDING_STAGE_KEY, "work_days")
    svc = MessageService(
        store,
        FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ)),
        FakeLlm({"actions": [{
            "type": "onboarding_decision", "decision": "skip", "confidence": 1.0,
        }]}),
        "America/New_York",
    )

    prompt = svc.handle(InboundMessage("/setup", 10, 1, 1, user_id=42))
    assert "keep mon,tue,wed,thu,fri" in prompt
    svc.handle(InboundMessage("skip", 10, 2, 2, user_id=42))
    assert store.get_meta("work_days") == "mon,tue,wed,thu,fri"


def test_upgraded_profile_keeps_all_days_until_owner_chooses():
    svc, store = service(FakeLlm({"actions": [{
        "type": "query", "kind": "outlook", "constraint": None,
    }]}))
    store.set_meta("telegram_owner_user_id", "42")

    settings = svc.handle(msg("/settings"))
    outlook = svc.handle(msg("am I overloaded this week?", 2))

    assert "planning days: mon,tue,wed,thu,fri,sat,sun (legacy all-days default" in settings
    assert "Sat 7/4:" in outlook and "not a planning day" not in outlook
    assert "keeps the prior all-days behavior" in outlook


def test_returning_owner_start_does_not_force_setup():
    store = SqliteStore(":memory:")
    store.set_meta("telegram_owner_user_id", "42")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, FakeLlm({"actions": []}), "America/New_York")
    out = svc.handle(InboundMessage("/start", 10, 1, 1, user_id=42))
    assert "hi, i am hob" in out and "setup 1/5" not in out


def test_recovery_commands_refuse_ambiguous_legacy_database(monkeypatch, tmp_path):
    from types import SimpleNamespace

    from app import _database_choice_error, _export_or_backup

    checkout = tmp_path / "checkout"
    home = tmp_path / "home"
    checkout.mkdir()
    app_data = home / "Library" / "Application Support" / "Hob" / "hob.db"
    app_data.parent.mkdir(parents=True)
    (checkout / "hob.db").touch()
    app_data.touch()
    monkeypatch.chdir(checkout)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.delenv("HOB_DB_PATH", raising=False)
    cfg = SimpleNamespace(db_path="hob.db")

    error = _database_choice_error(cfg)

    assert error and "set HOB_DB_PATH explicitly" in error
    destination = tmp_path / "must-not-be-written.db"
    assert _export_or_backup(cfg, ["backup", str(destination)]) == 2
    assert not destination.exists()
    monkeypatch.setenv("HOB_DB_PATH", "hob.db")
    assert _database_choice_error(cfg) is None


def test_plan_focus_positions_override_canonical_list_positions():
    from app import FOCUS_KEY

    svc, store = service(
        FakeLlm({"actions": [{"type": "start", "target": "2"}]})
    )
    store.set_meta(
        FOCUS_KEY,
        json.dumps({
            "ts": "2026-06-29T09:00:00-04:00",
            "items": [
                {"id": "a2", "label": "call the pool guy", "context": "plan"},
                {"id": "a3", "label": "review SR audit", "context": "plan"},
            ],
        }),
    )
    out = svc.handle(msg("do the second one"))
    assert "Last proposed plan" in svc._llm.calls[0][0]
    assert 'next: "review SR audit"' in out
    assert "not marked it done" in out
    assert store.get_item("a3").status == "open"
    assert store.get_item("a1").status == "open"


def test_followup_resolves_via_focus():
    # Turn 1 captures; turn 2's bare "make it 4pm" sees the captured item as the
    # conversational focus and reschedules it.
    llm = FakeLlm([
        {"actions": [{"type": "capture", "task": "call the vet", "raw": "call the vet"}]},
        {"actions": [{"type": "reschedule", "target": "a1", "time": "16:00"}]},
    ])
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    svc.handle(msg("call the vet"))
    out = svc.handle(msg("make it 4pm", message_id=2))

    assert any("Just discussed" in prompt for prompt, _, _ in llm.calls)
    assert "call the vet" in llm.calls[1][0]
    item = store.get_item("a1")
    assert item.due_time == "16:00"
    assert item.due_date == "2026-06-29"  # undated + time-only -> today
    assert 'moved "call the vet"' in out and "16:00" in out


def test_focus_expires_after_ttl():
    from app import FOCUS_KEY

    llm = FakeLlm({"actions": [{"type": "unknown"}]})
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")
    # A focus saved 20 minutes ago is stale and must not reach the prompt.
    store.set_meta(FOCUS_KEY, json.dumps(
        {"ts": "2026-06-29T08:40:00-04:00", "items": [{"id": "a1", "label": "x"}]}
    ))
    svc.handle(msg("make it 4pm"))
    assert "Just discussed" not in llm.calls[0][0]


def test_reply_to_reminder_anchors_and_snoozes():
    # Replying "snooze 20" to a reminder message anchors to that item.
    llm = FakeLlm({"actions": [{"type": "snooze", "target": "a1", "minutes": 20}]})
    store = SqliteStore(":memory:")
    store.add_item(Item(id="a1", raw_text="call bob", task="call bob",
                        due_date="2026-06-29", due_time="15:00", status="open",
                        source="capture", created_at="2026-06-29T08:00:00",
                        updated_at="2026-06-29T08:00:00"))
    store.set_meta("item_seq", "1")
    store.record_sent_ref(777, "a1")  # the reminder Hob sent
    clock = FakeClock(datetime(2026, 6, 29, 14, 55, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    out = svc.handle(InboundMessage(text="snooze 20", chat_id=1, message_id=9,
                                    update_id=9, reply_to=777))

    assert "REPLYING" in llm.calls[0][0] and "call bob" in llm.calls[0][0]
    item = store.get_item("a1")
    assert item.snooze_until == "2026-06-29T15:15"  # 14:55 + 20
    assert item.reminded is False
    assert "snoozed" in out and "15:15" in out


def test_edited_message_reinterprets():
    # The user edits "call vet at 3" to "call vet at 4": the old batch is
    # undone and the corrected text applied under the same message id.
    llm = FakeLlm([
        {"actions": [{"type": "capture", "task": "call vet", "raw": "call vet at 3pm",
                      "time": "15:00"}]},
        {"actions": [{"type": "capture", "task": "call vet", "raw": "call vet at 4pm",
                      "time": "16:00"}]},
    ])
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    svc.handle(msg("call vet at 3pm"))
    assert store.open_items()[0].due_time == "15:00"

    out = svc.handle(InboundMessage(text="call vet at 4pm", chat_id=1,
                                    message_id=1, update_id=2, edited=True))

    items = store.open_items()
    assert len(items) == 1  # replaced, not duplicated
    assert items[0].due_time == "16:00"
    assert out.startswith("took the edit")


def test_edited_message_restores_original_when_model_is_down():
    class Down:
        def complete_json(self, prompt, schema, temperature=0.0):
            raise RuntimeError("down")

    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    first = MessageService(
        store,
        clock,
        FakeLlm({"actions": [{"type": "capture", "task": "call vet", "raw": "call vet", "time": "15:00"}]}),
        "America/New_York",
    )
    first.handle(msg("call vet at 3pm"))

    down = MessageService(store, clock, Down(), "America/New_York")
    out = down.handle(
        InboundMessage(
            text="call vet at 4pm",
            chat_id=1,
            message_id=1,
            update_id=2,
            edited=True,
        )
    )
    assert "can't reach the model" in out
    items = store.open_items()
    assert len(items) == 1 and items[0].due_time == "15:00"


def test_note_then_wait_then_resume():
    llm = FakeLlm([
        {"actions": [{"type": "note", "target": "a2", "text": "gate code 4412"}]},
        {"actions": [{"type": "wait", "target": "a2"}]},
        {"actions": [{"type": "resume", "target": "a2"}]},
    ])
    svc, store = service(llm)

    out1 = svc.handle(msg("add a note to the pool one: gate code 4412"))
    assert 'noted on "call the pool guy": gate code 4412' in out1
    assert store.get_item("a2").note == "gate code 4412"

    out2 = svc.handle(msg("the pool guy is waiting on a callback", message_id=2))
    assert "parked" in out2
    assert store.get_item("a2").waiting_since == "2026-06-29"

    out3 = svc.handle(msg("pool guy called back", message_id=3))
    assert 'back on: "call the pool guy"' in out3
    assert store.get_item("a2").waiting_since is None


def test_forwarded_message_context_reaches_prompt():
    llm = FakeLlm({"actions": [{"type": "capture", "task": "grab milk",
                                "raw": "grab milk", "note": "from Sarah"}]})
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    out = svc.handle(InboundMessage(text="can you grab milk", chat_id=1,
                                    message_id=1, update_id=1,
                                    forwarded_from="Sarah"))

    assert "FORWARDED" in llm.calls[0][0] and "Sarah" in llm.calls[0][0]
    assert store.open_items()[0].note == "from Sarah"
    assert "from Sarah" in out


def test_reaction_completes_and_ignores_unmapped():
    llm = FakeLlm({"actions": []})
    store = SqliteStore(":memory:")
    store.add_item(Item(id="a1", raw_text="call bob", task="call bob",
                        due_date="2026-06-29", due_time="15:00", status="open",
                        source="capture", created_at="2026-06-29T08:00:00",
                        updated_at="2026-06-29T08:00:00"))
    store.set_meta("item_seq", "1")
    store.record_sent_ref(777, "a1")
    clock = FakeClock(datetime(2026, 6, 29, 15, 5, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    assert svc.handle_reaction(999, ["❤"]) == ""  # heart on chit-chat: ignored
    out = svc.handle_reaction(777, ["\U0001F44D"])  # thumbs up the reminder
    assert 'done: "call bob"' in out
    assert store.get_item("a1").status == "done"
    assert svc.handle_reaction(777, ["\U0001F44D"]) == ""  # idempotent


def test_inline_item_and_confirmation_callbacks_are_deterministic():
    svc, store = service(FakeLlm({"actions": []}))
    out = svc.handle_callback("cb1", "hob:item:a1:complete", None, 1)
    assert 'done: "org prez"' in out
    assert store.get_item("a1").status == "done"
    assert svc.handle_callback("cb1", "hob:item:a1:complete", None, 1) == ""

    store.set_meta(
        "pending_confirm",
        json.dumps([{"kind": "drop", "target": "a2"}]),
    )
    canceled = svc.handle_callback("cb2", "hob:confirm:no", None, 1)
    assert "canceled" in canceled and store.get_item("a2").status == "open"

    store.set_meta(
        "pending_confirm",
        json.dumps([{"kind": "drop", "target": "a2"}]),
    )
    confirmed = svc.handle_callback("cb3", "hob:confirm:yes", None, 1)
    assert 'dropped: "call the pool guy"' in confirmed

    store.set_meta(
        "pending_confirm",
        json.dumps(
            {
                "id": "new-turn",
                "mutations": [{"kind": "drop", "target": "a3"}],
            }
        ),
    )
    stale = svc.handle_callback(
        "cb4", "hob:confirm:yes:old-turn", None, 1
    )
    assert "expired" in stale
    assert store.get_meta("pending_confirm")  # current confirmation remains live


def test_set_profile_photo_once():
    import asyncio

    from app import AVATAR_KEY, AVATAR_PATH, AVATAR_VERSION, _set_profile_photo_once

    class FakeTG:
        def __init__(self):
            self.calls = []

        async def set_profile_photo(self, path):
            self.calls.append(path)
            return True

    store = SqliteStore(":memory:")
    tg = FakeTG()
    assert asyncio.run(_set_profile_photo_once(tg, store)) is True
    assert tg.calls == [AVATAR_PATH]
    assert store.get_meta(AVATAR_KEY) == AVATAR_VERSION
    # already set: a no-op, no second API call
    assert asyncio.run(_set_profile_photo_once(tg, store)) is False
    assert len(tg.calls) == 1


def test_chitchat_reply_generated_hot_classification_cold():
    # Pass 1 classifies chitchat at temp 0; pass 2 writes the reply hot, so
    # repeats vary. The pass-2 reply is used; on the fallback path the classified
    # reply stands.
    llm = FakeLlm([
        {"actions": [{"type": "chitchat", "reply": "anytime!"}]},
        {"reply": "aw shucks, happy to help"},
    ])
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    out = svc.handle(msg("thanks hob"))
    assert out == "aw shucks, happy to help"
    assert len(llm.calls) == 2
    assert llm.calls[0][2] == 0.0  # classification is deterministic
    assert llm.calls[1][2] > 0.0   # reply is generated hot


def test_pleasantry_gets_warm_reply_not_nag():
    llm = FakeLlm({"actions": [{"type": "chitchat", "reply": "anytime!"}]})
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    out = svc.handle(msg("thanks bud"))
    assert out == "anytime!"
    assert "rephrase" not in out


def test_owner_pairing_rejects_other_users_without_rebinding_digest():
    llm = FakeLlm({"actions": [{"type": "capture", "task": "x", "raw": "x"}]})
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    welcome = svc.handle(
        InboundMessage("/start", 10, 1, 1, user_id=42)
    )
    assert "hob" in welcome and store.get_meta("telegram_owner_user_id") == "42"
    denied = svc.handle(
        InboundMessage("steal the digest", 99, 1, 2, user_id=7)
    )
    assert "already paired" in denied
    assert store.get_meta("chat_id") == "10"
    assert store.open_items() == []

    group = svc.handle(
        InboundMessage(
            "hello group",
            77,
            2,
            3,
            user_id=42,
            chat_type="group",
        )
    )
    assert "private chat" in group
    assert store.get_meta("chat_id") == "10"


def test_plan_my_day_is_reasoned_read_only_and_validates_ids():
    llm = FakeLlm(
        [
            {"actions": [{"type": "query", "kind": "plan", "constraint": "40 minutes, low energy"}]},
            {
                "headline": "start small, then protect the deadline",
                "picks": [
                    {"id": "a2", "reason": "a quick call fits the energy available"},
                    {"id": "made-up", "reason": "hallucinated and must be ignored"},
                    {"id": "a3", "reason": "the audit is already overdue"},
                ],
            },
        ]
    )
    svc, store = service(llm)
    before = [i.to_dict() for i in store.open_items()]

    out = svc.handle(msg("I have 40 minutes and low energy; what should I do?"))

    assert "plan: start small" in out
    assert "call the pool guy" in out and "review SR audit" in out
    assert "made-up" not in out
    assert [i.to_dict() for i in store.open_items()] == before
    focus = json.loads(store.get_meta("focus"))
    assert focus["items"] and focus["items"][0]["context"] == "plan"


def test_week_outlook_is_read_only_uses_profile_days_and_checks_each_calendar_day():
    from core.feasibility import CalendarSnapshot

    class Calendar:
        def __init__(self):
            self.calls = []

        def snapshot(self, start, end):
            self.calls.append((start, end))
            return CalendarSnapshot("authorized")

    calendar = Calendar()
    llm = FakeLlm({"actions": [{
        "type": "query", "kind": "outlook", "constraint": "mornings only"
    }]})
    svc, store = service(llm)
    svc._calendar = calendar
    before = [item.to_dict() for item in store.open_items()]

    out = svc.handle(msg("am I overloaded this week if mornings are all I have?"))

    assert "week outlook" in out and "read-only load test" in out
    assert "Sat 7/4: not a planning day" in out
    assert "calendar: 7/7 day(s) checked" in out
    assert len(calendar.calls) == 7
    assert [item.to_dict() for item in store.open_items()] == before
    assert store.last_batch() == []


def test_outlook_by_friday_uses_friday_as_the_capacity_boundary():
    from core.feasibility import CalendarSnapshot

    class Calendar:
        def __init__(self):
            self.calls = []

        def snapshot(self, start, end):
            self.calls.append((start, end))
            return CalendarSnapshot("authorized")

    calendar = Calendar()
    llm = FakeLlm({"actions": [{
        "type": "query",
        "kind": "outlook",
        "when": {"kind": "weekday", "day": "fri"},
        "constraint": "by Friday",
    }]})
    svc, _ = service(llm)
    svc._calendar = calendar

    out = svc.handle(msg("can I finish everything by Friday?"))

    assert "week outlook 2026-06-29 to 2026-07-03" in out
    assert "calendar: 5/5 day(s) checked" in out
    assert len(calendar.calls) == 5


def test_plan_my_day_uses_injected_calendar_availability():
    from core.feasibility import BusyPeriod, CalendarSnapshot

    class Calendar:
        def snapshot(self, start, end):
            assert start.hour == 0 and end.date() > start.date()
            return CalendarSnapshot(
                "authorized",
                [BusyPeriod(
                    datetime(2026, 6, 29, 9, 0, tzinfo=TZ),
                    datetime(2026, 6, 29, 10, 0, tzinfo=TZ),
                )],
            )

    llm = FakeLlm([
        {"actions": [{"type": "query", "kind": "plan"}]},
        {"headline": "start after the busy block", "picks": [
            {"id": "a1", "reason": "it fits the first real opening"}
        ]},
    ])
    store = SqliteStore(":memory:")
    store.add_item(Item(
        id="a1", raw_text="write brief", task="write brief", due_date=None,
        due_time=None, status="open", source="capture",
        created_at="2026-06-29T08:00:00", updated_at="2026-06-29T08:00:00",
        duration_minutes=30,
    ))
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(
        store, clock, llm, "America/New_York", calendar=Calendar(), breaks=()
    )
    out = svc.handle(msg("plan my day"))
    assert "10:00–10:30 write brief" in out
    assert "calendar checked: 1 busy block" in out
    assert any("Feasible timeline" in prompt for prompt, _, _ in llm.calls)


def test_split_plan_numbers_tasks_not_segments():
    from core.feasibility import BusyPeriod, CalendarSnapshot

    class Calendar:
        def snapshot(self, start, end):
            return CalendarSnapshot("authorized", [
                BusyPeriod(
                    datetime(2026, 6, 29, 10, 0, tzinfo=TZ),
                    datetime(2026, 6, 29, 11, 0, tzinfo=TZ),
                ),
                BusyPeriod(
                    datetime(2026, 6, 29, 11, 30, tzinfo=TZ),
                    datetime(2026, 6, 29, 17, 30, tzinfo=TZ),
                ),
            ])

    llm = FakeLlm([
        {"actions": [{"type": "query", "kind": "plan"}]},
        {"headline": "two focused passes", "picks": []},
    ])
    store = SqliteStore(":memory:")
    store.add_item(Item(
        id="a1", raw_text="draft report", task="draft report", due_date=None,
        due_time=None, status="open", source="capture",
        created_at="2026-06-29T08:00:00", updated_at="2026-06-29T08:00:00",
        duration_minutes=90, splittable=True,
    ))
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(
        store, clock, llm, "America/New_York", calendar=Calendar(), breaks=()
    )
    out = svc.handle(msg("plan my day"))
    assert "1: 09:00–10:00 draft report" in out
    assert "↳ 11:00–11:30 draft report" in out
    assert "2:" not in out
    focus = json.loads(store.get_meta("focus"))
    assert [entry["id"] for entry in focus["items"]] == ["a1"]
    proposal = store.latest_proposed_plan("2026-06-29")
    assert proposal is not None
    assert [session.segment for session in store.plan_sessions(proposal.id)] == [1, 2]


def test_future_plan_can_be_adopted_run_completed_and_undone():
    llm = FakeLlm([
        {"actions": [{
            "type": "query",
            "kind": "plan",
            "when": {"kind": "tomorrow"},
            "constraint": "plan tomorrow",
        }]},
        {"headline": "a clean tomorrow", "picks": []},
        {"actions": [{"type": "plan_action", "op": "adopt", "confidence": 1.0}]},
        {"actions": [{"type": "complete", "target": "a1", "confidence": 1.0}]},
    ])
    store = SqliteStore(":memory:")
    store.add_item(Item(
        id="a1", raw_text="write brief", task="write brief",
        due_date="2026-06-30", due_time="09:00", status="open",
        source="capture", created_at="2026-06-29T08:00:00",
        updated_at="2026-06-29T08:00:00", duration_minutes=30,
        schedule_kind="fixed",
    ))
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York", breaks=())

    proposal_text = svc.handle(msg("plan tomorrow", 1))
    proposal = store.latest_proposed_plan("2026-06-30")
    assert "plan for 2026-06-30" in proposal_text
    assert proposal is not None and store.active_plan("2026-06-30") is None
    assert store.get_item("a1").due_date == "2026-06-30"

    adopted = svc.handle(msg("use this plan", 2))
    assert "adopted" in adopted and "tasks and calendar are unchanged" in adopted
    assert "first-run tip" in adopted and "replace my plan with this" in adopted
    assert store.active_plan("2026-06-30").id == proposal.id
    assert store.get_meta("first_plan_adopted_at")
    assert svc.handle(msg("use this plan", 2)) == ""
    status = svc.handle(msg("/plan", 20))
    assert "adopted plan for 2026-06-30" in status
    assert "09:00–09:30 write brief" in status

    clock.set(datetime(2026, 6, 30, 9, 5, tzinfo=TZ))
    done = svc.handle(msg("finished the brief", 3))
    assert 'done: "write brief"' in done
    assert store.get_plan_run(proposal.id).status == "completed"
    assert store.plan_sessions(proposal.id)[0].status == "done"
    assert "undid 1" in svc.handle(msg("/undo", 4))
    assert store.get_item("a1").status == "open"
    assert store.get_plan_run(proposal.id).status == "active"
    assert store.plan_sessions(proposal.id)[0].status == "planned"


def test_active_plan_requires_explicit_replacement_and_cancel_is_undoable():
    llm = FakeLlm([
        {"actions": [{"type": "query", "kind": "plan"}]},
        {"headline": "first pass", "picks": []},
        {"actions": [{"type": "plan_action", "op": "adopt", "confidence": 1.0}]},
        {"actions": [{"type": "query", "kind": "plan", "constraint": "start at 10"}]},
        {"headline": "revised pass", "picks": []},
        {"actions": [{"type": "plan_action", "op": "adopt", "confidence": 1.0}]},
        {"actions": [{"type": "plan_action", "op": "replace", "confidence": 1.0}]},
        {"actions": [{"type": "plan_action", "op": "cancel", "confidence": 1.0}]},
    ])
    svc, store = service(llm)
    svc.handle(msg("plan my day", 1))
    svc.handle(msg("use this plan", 2))
    original = store.active_plan("2026-06-29")
    store.set_meta("focus", "")
    expected_focus = list(dict.fromkeys(
        session.item_id for session in store.plan_sessions(original.id)
    ))
    assert [entry["id"] for entry in svc._context("start the second one").focus] == expected_focus
    svc.handle(msg("replan, start at 10", 3))
    proposal = store.latest_proposed_plan("2026-06-29")
    refused = svc.handle(msg("use this plan", 4))
    assert "already have an adopted plan" in refused
    assert store.active_plan("2026-06-29").id == original.id
    replaced = svc.handle(msg("replace my plan with this", 5))
    assert "replaced" in replaced
    assert "first-run tip" not in replaced
    assert store.active_plan("2026-06-29").id == proposal.id
    canceled = svc.handle(msg("cancel my plan", 6))
    assert "canceled" in canceled and store.active_plan("2026-06-29") is None
    assert "undid 1" in svc.handle(msg("/undo", 7))
    assert store.active_plan("2026-06-29").id == proposal.id


def test_semantic_search_validates_model_selected_ids():
    llm = FakeLlm(
        [
            {"actions": [{"type": "query", "kind": "search", "term": "doctor"}]},
            {"matches": ["a4", "invented"]},
        ]
    )
    svc, store = service(llm)
    store.add_item(
        Item(
            id="a4",
            raw_text="annual physical",
            task="book annual physical",
            due_date=None,
            due_time=None,
            status="open",
            source="capture",
            created_at="2026-06-29T08:30:00",
            updated_at="2026-06-29T08:30:00",
            note="primary care",
        )
    )
    out = svc.handle(msg("anything about the doctor?"))
    assert "book annual physical" in out and "invented" not in out


def test_amend_edits_item_text():
    llm = FakeLlm({"actions": [{"type": "amend", "target": "a1", "task": "prep the Q3 deck"}]})
    svc, store = service(llm)

    out = svc.handle(msg("change the prez task to prep the Q3 deck"))

    assert store.get_item("a1").task == "prep the Q3 deck"
    assert 'updated: "prep the Q3 deck"' in out


def test_capture_relate_inherits_date_end_to_end():
    llm = FakeLlm(
        {"actions": [{"type": "capture", "task": "bring soda", "raw": "bring soda",
                      "relate": "a3"}]}
    )
    svc, store = service(llm)  # a3 is due 2026-06-28

    out = svc.handle(msg("Shelly asked me to bring soda too"))

    soda = [i for i in store.open_items() if i.task == "bring soda"][0]
    assert soda.due_date == "2026-06-28"  # inherited a3's date
    assert 'got it: "bring soda" for 2026-06-28' in out


def test_far_future_capture_confirms_then_applies():
    llm = FakeLlm([
        {"actions": [{"type": "capture", "task": "take out the trash",
                      "raw": "take out the trash in 200 years",
                      "when": {"kind": "offset", "n": 200, "unit": "year"}}]},
        {"actions": [{"type": "confirmation_decision", "decision": "approve"}]},
        {"outcome": "approve", "confidence": 1.0},
    ])
    svc, store = service(llm)

    out = svc.handle(msg("in 200 years I need to take out the trash"))
    assert "years out" in out and "confirm" in out.lower()
    assert not any(i.task == "take out the trash" for i in store.open_items())

    out2 = svc.handle(msg("yes", message_id=2))
    kept = [i for i in store.open_items() if i.task == "take out the trash"][0]
    assert kept.due_date == "2226-06-29"  # confirmed, kept the far date
    assert "got it" in out2.lower()


def test_bulk_drop_across_days_confirms_then_applies():
    llm = FakeLlm([
        {"actions": [{"type": "bulk", "op": "drop", "scope": "all"}]},
        {"scope": "all", "confidence": 1.0},
        {"actions": [{"type": "confirmation_decision", "decision": "approve"}]},
        {"outcome": "approve", "confidence": 1.0},
    ])
    svc, store = service(llm)  # seed spans undated items + a3 on 2026-06-28

    out = svc.handle(msg("delete everything"))
    assert "confirm" in out.lower()
    assert len(store.open_items()) == 3  # nothing dropped yet

    out2 = svc.handle(msg("yes", message_id=2))
    assert store.open_items() == []  # confirmed -> all cleared
    assert "dropped" in out2


def test_bulk_confirm_cancelled_by_non_yes():
    # A non-affirmation cancels the pending delete and is handled as a new message.
    llm = FakeLlm(
        [
            {"actions": [{"type": "bulk", "op": "drop", "scope": "all"}]},
            {"scope": "all", "confidence": 1.0},
            {"actions": [{"type": "capture", "task": "buy milk", "raw": "buy milk"}]},
            {"outcome": "other", "confidence": 1.0},
        ]
    )
    svc, store = service(llm)

    svc.handle(msg("delete everything"))
    out = svc.handle(msg("actually buy milk", message_id=2))

    assert len(store.open_items()) == 4  # nothing dropped; milk captured
    assert "got it" in out.lower()


def test_eod_that_list_reschedule_cannot_move_unpresented_tasks():
    llm = FakeLlm([{
        "actions": [
            {
                "type": "bulk",
                "op": "reschedule",
                "scope": "presented",
                "when": {"kind": "weekday", "which": "next", "day": "mon"},
                "except": ["a3"],
            },
            {
                "type": "reschedule",
                "target": "a3",
                "when": {"kind": "weekday", "which": "next", "day": "sun"},
            },
        ]
    }, {"scope": "presented", "confidence": 1.0}])
    svc, store = service(llm)
    for task_id, label, due in (
        ("a4", "hit the grift", "2026-07-10"),
        ("a5", "remind mortgage home insurance", "2026-07-12"),
    ):
        store.add_item(Item(
            id=task_id,
            raw_text=label,
            task=label,
            due_date=due,
            due_time=None,
            status="open",
            source="capture",
            created_at="2026-06-29T08:00:00-04:00",
            updated_at="2026-06-29T08:00:00-04:00",
        ))
    store.set_meta("item_seq", "5")
    store.set_meta(
        "last_presented_list",
        json.dumps({
            "ts": "2026-06-29T09:00:00-04:00",
            "kind": "eod",
            "items": [
                {"id": "a1", "label": "org prez"},
                {"id": "a2", "label": "call the pool guy"},
                {"id": "a3", "label": "review SR audit"},
            ],
        }),
    )

    svc.handle(msg(
        "Move everything on that list to Monday except the audit, "
        "that goes to Sunday"
    ))

    assert store.get_item("a1").due_date == "2026-07-06"
    assert store.get_item("a2").due_date == "2026-07-06"
    assert store.get_item("a3").due_date == "2026-07-05"
    assert store.get_item("a4").due_date == "2026-07-10"
    assert store.get_item("a5").due_date == "2026-07-12"


def test_query_today_lists_items():
    llm = FakeLlm({"actions": [{"type": "query", "kind": "today"}]})
    svc, store = service(llm)

    out = svc.handle(msg("what's on today?"))

    assert "today:" in out
    assert "1: review SR audit" in out  # overdue rolls in first


def test_status_reports_execution_evidence_without_private_text(
    tmp_path, monkeypatch, capsys
):
    from types import SimpleNamespace

    import app

    db = tmp_path / "hob.db"
    with SqliteStore(str(db)) as store:
        store.add_item(Item(
            id="a1",
            raw_text="secret task label",
            task="secret task label",
            due_date=None,
            due_time=None,
            status="open",
            source="capture",
            created_at="2026-07-11T08:00:00",
            updated_at="2026-07-11T08:00:00",
        ))
        store.save_plan_run(
            PlanRun(
                "p1", "2026-07-11", "proposed", "private constraint",
                "2026-07-11T08:00:00",
            ),
            [PlanSession(
                "p1:s1", "p1", "a1", "secret task label",
                "2026-07-11T09:00:00", "2026-07-11T09:30:00",
            )],
        )
        store.adopt_plan("p1", "2026-07-11T08:05:00")
        store.set_meta("first_plan_adopted_at", "2026-07-11T08:05:00")
    cfg = SimpleNamespace(
        db_path=str(db),
        telegram_token_source="test",
        allowed_telegram_user_id=None,
        work_start="09:00",
        work_end="17:30",
        work_days=(0, 1, 2, 3, 4),
        default_duration_minutes=30,
        transition_buffer_minutes=0,
        model="test-model",
        ollama_host="http://localhost:11434",
        calendar_bridge="",
        calendar_enabled=False,
    )
    monkeypatch.setattr(app, "_model_ready", lambda llm, model: True)
    monkeypatch.setattr(
        app,
        "EventKitCalendar",
        lambda *args: SimpleNamespace(
            status=lambda: SimpleNamespace(status="disabled")
        ),
    )

    assert app._status(cfg) == 0
    output = capsys.readouterr().out
    assert "first_plan=yes adopted_runs=1" in output
    assert "runs=active:1" in output and "states=planned:1" in output
    assert "secret" not in output and "private constraint" not in output
