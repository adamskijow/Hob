# SPDX-License-Identifier: MIT
"""Planner reconciliation: model proposes, deterministic core decides."""
from core.models import (
    Amend,
    Bulk,
    Capture,
    Complete,
    Drop,
    InterpreterContext,
    Prioritize,
    Query,
    Reschedule,
    Setting,
    Undo,
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


def test_resolve_ref_tolerates_model_forms():
    from core.planner import _resolve_ref
    active, by_pos = {"a1": "x", "a3": "y"}, {"1": "a1", "2": "a3"}
    assert _resolve_ref("a1", active, by_pos) == "a1"  # id
    assert _resolve_ref("A1", active, by_pos) == "a1"  # uppercased id
    assert _resolve_ref("2", active, by_pos) == "a3"  # position
    assert _resolve_ref("id:a1", active, by_pos) == "a1"  # stray "id:" prefix
    assert _resolve_ref("id:2", active, by_pos) == "a3"
    assert _resolve_ref("first", active, by_pos) == "a1"  # spelled ordinal
    assert _resolve_ref("#2", active, by_pos) == "a3"
    assert _resolve_ref("zzz", active, by_pos) is None


def test_target_by_position_number():
    # The user sees positions; "drop 2" must resolve to the 2nd listed item's id.
    plan = reconcile([Complete(target="2", confidence=0.9)], ctx(ACTIVE))
    assert plan.mutations[0].target == "a2"


def test_relate_by_position_number():
    plan = reconcile(
        [Capture(task="bring soda", raw="bring soda", relate="3")], ctx(ACTIVE)
    )
    assert plan.mutations[0].due_date == "2026-06-28"  # item #3 (a3) date


def test_target_matched_case_insensitively():
    # The display shows ids uppercased (A1); typing that must still resolve.
    plan = reconcile([Complete(target="A1", confidence=0.9)], ctx(ACTIVE))
    assert plan.mutations[0].kind == "complete"
    assert plan.mutations[0].target == "a1"  # stored id stays lowercase


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


# Pending clarifications -------------------------------------------------------


def test_ambiguous_capture_sets_pending():
    plan = reconcile([Capture(task="lunch with sam", raw="thursday or friday")], ctx())
    assert not plan.mutations
    assert len(plan.pending) == 1
    assert plan.pending[0].kind == "capture"
    assert plan.pending[0].task == "lunch with sam"


def test_reschedule_unresolved_sets_pending():
    plan = reconcile(
        [Reschedule(target="a3", raw="later", confidence=0.9)],
        ctx(ACTIVE, message="move the audit later"),
    )
    assert not plan.mutations
    assert len(plan.pending) == 1
    assert plan.pending[0].kind == "reschedule"
    assert plan.pending[0].target == "a3"


def test_reschedule_guard_fail_sets_no_pending():
    # A hallucinated reschedule must not become resumable: a stray date next turn
    # must not move this item.
    plan = reconcile(
        [Reschedule(target="a3", raw="next Monday", confidence=0.9)],
        ctx(ACTIVE, message="what's on for tomorrow?"),
    )
    assert plan.questions
    assert not plan.pending


# Bulk actions ----------------------------------------------------------------


def test_bulk_drop_across_days_confirms():
    # ACTIVE spans undated items + a dated one, so a delete-all is held for yes/no.
    plan = reconcile([Bulk(op="drop", scope="all")], ctx(ACTIVE))
    assert not plan.mutations
    assert plan.confirm is not None
    assert all(m.kind == "drop" for m in plan.confirm.mutations)
    assert {m.target for m in plan.confirm.mutations} == {"a1", "a2", "a3"}


def test_bulk_drop_single_day_applies_without_confirm():
    active = [
        {"id": "x1", "label": "a", "due_date": "2026-07-03"},
        {"id": "x2", "label": "b", "due_date": "2026-07-03"},
    ]
    plan = reconcile([Bulk(op="drop", scope="all")], ctx(active))
    assert plan.confirm is None
    assert {m.target for m in plan.mutations} == {"x1", "x2"}


def test_bulk_complete_across_days_does_not_confirm():
    # Completing is undoable and not a deletion, so it does not need a yes/no.
    plan = reconcile([Bulk(op="complete", scope="all")], ctx(ACTIVE))
    assert plan.confirm is None
    assert len(plan.mutations) == 3


def test_bulk_complete_today_excludes_future():
    active = ACTIVE + [{"id": "a4", "label": "future thing", "due_date": "2026-07-15"}]
    plan = reconcile([Bulk(op="complete", scope="today")], ctx(active))
    # a1/a2 undated + a3 overdue are on deck today; a4 is future, excluded.
    assert {m.target for m in plan.mutations} == {"a1", "a2", "a3"}
    assert all(m.kind == "complete" for m in plan.mutations)


def test_bulk_date_resolves_day_from_message():
    active = [
        {"id": "a3", "label": "review SR audit", "due_date": "2026-06-28"},
        {"id": "a5", "label": "thing friday", "due_date": "2026-07-03"},
    ]
    plan = reconcile(
        [Bulk(op="drop", scope="date")], ctx(active, message="drop all of friday")
    )
    assert {m.target for m in plan.mutations} == {"a5"}  # friday = 2026-07-03


def test_bulk_date_ambiguous_asks():
    plan = reconcile(
        [Bulk(op="drop", scope="date")], ctx(ACTIVE, message="clear thursday or friday")
    )
    assert not plan.mutations
    assert plan.questions


def test_bulk_no_match_changes_nothing():
    plan = reconcile(
        [Bulk(op="drop", scope="date")], ctx(ACTIVE, message="clear out july 20")
    )
    assert not plan.mutations
    assert plan.questions


def test_low_confidence_bulk_confirms_not_applies():
    # A sweeping mutation must not apply on a low-confidence guess.
    plan = reconcile([Bulk(op="drop", scope="all", confidence=0.2)], ctx(ACTIVE))
    assert not plan.mutations
    assert plan.questions and "confirm" in plan.questions[0]


def test_bulk_reschedule_moves_matching():
    plan = reconcile(
        [Bulk(op="reschedule", scope="all", raw="wednesday")],
        ctx(ACTIVE, message="push everything to wednesday"),
    )
    assert {m.target for m in plan.mutations} == {"a1", "a2", "a3"}
    assert all(m.kind == "reschedule" and m.due_date == "2026-07-01" for m in plan.mutations)


def test_bulk_reschedule_unresolved_asks():
    plan = reconcile(
        [Bulk(op="reschedule", scope="all", raw="later")],
        ctx(ACTIVE, message="push everything later"),
    )
    assert not plan.mutations and plan.questions


def test_query_overdue_and_week():
    assert reconcile([Query(kind="overdue")], ctx(ACTIVE)).queries[0].kind == "overdue"
    assert reconcile([Query(kind="week")], ctx(ACTIVE)).queries[0].kind == "week"


def test_query_search_from_term():
    plan = reconcile([Query(kind="all", term="pool")], ctx(ACTIVE, message="anything about pool"))
    assert plan.queries[0].kind == "search" and plan.queries[0].term == "pool"


def test_query_done_period():
    today = reconcile([Query(kind="done")], ctx(ACTIVE, message="what did i finish today"))
    assert today.queries[0].kind == "done" and today.queries[0].date == "2026-06-29"
    week = reconcile([Query(kind="done")], ctx(ACTIVE, message="what did i do this week"))
    assert week.queries[0].date == "2026-06-23"  # today - 6 days


def test_undo_action_sets_flag():
    assert reconcile([Undo()], ctx()).undo is True


def test_prioritize_resolves_target_and_level():
    plan = reconcile([Prioritize(target="a3", level="high")], ctx(ACTIVE))
    assert [m.kind for m in plan.mutations] == ["prioritize"]
    assert plan.mutations[0].target == "a3" and plan.mutations[0].priority == "high"


def test_prioritize_by_position():
    plan = reconcile([Prioritize(target="2", level="low")], ctx(ACTIVE))
    assert plan.mutations[0].target == "a2" and plan.mutations[0].priority == "low"


def test_capture_carries_priority():
    plan = reconcile(
        [Capture(task="call plumber", raw="call plumber urgent", priority="high")], ctx()
    )
    assert plan.mutations[0].kind == "capture" and plan.mutations[0].priority == "high"


def test_capture_carries_tag():
    plan = reconcile([Capture(task="book caterer", raw="book caterer", tag="wedding")], ctx())
    assert plan.mutations[0].tag == "wedding"


def test_query_tag():
    plan = reconcile([Query(kind="tag", tag="wedding")], ctx(ACTIVE))
    assert plan.queries[0].kind == "tag" and plan.queries[0].tag == "wedding"


def test_query_term_beats_tag():
    # "anything about the caterer" can come back with both; term wins -> search.
    plan = reconcile([Query(kind="tag", tag="wedding", term="caterer")], ctx(ACTIVE))
    assert plan.queries[0].kind == "search" and plan.queries[0].term == "caterer"


def test_setting_wake_time_parsed():
    plan = reconcile([Setting(key="wake_time", raw="6:30")], ctx())
    assert [(s.key, s.value) for s in plan.settings] == [("wake_time", "06:30")]


def test_setting_unparseable_asks():
    plan = reconcile([Setting(key="wake_time", raw="whenever")], ctx())
    assert not plan.settings and plan.questions


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


def test_query_named_day_overrides_model_kind():
    # The model mislabeled a "tomorrow" query as today; the message decides.
    plan = reconcile(
        [Query(kind="today")], ctx(ACTIVE, message="what is my schedule for tomorrow again")
    )
    assert plan.queries[0].kind == "date"
    assert plan.queries[0].date == "2026-06-30"


def test_capture_recovers_dropped_date_from_message():
    # The model dropped the leading "Tomorrow" from raw; a lone capture recovers
    # the date from the whole message.
    plan = reconcile(
        [Capture(task="harass Jerry", raw="harass Jerry")],
        ctx(message="Tomorrow I need to harass Jerry"),
    )
    assert plan.mutations[0].due_date == "2026-06-30"


def test_capture_recurring_daily():
    plan = reconcile(
        [Capture(task="water plants", raw="water plants daily", repeat="daily")], ctx()
    )
    assert plan.mutations[0].repeat == "daily"
    assert plan.mutations[0].due_date == "2026-06-29"  # today


def test_capture_recurring_weekly_next_occurrence():
    plan = reconcile(
        [Capture(task="trash", raw="trash every wednesday", repeat="weekly:wednesday")],
        ctx(),
    )
    assert plan.mutations[0].repeat == "weekly:wed"
    assert plan.mutations[0].due_date == "2026-07-01"  # next Wed after Mon 06-29


def test_capture_unsupported_repeat_is_one_off():
    plan = reconcile(
        [Capture(task="rent", raw="rent monthly", repeat="monthly")], ctx()
    )
    assert plan.mutations[0].repeat is None


def test_capture_far_future_confirms():
    # "in 200 years" is probably a typo or a joke: hold it for a yes/no.
    plan = reconcile([Capture(task="take out the trash", raw="in 200 years")], ctx())
    assert not plan.mutations
    assert plan.confirm is not None
    assert plan.confirm.mutations[0].kind == "capture"
    assert "years out" in plan.confirm.question


def test_capture_near_future_applies():
    # A couple of years out is plausible; apply without confirming.
    plan = reconcile([Capture(task="renew passport", raw="in 2 years")], ctx())
    assert plan.mutations and plan.confirm is None


def test_reschedule_far_future_confirms():
    plan = reconcile(
        [Reschedule(target="a3", raw="in 100 years", confidence=0.9)],
        ctx(ACTIVE, message="push the audit in 100 years"),
    )
    assert not plan.mutations
    assert plan.confirm is not None and plan.confirm.mutations[0].kind == "reschedule"


def test_capture_relate_inherits_date():
    # "bring soda" for an existing dated item inherits that item's date.
    plan = reconcile(
        [Capture(task="bring soda", raw="bring soda", relate="a3")], ctx(ACTIVE)
    )
    assert plan.mutations[0].due_date == "2026-06-28"  # a3's date


def test_capture_relate_case_insensitive():
    plan = reconcile(
        [Capture(task="bring soda", raw="bring soda", relate="A3")], ctx(ACTIVE)
    )
    assert plan.mutations[0].due_date == "2026-06-28"


def test_capture_own_date_beats_relate():
    plan = reconcile(
        [Capture(task="bring soda", raw="bring soda Friday", relate="a3")], ctx(ACTIVE)
    )
    assert plan.mutations[0].due_date == "2026-07-03"  # its own Friday, not a3's


def test_amend_replaces_item_text():
    plan = reconcile([Amend(target="a1", task="prep Q3 deck", confidence=0.9)], ctx(ACTIVE))
    assert plan.mutations[0].kind == "amend"
    assert plan.mutations[0].target == "a1"
    assert plan.mutations[0].task == "prep Q3 deck"


def test_amend_bad_target_asks():
    plan = reconcile([Amend(target="zz", task="x", confidence=0.9)], ctx(ACTIVE))
    assert not plan.mutations and plan.questions


def test_amend_low_confidence_asks():
    plan = reconcile([Amend(target="a1", task="x", confidence=0.2)], ctx(ACTIVE))
    assert not plan.mutations and plan.questions


def test_multi_capture_shares_leading_date():
    # "Tomorrow I need to A, B" -> the leading date reaches both tasks.
    plan = reconcile(
        [Capture(task="look at slides", raw="look at slides"),
         Capture(task="prep meeting", raw="prep meeting")],
        ctx(message="Tomorrow I need to look at slides and prep meeting"),
    )
    assert [m.due_date for m in plan.mutations] == ["2026-06-30", "2026-06-30"]


def test_capture_uses_model_extracted_time():
    # "1130" is not a year (dropped); the model's parsed time is kept as a fallback.
    plan = reconcile(
        [Capture(task="prep", raw="prep for my 1130 meeting", time="11:30")], ctx()
    )
    assert plan.mutations[0].due_date is None
    assert plan.mutations[0].due_time == "11:30"


def test_multi_capture_does_not_borrow_message_date():
    # With several captures the message fallback is off, so a date in the message
    # is not misattributed to all of them.
    plan = reconcile(
        [Capture(task="call John", raw="call John"),
         Capture(task="email Sue", raw="email Sue")],
        ctx(message="call John and email Sue tomorrow"),
    )
    assert [m.due_date for m in plan.mutations] == [None, None]


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
