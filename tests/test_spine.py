# SPDX-License-Identifier: MIT
"""The spine end to end: one message, several actions, through MessageService.

Every inbound message (captures, EOD reports, corrections, queries) takes the
same path: interpret -> reconcile -> apply.
"""
import json
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

    assert 'did you mean: "org prez"' in out
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
    assert "Pending question" in llm.calls[1][0]  # follow-up prompt carried it
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

    llm = FakeLlm({"actions": [{"type": "setting", "key": "wake_time", "raw": "6:30"}]})
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    out = svc.handle(msg("send the morning digest at 6:30"))
    assert "06:30" in out
    assert store.get_meta(WAKE_TIME_KEY) == "06:30"

    # the scheduler reads the override, not the configured default
    sched = DigestScheduler(clock, store, fire=lambda: True, wake_time="07:00")
    assert sched._wake_time() == "06:30"


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

    assert "Just discussed" in llm.calls[1][0]  # focus reached the prompt
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


def test_pleasantry_gets_warm_reply_not_nag():
    llm = FakeLlm({"actions": [{"type": "chitchat", "reply": "anytime!"}]})
    store = SqliteStore(":memory:")
    clock = FakeClock(datetime(2026, 6, 29, 9, 0, tzinfo=TZ))
    svc = MessageService(store, clock, llm, "America/New_York")

    out = svc.handle(msg("thanks bud"))
    assert out == "anytime!"
    assert "rephrase" not in out


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
    llm = FakeLlm(
        {"actions": [{"type": "capture", "task": "take out the trash",
                      "raw": "take out the trash in 200 years",
                      "when": {"kind": "offset", "n": 200, "unit": "year"}}]}
    )
    svc, store = service(llm)

    out = svc.handle(msg("in 200 years I need to take out the trash"))
    assert "years out" in out and "yes" in out.lower()
    assert not any(i.task == "take out the trash" for i in store.open_items())

    out2 = svc.handle(msg("yes", message_id=2))
    kept = [i for i in store.open_items() if i.task == "take out the trash"][0]
    assert kept.due_date == "2226-06-29"  # confirmed, kept the far date
    assert "got it" in out2.lower()


def test_bulk_drop_across_days_confirms_then_applies():
    llm = FakeLlm({"actions": [{"type": "bulk", "op": "drop", "scope": "all"}]})
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
            {"actions": [{"type": "capture", "task": "buy milk", "raw": "buy milk"}]},
        ]
    )
    svc, store = service(llm)

    svc.handle(msg("delete everything"))
    out = svc.handle(msg("actually buy milk", message_id=2))

    assert len(store.open_items()) == 4  # nothing dropped; milk captured
    assert "got it" in out.lower()


def test_query_today_lists_items():
    llm = FakeLlm({"actions": [{"type": "query", "kind": "today"}]})
    svc, store = service(llm)

    out = svc.handle(msg("what's on today?"))

    assert "today:" in out
    assert "1: review SR audit" in out  # overdue rolls in first
