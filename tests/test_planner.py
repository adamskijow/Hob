# SPDX-License-Identifier: MIT
"""Planner reconciliation: model proposes, deterministic core decides."""
from core.models import Capture, InterpreterContext, Unknown
from core.planner import reconcile


def ctx():
    return InterpreterContext(
        message="",
        today="2026-06-29",  # Monday
        now="2026-06-29T09:00:00",
        timezone="America/New_York",
        active_items=[],
        last_digest=[],
    )


def test_capture_without_date():
    plan = reconcile([Capture(task="call pool guy", raw="call pool guy")], ctx())
    assert len(plan.mutations) == 1
    assert not plan.questions
    assert plan.mutations[0].kind == "capture"
    assert plan.mutations[0].due_date is None


def test_capture_resolves_date_from_raw():
    plan = reconcile(
        [Capture(task="org prez", raw="org prez Monday", due="2026-07-06")], ctx()
    )
    assert plan.mutations[0].due_date == "2026-07-06"
    assert not plan.questions


def test_ambiguous_date_asks_and_applies_nothing():
    plan = reconcile([Capture(task="x", raw="Friday or Monday")], ctx())
    assert not plan.mutations
    assert len(plan.questions) == 1


def test_model_parser_disagreement_asks():
    # parser resolves "Monday" to 2026-07-06; model claims 2026-07-07
    plan = reconcile([Capture(task="x", raw="Monday", due="2026-07-07")], ctx())
    assert not plan.mutations
    assert plan.questions


def test_parser_finds_nothing_but_model_dated_it_asks():
    plan = reconcile([Capture(task="x", raw="sometime soon", due="2026-07-10")], ctx())
    assert not plan.mutations
    assert plan.questions


def test_garbage_model_date_is_ignored_not_a_disagreement():
    # unparseable model due -> ignored; clean parser date is applied
    plan = reconcile([Capture(task="x", raw="Monday", due="next monday")], ctx())
    assert plan.mutations[0].due_date == "2026-07-06"
    assert not plan.questions


def test_bare_time_capture():
    plan = reconcile([Capture(task="call", raw="call at 3pm")], ctx())
    assert plan.mutations[0].due_time == "15:00"


def test_unknown_asks():
    plan = reconcile([Unknown(note="huh")], ctx())
    assert not plan.mutations
    assert plan.questions
