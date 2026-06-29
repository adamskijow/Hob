# SPDX-License-Identifier: MIT
"""Planner reconciliation: model proposes, deterministic core decides."""
from core.models import (
    Capture,
    Complete,
    Drop,
    InterpreterContext,
    Query,
    Reschedule,
    Unknown,
)
from core.planner import reconcile


def ctx(active=None, message=""):
    return InterpreterContext(
        message=message,
        today="2026-06-29",  # Monday
        now="2026-06-29T09:00:00",
        timezone="America/New_York",
        active_items=active or [],
        last_digest=[],
    )


ACTIVE = [
    {"id": "a1", "label": "org prez", "due_date": None},
    {"id": "a2", "label": "call the pool guy", "due_date": None},
    {"id": "a3", "label": "review SR audit", "due_date": "2026-06-28"},
]


def test_capture_without_date():
    plan = reconcile([Capture(task="call pool guy", raw="call pool guy")], ctx())
    assert len(plan.mutations) == 1
    assert not plan.questions
    assert plan.mutations[0].kind == "capture"
    assert plan.mutations[0].due_date is None


def test_capture_resolves_date_from_raw():
    plan = reconcile([Capture(task="org prez", raw="org prez Monday")], ctx())
    assert plan.mutations[0].due_date == "2026-07-06"
    assert not plan.questions


def test_ambiguous_date_asks_and_applies_nothing():
    plan = reconcile([Capture(task="x", raw="Friday or Monday")], ctx())
    assert not plan.mutations
    assert len(plan.questions) == 1


def test_capture_date_owned_by_parser():
    # The model proposes no date; the parser alone resolves "Monday".
    plan = reconcile([Capture(task="x", raw="Monday")], ctx())
    assert plan.mutations[0].due_date == "2026-07-06"
    assert not plan.questions


def test_capture_undated_when_parser_finds_nothing():
    # No date in the phrase -> captured undated, no clarifying question.
    plan = reconcile([Capture(task="x", raw="sometime soon")], ctx())
    assert plan.mutations[0].due_date is None
    assert not plan.questions


def test_bare_time_capture():
    plan = reconcile([Capture(task="call", raw="call at 3pm")], ctx())
    assert plan.mutations[0].due_time == "15:00"


def test_unknown_asks():
    plan = reconcile([Unknown(note="huh")], ctx())
    assert not plan.mutations
    assert plan.questions


# Phase 7: references, reschedule, query --------------------------------------


def test_complete_valid_target():
    plan = reconcile([Complete(target="a1", confidence=0.9)], ctx(ACTIVE))
    assert plan.mutations[0].kind == "complete"
    assert plan.mutations[0].target == "a1"
    assert not plan.questions


def test_unresolved_reference_asks_not_mutates():
    plan = reconcile([Complete(target="zz", confidence=0.9)], ctx(ACTIVE))
    assert not plan.mutations
    assert plan.questions


def test_low_confidence_reference_asks():
    plan = reconcile([Complete(target="a1", confidence=0.2)], ctx(ACTIVE))
    assert not plan.mutations
    assert "org prez" in plan.questions[0]


def test_drop_with_reason():
    plan = reconcile([Drop(target="a2", reason="not happening", confidence=0.9)], ctx(ACTIVE))
    assert plan.mutations[0].kind == "drop"
    assert plan.mutations[0].target == "a2"


def test_reschedule_resolves_date():
    plan = reconcile(
        [Reschedule(target="a3", raw="to Friday", confidence=0.9)],
        ctx(ACTIVE, message="push the audit to Friday"),
    )
    assert plan.mutations[0].kind == "reschedule"
    assert plan.mutations[0].due_date == "2026-07-03"


def test_reschedule_without_date_asks():
    plan = reconcile(
        [Reschedule(target="a3", raw="later", confidence=0.9)],
        ctx(ACTIVE, message="move the audit later"),
    )
    assert not plan.mutations
    assert plan.questions


def test_reschedule_bad_target_asks():
    plan = reconcile([Reschedule(target="zz", raw="to Friday", confidence=0.9)], ctx(ACTIVE))
    assert not plan.mutations
    assert plan.questions


def test_reschedule_phrase_not_in_message_asks():
    # The model invented a date absent from the message (a query misread as a
    # reschedule); the guard refuses to mutate and asks.
    plan = reconcile(
        [Reschedule(target="a3", raw="next Monday", confidence=0.9)],
        ctx(ACTIVE, message="what's on for tomorrow?"),
    )
    assert not plan.mutations
    assert plan.questions


def test_query_today_and_all():
    plan = reconcile([Query(kind="today")], ctx(ACTIVE))
    assert plan.queries[0].kind == "today"
    plan = reconcile([Query(kind="all")], ctx(ACTIVE))
    assert plan.queries[0].kind == "all"


def test_query_date_resolved_from_message_not_model():
    # model could lie about the date; we resolve from the message text
    plan = reconcile([Query(kind="date", date="1999-01-01")], ctx(ACTIVE, message="what's on for tomorrow?"))
    assert plan.queries[0].kind == "date"
    assert plan.queries[0].date == "2026-06-30"


def test_multi_action_batch():
    actions = [
        Complete(target="a1", confidence=0.9),
        Drop(target="a2", confidence=0.9),
        Reschedule(target="a3", raw="to Friday", confidence=0.9),
    ]
    plan = reconcile(
        actions, ctx(ACTIVE, message="did org prez, drop pool, push audit to Friday")
    )
    kinds = [m.kind for m in plan.mutations]
    assert kinds == ["complete", "drop", "reschedule"]
    assert not plan.questions
