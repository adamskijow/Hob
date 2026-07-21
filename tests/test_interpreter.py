# SPDX-License-Identifier: MIT
"""Interpreter: canned model JSON in, parsed Actions out, graceful on garbage."""
from core.interpreter import MODEL_UNREACHABLE, build_prompt, interpret, parse_actions
from core.models import (
    Amend,
    Bulk,
    Capture,
    Chitchat,
    Complete,
    ConfirmationDecision,
    Drop,
    InterpreterContext,
    NudgeDecision,
    PlanAction,
    Query,
    Recap,
    Reschedule,
    Schedule,
    Setting,
    Undo,
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


def test_active_nudge_gets_focused_semantic_adjudication():
    c = ctx("It needs to stay on")
    c.nudge = {
        "item_id": "a1",
        "label": "call pool",
        "kind": "stale_task",
        "sent_at": "2026-06-29T07:00:00",
    }
    llm = FakeLlm([
        {"actions": [{
            "type": "setting", "key": "eod_time", "raw": "stay on",
            "time": "20:00",
        }]},
        {"outcome": "keep", "confidence": 0.97},
    ])

    action = interpret(llm, c)[0]

    assert isinstance(action, NudgeDecision)
    assert action.decision == "keep"
    assert "Reason by meaning" in llm.calls[1][0]


def test_confirmation_approval_requires_independent_model_consensus():
    c = ctx("yes, but exclude 2")
    c.confirmation_pending = True
    llm = FakeLlm([
        {"actions": [{"type": "unknown", "note": "conditional revision"}]},
        {"outcome": "approve", "confidence": 0.99},
    ])

    action = interpret(llm, c)[0]

    assert isinstance(action, Unknown)


def test_confirmation_pure_approval_passes_two_model_votes():
    c = ctx("yes")
    c.confirmation_pending = True
    llm = FakeLlm([
        {"actions": [{
            "type": "confirmation_decision", "decision": "approve",
            "confidence": 0.96,
        }]},
        {"outcome": "approve", "confidence": 0.99},
    ])

    action = interpret(llm, c)[0]

    assert isinstance(action, ConfirmationDecision)
    assert action.decision == "approve"


def test_bulk_scope_adjudication_confines_that_list():
    c = ctx("move everything on that list to monday")
    c.presented_items = [{"id": "a1", "label": "call pool"}]
    llm = FakeLlm([
        {"actions": [{
            "type": "bulk", "op": "reschedule", "scope": "all", "except": [],
            "when": {"kind": "weekday", "day": "mon"},
        }]},
        {"scope": "presented", "exclude": [], "confidence": 0.96},
    ])

    action = interpret(llm, c)[0]

    assert isinstance(action, Bulk)
    assert action.scope == "presented"
    assert len(llm.calls) == 2
    assert "classify which set" in llm.calls[1][0]


def test_bulk_scope_adjudication_resolves_numbered_exclusions():
    c = ctx("finished it all except 1 and 3")
    c.last_digest = [
        {"id": "a1", "label": "call pool"},
        {"id": "a2", "label": "write brief"},
        {"id": "a3", "label": "book dentist"},
    ]
    c.active_items = c.last_digest
    llm = FakeLlm([
        {"actions": [{
            "type": "bulk", "op": "complete", "scope": "all", "except": [],
        }]},
        {
            "scope": "presented", "exclude": ["a1", "a3", "not-real"],
            "confidence": 0.98,
        },
    ])

    action = interpret(llm, c)[0]

    assert isinstance(action, Bulk)
    assert action.scope == "presented" and action.exclude == ["a1", "a3"]


def test_candidate_review_corrects_model_route_and_preserves_typed_contract():
    c = ctx("the first half of the day is shot, replan")
    llm = FakeLlm(
        {"actions": [{"type": "plan_action", "op": "replace"}]},
        review_responses=[
            {
                "type": "plan", "when": {"kind": "none"},
                "earliest_time": "12:00", "confidence": 0.97,
            },
            {"outcome": "plan", "confidence": 0.95},
        ],
    )

    action = interpret(llm, c)[0]

    assert isinstance(action, Query)
    assert action.kind == "plan" and action.earliest_time == "12:00"
    assert len(llm.calls) == 3
    assert llm.calls[1][0].startswith("Independently audit a first-pass")


def test_high_confidence_retraction_audit_is_bounded_by_recent_change():
    c = ctx("Nevermind I'm good")
    c.last_change_at = "2026-06-29T08:55:00"
    llm = FakeLlm(
        {"actions": [{"type": "chitchat", "reply": "sure"}]},
        review_responses={"type": "undo", "confidence": 0.96},
    )

    action = interpret(llm, c)[0]

    assert isinstance(action, Undo)
    assert len(llm.calls) == 2


def test_setting_audit_supplies_typed_range_without_raw_phrase_repair():
    c = ctx("plan my work from 9 to 5")
    llm = FakeLlm(
        {"actions": [{
            "type": "setting", "key": "work_hours", "raw": "9 to 5",
        }]},
        review_responses={
            "type": "setting", "key": "work_hours", "raw": "9 to 5",
            "time": None, "start_time": "09:00", "end_time": "17:00",
            "days": [], "minutes": None, "clear": False, "confidence": 0.98,
        },
    )

    action = interpret(llm, c)[0]

    assert isinstance(action, Setting)
    assert action.start_time == "09:00" and action.end_time == "17:00"


def test_schedule_audit_corrects_typed_deadline_without_moving_task():
    c = ctx(
        "the audit is due Friday and takes 90 minutes",
        active=[{"id": "a3", "label": "review audit", "due_date": None}],
    )
    llm = FakeLlm(
        {"actions": [{
            "type": "schedule", "target": "a3",
            "deadline": {"kind": "today"}, "duration_minutes": 90,
        }]},
        review_responses={
            "type": "schedule", "target": "a3",
            "deadline": {"kind": "weekday", "day": "fri"},
            "duration_minutes": 90, "duration_confidence": 1,
            "confidence": 0.99,
        },
    )

    action = interpret(llm, c)[0]

    assert isinstance(action, Schedule)
    assert action.deadline.day == "fri" and action.duration_minutes == 90


def test_bulk_audit_owns_destination_date_intent():
    c = ctx("push everything to tomorrow")
    llm = FakeLlm([
        {"actions": [{
            "type": "bulk", "op": "reschedule", "scope": "all",
            "except": [], "when": {"kind": "none"},
        }]},
        {
            "scope": "all", "when": {"kind": "tomorrow"},
            "exclude": [], "confidence": 0.99,
        },
    ])

    action = interpret(llm, c)[0]

    assert isinstance(action, Bulk)
    assert action.when.kind == "tomorrow"


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
        assert not any(
            "most recently asked the user an evening recap" in prompt
            for prompt, _, _ in llm.calls[1:]
        )


def test_eod_adjudication_outage_preserves_safe_main_model_result():
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

    assert isinstance(action, Chitchat)
    assert action.reply == "got it"


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
