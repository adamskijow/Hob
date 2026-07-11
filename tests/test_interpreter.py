# SPDX-License-Identifier: MIT
"""Interpreter: canned model JSON in, parsed Actions out, graceful on garbage."""
from core.interpreter import MODEL_UNREACHABLE, build_prompt, interpret, parse_actions
from core.models import (
    Amend,
    Bulk,
    Capture,
    Complete,
    Drop,
    InterpreterContext,
    PlanAction,
    Query,
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
