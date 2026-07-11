# SPDX-License-Identifier: MIT
from copy import deepcopy

from core.explanation import DECISION_VERSION, explain_decision


def decision():
    return {
        "version": DECISION_VERSION,
        "kind": "plan",
        "generated_at": "2026-07-11T08:00:00-04:00",
        "start_day": "2026-07-11",
        "end_day": "2026-07-11",
        "constraint": "plan my day",
        "calendar": {"authorized_days": 1, "total_days": 1},
        "preferences": {
            "work_start": "09:00",
            "work_end": "17:00",
            "work_days": [0, 1, 2, 3, 4],
            "breaks": [["12:00", "13:00"]],
            "energy": "low",
            "default_duration_minutes": 30,
            "transition_buffer_minutes": 10,
        },
        "items": [
            {
                "id": "a1",
                "label": "draft board report",
                "outcome": "scheduled",
                "blocks": [
                    {"day": "2026-07-11", "start": "09:00", "end": "10:00"}
                ],
                "inferred": False,
                "priority": "high",
                "deadline": "2026-07-11",
                "fixed": False,
            },
            {
                "id": "a2",
                "label": "prepare audit appendix",
                "outcome": "deferred",
                "reason": "does not fit the remaining free time",
                "remaining_minutes": 90,
                "blocks": [],
                "inferred": True,
            },
        ],
    }


def test_deferred_explanation_and_options_are_grounded_and_read_only():
    snapshot = decision()
    before = deepcopy(snapshot)

    out = explain_decision(
        snapshot, "what would make the audit appendix fit?", "audit appendix"
    )

    assert '"prepare audit appendix" was deferred' in out
    assert "does not fit the remaining free time" in out
    assert "90m remaining" in out and "for 90m plus any visible buffers" in out
    assert "EventKit availability used on 1/1" in out and "nothing changed" in out
    assert snapshot == before


def test_scheduled_explanation_uses_recorded_block_and_default_flag():
    snapshot = decision()
    snapshot["items"][0]["inferred"] = True

    out = explain_decision(snapshot, "why was the first one scheduled there?")

    assert '"draft board report" was scheduled' in out
    assert "2026-07-11 09:00-10:00" in out
    assert "visible default estimate" in out
    assert "first compatible opening" in out
    assert "high priority, deadline 2026-07-11" in out


def test_generic_explanation_summarizes_result_without_inventing_cause():
    out = explain_decision(decision(), "why this plan?")

    assert "1 scheduled result(s) and 1 not fully placed or at risk" in out
    assert "planning hours 09:00-17:00" in out
    assert "planning days Mon,Tue,Wed,Thu,Fri" in out
    assert "protected 12:00-13:00" in out
    assert "stated low-energy constraint" in out
    assert "name a displayed task" in out


def test_tied_target_asks_instead_of_guessing():
    snapshot = decision()
    snapshot["items"].append(
        {
            "id": "a3",
            "label": "audit evidence review",
            "outcome": "risk",
            "reason": "does not fit by deadline 2026-07-11",
            "remaining_minutes": 30,
        }
    )

    out = explain_decision(snapshot, "why did audit not fit?")

    assert out.startswith("which result did you mean:")
    assert "prepare audit appendix" in out and "audit evidence review" in out


def test_single_unresolved_result_supports_natural_pronoun_followup():
    out = explain_decision(decision(), "why didn't it fit?")

    assert '"prepare audit appendix" was deferred' in out


def test_reason_specific_options_do_not_silently_change_anything():
    snapshot = decision()
    item = snapshot["items"][1]
    item["reason"] = "does not fit after its prerequisite"

    out = explain_decision(snapshot, "what would it take to make a2 fit?")

    assert "Resolve the recorded prerequisite" in out
    assert "explicitly change that dependency" in out
    assert out.endswith("nothing changed.")


def test_missing_malformed_or_future_snapshot_regenerates_safely():
    malformed = decision()
    malformed["items"][0]["blocks"] = "not-a-list"
    for snapshot in (
        {},
        {"version": 999, "kind": "plan", "items": []},
        malformed,
    ):
        out = explain_decision(snapshot, "why?")
        assert 'ask "plan my day" or use /outlook' in out


def test_partial_result_preserves_placed_blocks_and_remaining_reason():
    snapshot = decision()
    item = snapshot["items"][0]
    item.update(
        outcome="partial",
        reason="does not fit the remaining free time",
        remaining_minutes=45,
    )

    out = explain_decision(snapshot, "why did the board report not fit?")

    assert "was partly scheduled at 2026-07-11 09:00-10:00" in out
    assert "remainder was deferred" in out and "45m remaining" in out


def test_common_options_wording_is_safe_during_literal_outage_route():
    from core.explanation import is_explanation_question

    assert is_explanation_question("what would make the audit fit?")
    assert is_explanation_question("why is the report not on the plan?")
    assert is_explanation_question("how can I make it fit?")
    assert not is_explanation_question("how can I fit a workout into my day?")


def test_model_only_single_word_cannot_hallucinate_a_target():
    snapshot = decision()
    snapshot["items"].append(
        {
            "id": "a3",
            "label": "call insurance office",
            "outcome": "deferred",
            "reason": "does not fit the remaining free time",
            "remaining_minutes": 20,
        }
    )

    out = explain_decision(snapshot, "why this plan?", term="audit")

    assert "latest plan covers" in out
    assert '"prepare audit appendix" was deferred' not in out


def test_bounded_generation_caps_items_and_blocks_and_marks_truncation():
    from app import MessageService

    entries = [
        {
            "id": f"a{index}",
            "label": f"task {index}",
            "outcome": "scheduled",
            "blocks": [
                {"day": "2026-07-11", "start": "09:00", "end": "09:05"}
                for _ in range(55)
            ],
        }
        for index in range(105)
    ]

    bounded, truncated = MessageService._bounded_decision_items(entries)

    assert truncated and len(bounded) == 100
    assert all(len(item["blocks"]) == 50 for item in bounded)
