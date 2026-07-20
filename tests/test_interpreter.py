# SPDX-License-Identifier: MIT
"""Interpreter: canned model JSON in, parsed Actions out, graceful on garbage."""
from core.interpreter import MODEL_UNREACHABLE, build_prompt, interpret, parse_actions
from core.models import (
    Amend,
    Bulk,
    Capture,
    Chitchat,
    Complete,
    Drop,
    InterpreterContext,
    PlanAction,
    Query,
    Recap,
    Reschedule,
    Unknown,
)
from tests.fakes import FakeLlm


def ctx(message="x", active=None):
    return InterpreterContext(
        message=message,
        today="2026-06-29",
        now="2026-06-29T09:00:00",
        timezone="America/New_York",
        active_items=active or [],
        last_digest=[],
    )


def test_interpret_capture():
    llm = FakeLlm(
        {"actions": [{"type": "capture", "task": "org prez", "raw": "org prez Monday",
                      "confidence": 0.9}]}
    )
    actions = interpret(llm, ctx("org prez Monday"))
    assert len(actions) == 1
    assert isinstance(actions[0], Capture)
    assert actions[0].task == "org prez"
    assert actions[0].raw == "org prez Monday"


def test_interpret_multiple_captures():
    llm = FakeLlm(
        {"actions": [{"type": "capture", "task": "a", "raw": "a"},
                     {"type": "capture", "task": "b", "raw": "b"}]}
    )
    assert len(interpret(llm, ctx())) == 2


def test_model_call_failure_falls_back_to_unknown():
    class Boom:
        def complete_json(self, prompt, schema):
            raise RuntimeError("model timeout")

    actions = interpret(Boom(), ctx())
    assert len(actions) == 1 and isinstance(actions[0], Unknown)
    assert actions[0].note == MODEL_UNREACHABLE


def test_malformed_missing_actions_array():
    assert isinstance(parse_actions({"foo": 1})[0], Unknown)


def test_malformed_non_object_response():
    assert isinstance(parse_actions("garbage")[0], Unknown)


def test_action_missing_type_is_unknown():
    assert isinstance(parse_actions({"actions": [{"task": "x"}]})[0], Unknown)


def test_plan_action_and_plan_status_parse_as_typed_actions():
    actions = parse_actions({"actions": [
        {"type": "plan_action", "op": "replace", "confidence": 0.9},
        {"type": "query", "kind": "plan_status"},
    ]})
    assert isinstance(actions[0], PlanAction) and actions[0].op == "replace"
    assert isinstance(actions[1], Query) and actions[1].kind == "plan_status"


def test_outlook_query_preserves_what_if_constraint():
    action = parse_actions({"actions": [{
        "type": "query", "kind": "outlook", "constraint": "mornings only"
    }]})[0]
    assert isinstance(action, Query)
    assert action.kind == "outlook" and action.constraint == "mornings only"


def test_capture_uses_raw_when_task_missing():
    res = parse_actions({"actions": [{"type": "capture", "raw": "call mom"}]})
    assert isinstance(res[0], Capture) and res[0].task == "call mom"


def test_unhandled_type_is_unknown():
    res = parse_actions({"actions": [{"type": "frobnicate", "target": "a1"}]})
    assert isinstance(res[0], Unknown)


def test_parse_complete_drop_reschedule_query():
    res = parse_actions(
        {
            "actions": [
                {"type": "complete", "target": "a1", "confidence": 0.9},
                {"type": "drop", "target": "a2", "reason": "not happening"},
                {"type": "reschedule", "target": "a3", "when": {"kind": "weekday", "day": "fri"}},
                {"type": "query", "kind": "date", "when": {"kind": "tomorrow"}},
            ]
        }
    )
    assert isinstance(res[0], Complete) and res[0].target == "a1"
    assert isinstance(res[1], Drop) and res[1].reason == "not happening"
    assert isinstance(res[2], Reschedule) and res[2].when.day == "fri"
    assert isinstance(res[3], Query) and res[3].kind == "date"


def test_parse_typed_recap_outcome():
    action = parse_actions(
        {"actions": [{"type": "recap", "outcome": "none", "confidence": 0.9}]}
    )[0]
    assert isinstance(action, Recap)
    assert action.outcome == "none" and action.confidence == 0.9


def test_invalid_recap_outcome_is_unknown():
    action = parse_actions(
        {"actions": [{"type": "recap", "outcome": "all"}]}
    )[0]
    assert isinstance(action, Unknown)


def test_reference_action_without_target_is_unknown():
    assert isinstance(parse_actions({"actions": [{"type": "complete"}]})[0], Unknown)


def test_parse_capture_relate():
    res = parse_actions(
        {"actions": [{"type": "capture", "task": "bring soda", "raw": "bring soda",
                      "relate": "a7"}]}
    )
    assert isinstance(res[0], Capture) and res[0].relate == "a7"


def test_parse_amend():
    res = parse_actions(
        {"actions": [{"type": "amend", "target": "a2", "task": "prep Q3 deck"}]}
    )
    assert isinstance(res[0], Amend) and res[0].target == "a2"
    assert res[0].task == "prep Q3 deck"


def test_amend_without_text_is_unknown():
    assert isinstance(parse_actions({"actions": [{"type": "amend", "target": "a2"}]})[0], Unknown)


def test_parse_bulk():
    res = parse_actions({"actions": [{"type": "bulk", "op": "drop", "scope": "all"}]})
    assert isinstance(res[0], Bulk) and res[0].op == "drop" and res[0].scope == "all"


def test_bulk_invalid_op_is_unknown():
    res = parse_actions({"actions": [{"type": "bulk", "op": "frobnicate", "scope": "all"}]})
    assert isinstance(res[0], Unknown)


def test_prompt_includes_digest_positions():
    c = ctx()
    c.last_digest = [{"id": "a3", "label": "review audit"}, {"id": "a5", "label": "call pool"}]
    prompt = build_prompt(c)
    assert "1. a3: review audit" in prompt
    assert "2. a5: call pool" in prompt


def test_prompt_identifies_presented_evening_recap_context():
    c = ctx()
    c.presented_items = [{"id": "a1", "label": "call pool"}]
    c.presented_kind = "eod"
    prompt = build_prompt(c)
    assert "kind: evening recap" in prompt
    assert 'type "recap"' in prompt


def test_ambiguous_eod_answer_gets_model_semantic_adjudication():
    c = ctx("nada")
    c.presented_items = [{"id": "a1", "label": "call pool"}]
    c.presented_kind = "eod"
    llm = FakeLlm([
        {"actions": [{"type": "chitchat", "reply": "got it"}]},
        {"outcome": "none", "confidence": 0.94},
    ])

    action = interpret(llm, c)[0]

    assert isinstance(action, Recap)
    assert action.outcome == "none" and action.confidence == 0.94
    assert len(llm.calls) == 2
    assert "meaning in this conversational context" in llm.calls[1][0]


def test_eod_adjudication_preserves_actual_chitchat():
    c = ctx("thanks hob")
    c.presented_items = [{"id": "a1", "label": "call pool"}]
    c.presented_kind = "eod"
    llm = FakeLlm([
        {"actions": [{"type": "chitchat", "reply": "anytime"}]},
        {"outcome": "social", "confidence": 0.99},
    ])

    action = interpret(llm, c)[0]

    assert action.reply == "anytime"
    assert len(llm.calls) == 2


def test_eod_adjudication_corrects_direct_recap_false_positive():
    c = ctx("thanks hob")
    c.presented_items = [{"id": "a1", "label": "call pool"}]
    c.presented_kind = "eod"
    llm = FakeLlm([
        {"actions": [{"type": "recap", "outcome": "none", "confidence": 1.0}]},
        {"outcome": "social", "confidence": 0.99},
    ])

    action = interpret(llm, c)[0]

    assert isinstance(action, Chitchat)
    assert len(llm.calls) == 2


def test_eod_adjudication_rejects_unconfirmed_direct_recap():
    c = ctx("what is tomorrow's schedule?")
    c.presented_items = [{"id": "a1", "label": "call pool"}]
    c.presented_kind = "eod"
    llm = FakeLlm([
        {"actions": [{"type": "recap", "outcome": "none", "confidence": 1.0}]},
        {"outcome": "other", "confidence": 0.99},
    ])

    action = interpret(llm, c)[0]

    assert isinstance(action, Unknown)
    assert action.note == "recap outcome not confirmed"


def test_eod_adjudication_does_not_override_concrete_action():
    c = ctx("buy milk")
    c.presented_items = [{"id": "a1", "label": "call pool"}]
    c.presented_kind = "eod"
    llm = FakeLlm({
        "actions": [{
            "type": "capture",
            "task": "buy milk",
            "raw": "buy milk",
            "when": {"kind": "none"},
        }]
    })

    action = interpret(llm, c)[0]

    assert isinstance(action, Capture)
    assert len(llm.calls) == 1


def test_eod_adjudication_requires_uncontested_machine_context():
    for mutate in (
        lambda c: setattr(c, "presented_kind", "morning"),
        lambda c: setattr(c, "forwarded_from", "Alice"),
        lambda c: setattr(
            c,
            "pending",
            [{
                "kind": "capture",
                "question": "when is call mom due?",
                "task": "call mom",
            }],
        ),
    ):
        c = ctx("nada")
        c.presented_items = [{"id": "a1", "label": "call pool"}]
        c.presented_kind = "eod"
        mutate(c)
        llm = FakeLlm(
            {"actions": [{"type": "unknown", "note": "unclear"}]}
        )

        action = interpret(llm, c)[0]

        assert isinstance(action, Unknown)
        assert len(llm.calls) == 1


def test_eod_adjudication_outage_fails_closed():
    class FailsSecondCall:
        def __init__(self):
            self.calls = 0

        def complete_json(self, prompt, schema):
            self.calls += 1
            if self.calls == 1:
                return {"actions": [{"type": "chitchat", "reply": "got it"}]}
            raise RuntimeError("model stopped between passes")

    c = ctx("the scoreboard stayed empty")
    c.presented_items = [{"id": "a1", "label": "call pool"}]
    c.presented_kind = "eod"

    action = interpret(FailsSecondCall(), c)[0]

    assert isinstance(action, Unknown)
    assert action.note == MODEL_UNREACHABLE


def test_empty_actions_list_is_unknown():
    assert isinstance(parse_actions({"actions": []})[0], Unknown)


def test_prompt_includes_weekday_and_active_list():
    prompt = build_prompt(ctx(active=[{"id": "a1", "label": "call pool", "due_date": "2026-07-01"}]))
    assert "Monday" in prompt  # 2026-06-29 is a Monday
    assert "a1: call pool" in prompt


def test_prompt_includes_pending_clarification():
    c = ctx()
    c.pending = [
        {"kind": "capture", "question": "when is lunch with sam due?",
         "task": "lunch with sam"}
    ]
    prompt = build_prompt(c)
    assert "Pending question" in prompt
    assert "lunch with sam" in prompt


def test_prompt_has_no_pending_section_when_empty():
    assert "Pending question" not in build_prompt(ctx())


def test_parses_temporal_capture_schedule_and_recurrence_actions():
    actions = parse_actions(
        {
            "actions": [
                {
                    "type": "capture",
                    "task": "draft deck",
                    "raw": "draft deck",
                    "when": {"kind": "tomorrow"},
                    "deadline": {"kind": "weekday", "day": "fri"},
                    "duration_minutes": 90,
                    "duration_confidence": 0.8,
                    "splittable": True,
                    "depends_on": ["a1"],
                    "reminder_offsets": [60, 10],
                },
                {
                    "type": "schedule",
                    "target": "a2",
                    "duration_minutes": 45,
                    "clear": ["deadline"],
                },
                {"type": "recur", "target": "a3", "op": "skip"},
            ]
        }
    )
    assert actions[0].duration_minutes == 90
    assert actions[0].deadline.kind == "weekday"
    assert actions[0].reminder_offsets == [60, 10]
    assert actions[1].clear == ["deadline"]
    assert actions[2].op == "skip"
