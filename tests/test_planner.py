# SPDX-License-Identifier: MIT
"""Planner reconciliation: model proposes, deterministic core decides."""
from core.models import (
    Amend,
    Bulk,
    Capture,
    Chitchat,
    Complete,
    Drop,
    InterpreterContext,
    Note,
    PlanAction,
    Prioritize,
    Query,
    Recap,
    Recur,
    Reschedule,
    Schedule,
    Setting,
    Start,
    Undo,
    Unknown,
    When,
)
from core.planner import reconcile


def ctx(
    active=None,
    message="",
    focus=None,
    replied=None,
    presented=None,
    digest=None,
    pending=None,
    forwarded=None,
    presented_kind=None,
):
    return InterpreterContext(
        message=message,
        focus=focus or [],
        replied=replied,
        today="2026-06-29",  # Monday
        now="2026-06-29T09:00:00",
        timezone="America/New_York",
        active_items=active or [],
        last_digest=digest or [],
        presented_items=presented or [],
        presented_kind=presented_kind,
        pending=pending or [],
        forwarded_from=forwarded,
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


def test_capture_resolves_date_from_intent():
    plan = reconcile(
        [Capture(task="org prez", raw="org prez Monday", when=When(kind="weekday", day="mon"))],
        ctx(),
    )
    assert plan.mutations[0].due_date == "2026-07-06"  # core does the math
    assert not plan.questions


def test_ambiguous_intent_asks_and_applies_nothing():
    plan = reconcile([Capture(task="x", raw="Friday or Monday", when=When(kind="ambiguous"))], ctx())
    assert not plan.mutations
    assert len(plan.questions) == 1


def test_capture_undated_when_parser_finds_nothing():
    # No date in the phrase -> captured undated, no clarifying question.
    plan = reconcile([Capture(task="x", raw="sometime soon")], ctx())
    assert plan.mutations[0].due_date is None
    assert not plan.questions


def test_bare_time_capture():
    # The model extracts the clock time; the core parses it (no date math).
    plan = reconcile([Capture(task="call", raw="call at 3pm", time="3pm")], ctx())
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


def test_shared_past_tense_converts_misread_start_to_completion():
    active = [
        {"id": "a1", "label": "remind mortgage home insurance", "due_date": None},
        {"id": "a2", "label": "hit the grift", "due_date": None},
    ]
    plan = reconcile(
        [
            Complete(target="a1", confidence=0.95),
            Start(target="a2", confidence=0.95),
        ],
        ctx(active, message="I did home insurance and hit the grift"),
    )

    assert [(m.kind, m.target) for m in plan.mutations] == [
        ("complete", "a1"),
        ("complete", "a2"),
    ]
    assert not plan.starts


def test_explicit_future_breaks_shared_completion_tense():
    active = [
        {"id": "a1", "label": "remind mortgage home insurance", "due_date": None},
        {"id": "a2", "label": "hit the grift", "due_date": None},
    ]
    plan = reconcile(
        [
            Complete(target="a1", confidence=0.95),
            Start(target="a2", confidence=0.95),
        ],
        ctx(active, message="I did home insurance and will hit the grift"),
    )

    assert [(m.kind, m.target) for m in plan.mutations] == [("complete", "a1")]
    assert plan.starts == ["a2"]


def test_partial_progress_breaks_shared_completion_tense():
    active = [
        {"id": "a1", "label": "remind mortgage home insurance", "due_date": None},
        {"id": "a2", "label": "hit the grift", "due_date": None},
    ]
    plan = reconcile(
        [
            Complete(target="a1", confidence=0.95),
            Start(target="a2", confidence=0.95),
        ],
        ctx(active, message="I did home insurance and worked on the grift"),
    )

    assert [(m.kind, m.target) for m in plan.mutations] == [("complete", "a1")]
    assert plan.starts == ["a2"]


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
    assert _resolve_ref("a3: review the audit (due 2026-06-28)", active, by_pos) == "a3"  # whole line
    assert _resolve_ref("url_not_provided_2", active, by_pos) == "a3"  # noisy + trailing position
    assert _resolve_ref("zzz", active, by_pos) is None


def test_target_by_position_number():
    # The user sees positions; "drop 2" must resolve to the 2nd listed item's id.
    plan = reconcile([Complete(target="2", confidence=0.9)], ctx(ACTIVE))
    assert plan.mutations[0].target == "a2"


def test_literal_ordinal_overrides_a_bad_model_target():
    plan = reconcile(
        [Complete(target="All items on deck", confidence=1.0)],
        ctx(ACTIVE, message="the third one is done"),
    )
    assert plan.mutations[0].target == "a3"


def test_plan_start_uses_displayed_order_without_completing():
    focus = [
        {"id": "a2", "label": "call the pool guy", "context": "plan"},
        {"id": "a3", "label": "review SR audit", "context": "plan"},
    ]
    plan = reconcile(
        [Prioritize(target="a2", level="normal")],
        ctx(ACTIVE, message="do the second one", focus=focus),
    )
    assert plan.starts == ["a3"]
    assert not plan.mutations


def test_pronoun_constraint_clause_merges_into_new_capture():
    plan = reconcile(
        [
            Capture(
                task="draft the board report; it is due Monday",
                raw="draft the board report Friday; it is due Monday",
                when=When(kind="weekday", day="fri"),
                duration_minutes=180,
                splittable=True,
            ),
            Schedule(
                target="a3",
                deadline=When(kind="absolute", date="2026-07-06"),
                clear=["deadline"],
            ),
        ],
        ctx(
            ACTIVE,
            message=(
                "draft the board report Friday; it is due Monday and takes "
                "three hours in two sessions"
            ),
        ),
    )
    assert len(plan.mutations) == 1
    mutation = plan.mutations[0]
    assert mutation.kind == "capture"
    assert mutation.task == "draft the board report"
    assert mutation.due_date == "2026-07-03"
    assert mutation.deadline_date == "2026-07-06"
    assert mutation.duration_minutes == 180 and mutation.splittable


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
    assert plan.confirm is not None
    assert "org prez" in plan.confirm.question


def test_drop_with_reason():
    plan = reconcile([Drop(target="a2", reason="not happening", confidence=0.9)], ctx(ACTIVE))
    assert plan.mutations[0].kind == "drop"
    assert plan.mutations[0].target == "a2"


def test_reschedule_resolves_date():
    plan = reconcile(
        [Reschedule(target="a3", when=When(kind="weekday", which="next", day="fri"), confidence=0.9)],
        ctx(ACTIVE),
    )
    assert plan.mutations[0].kind == "reschedule"
    assert plan.mutations[0].due_date == "2026-07-03"


def test_reschedule_without_date_asks():
    plan = reconcile([Reschedule(target="a3", when=None, confidence=0.9)], ctx(ACTIVE))
    assert not plan.mutations
    assert plan.questions


def test_reschedule_time_only():
    # "make it 4pm" as a follow-up: no new date, just a clock time.
    plan = reconcile(
        [Reschedule(target="a3", when=None, time="4pm", confidence=0.9)],
        ctx(ACTIVE, message="make it 4pm",
            focus=[{"id": "a3", "label": "review SR audit"}]),
    )
    assert plan.mutations[0].kind == "reschedule"
    assert plan.mutations[0].due_date is None
    assert plan.mutations[0].due_time == "16:00"
    assert not plan.questions


def test_reschedule_time_only_padded_today_keeps_day():
    # The model pads "make it 4pm" with kind today; no today-word in the message
    # means the day is not changing.
    plan = reconcile(
        [Reschedule(target="a3", when=When(kind="today"), time="4pm", confidence=0.9)],
        ctx(ACTIVE, message="make it 4pm",
            focus=[{"id": "a3", "label": "review SR audit"}]),
    )
    assert plan.mutations[0].due_date is None  # padded today ignored
    assert plan.mutations[0].due_time == "16:00"
    # but an explicit "today at 4" keeps the date change
    plan2 = reconcile(
        [Reschedule(target="a3", when=When(kind="today"), time="4pm", confidence=0.9)],
        ctx(ACTIVE, message="do it today at 4pm",
            focus=[{"id": "a3", "label": "review SR audit"}]),
    )
    assert plan2.mutations[0].due_date == "2026-06-29"


def test_reschedule_time_only_unanchored_asks():
    # "make it 4pm" with no focus, no reply anchor, and no overlap with the
    # item's words is a guess: ask instead of moving.
    plan = reconcile(
        [Reschedule(target="a3", when=None, time="4pm", confidence=0.9)],
        ctx(ACTIVE, message="make it 4pm"),
    )
    assert not plan.mutations
    assert plan.questions


def test_reschedule_date_and_time():
    plan = reconcile(
        [Reschedule(target="a3", when=When(kind="weekday", day="fri"), time="9am",
                    confidence=0.9)],
        ctx(ACTIVE),
    )
    assert plan.mutations[0].due_date == "2026-07-03"
    assert plan.mutations[0].due_time == "09:00"


def test_reschedule_bad_target_asks():
    plan = reconcile(
        [Reschedule(target="zz", when=When(kind="weekday", day="fri"), confidence=0.9)],
        ctx(ACTIVE),
    )
    assert not plan.mutations
    assert plan.questions


# Pending clarifications -------------------------------------------------------


def test_ambiguous_capture_sets_pending():
    plan = reconcile(
        [Capture(task="lunch with sam", raw="thursday or friday", when=When(kind="ambiguous"))],
        ctx(),
    )
    assert not plan.mutations
    assert len(plan.pending) == 1
    assert plan.pending[0].kind == "capture"
    assert plan.pending[0].task == "lunch with sam"


def test_reschedule_unresolved_sets_pending():
    plan = reconcile([Reschedule(target="a3", when=None, confidence=0.9)], ctx(ACTIVE))
    assert not plan.mutations
    assert len(plan.pending) == 1
    assert plan.pending[0].kind == "reschedule"
    assert plan.pending[0].target == "a3"


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
        [Bulk(op="drop", scope="date", when=When(kind="weekday", which="next", day="fri"))],
        ctx(active),
    )
    assert {m.target for m in plan.mutations} == {"a5"}  # friday = 2026-07-03


def test_bulk_date_ambiguous_asks():
    plan = reconcile([Bulk(op="drop", scope="date", when=When(kind="ambiguous"))], ctx(ACTIVE))
    assert not plan.mutations
    assert plan.questions


def test_bulk_no_match_changes_nothing():
    # A day with no items on it: scope resolves, but nothing matches.
    plan = reconcile(
        [Bulk(op="drop", scope="date", when=When(kind="month_day", month=7, day_num=20))],
        ctx(ACTIVE),
    )
    assert not plan.mutations
    assert plan.questions


def test_low_confidence_bulk_confirms_not_applies():
    # A sweeping mutation must not apply on a low-confidence guess.
    plan = reconcile([Bulk(op="drop", scope="all", confidence=0.2)], ctx(ACTIVE))
    assert not plan.mutations
    assert plan.confirm is not None and "confirm" in plan.confirm.question


def test_bulk_reschedule_moves_matching():
    plan = reconcile(
        [Bulk(op="reschedule", scope="all", when=When(kind="weekday", day="wed"))],
        ctx(ACTIVE),
    )
    assert {m.target for m in plan.mutations} == {"a1", "a2", "a3"}
    assert all(m.kind == "reschedule" and m.due_date == "2026-07-01" for m in plan.mutations)


def test_bulk_reschedule_unresolved_asks():
    plan = reconcile([Bulk(op="reschedule", scope="all", when=None)], ctx(ACTIVE))
    assert not plan.mutations and plan.questions


def test_bulk_reschedule_that_list_touches_only_presented_items():
    active = ACTIVE + [
        {"id": "a4", "label": "unrelated future", "due_date": "2026-07-10"},
        {"id": "a5", "label": "another future", "due_date": "2026-07-12"},
    ]
    plan = reconcile(
        [
            Bulk(
                op="reschedule",
                scope="all",
                when=When(kind="weekday", which="next", day="mon"),
                exclude=["a3"],
            ),
            Reschedule(
                target="a3",
                when=When(kind="weekday", which="next", day="sun"),
            ),
        ],
        ctx(
            active,
            message=(
                "move everything on that list to monday except the audit, "
                "that goes to sunday"
            ),
            presented=[
                {"id": "a1", "label": "org prez"},
                {"id": "a2", "label": "call the pool guy"},
                {"id": "a3", "label": "review SR audit"},
            ],
        ),
    )

    assert {mutation.target for mutation in plan.mutations} == {"a1", "a2", "a3"}
    assert all(mutation.target not in {"a4", "a5"} for mutation in plan.mutations)


def test_that_list_without_recent_presented_list_fails_closed():
    plan = reconcile(
        [Bulk(op="reschedule", scope="all", when=When(kind="tomorrow"))],
        ctx(ACTIVE, message="move everything on that list to tomorrow"),
    )
    assert not plan.mutations
    assert plan.questions == ["which list did you mean? i changed nothing."]


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


def test_recent_standalone_nevermind_overrides_model_but_stale_or_task_text_does_not():
    recent = ctx(message="Nevermind I'm good")
    recent.now = "2026-06-29T10:00:00-04:00"
    recent.last_change_at = "2026-06-29T09:55:00-04:00"
    plan = reconcile([Chitchat(reply="sounds good")], recent)
    assert plan.undo and plan.chitchat is None and not plan.mutations

    stale = ctx(message="Nevermind I'm good")
    stale.now = "2026-06-29T10:20:01-04:00"
    stale.last_change_at = "2026-06-29T10:00:00-04:00"
    assert not reconcile([Chitchat(reply="sounds good")], stale).undo

    task_text = ctx(message="never mind the taxes, pay rent")
    task_text.now = "2026-06-29T10:00:00-04:00"
    task_text.last_change_at = "2026-06-29T09:55:00-04:00"
    model_capture = Capture(task="pay rent", raw=task_text.message)
    result = reconcile([model_capture], task_text)
    assert not result.undo and [mutation.kind for mutation in result.mutations] == [
        "capture"
    ]


def test_note_wait_resume_reconcile():
    from core.models import Note, Resume, Wait

    plan = reconcile([Note(target="a1", text="gate code 4412")], ctx(ACTIVE))
    assert plan.mutations[0].kind == "note" and plan.mutations[0].note == "gate code 4412"
    plan = reconcile([Wait(target="2")], ctx(ACTIVE))
    assert plan.mutations[0].kind == "wait" and plan.mutations[0].target == "a2"
    waiting_active = [dict(a, waiting=(a["id"] == "a2")) for a in ACTIVE]
    plan = reconcile([Resume(target="a2")], ctx(waiting_active))
    assert plan.mutations[0].kind == "resume"


def test_capture_carries_waiting_and_note():
    plan = reconcile(
        [Capture(task="wait for plumber", raw="waiting on the plumber",
                 waiting=True, note="about the leak")],
        ctx(),
    )
    assert plan.mutations[0].waiting is True
    assert plan.mutations[0].note == "about the leak"


def test_waiting_capture_that_names_existing_item_becomes_wait_action():
    plan = reconcile(
        [
            Capture(
                task="the prez deck is waiting on sam's slides",
                raw="the prez deck is waiting on sam's slides",
                waiting=True,
            )
        ],
        ctx(ACTIVE, message="the prez deck is waiting on sam's slides"),
    )
    assert len(plan.mutations) == 1
    assert plan.mutations[0].kind == "wait"
    assert plan.mutations[0].target == "a1"


def test_waiting_new_task_with_one_shared_word_stays_a_capture():
    active = [
        {"id": "a1", "label": "draft quarterly report", "due_date": None}
    ]
    plan = reconcile(
        [
            Capture(
                task="new report from Sam",
                raw="new report is waiting on Sam",
                waiting=True,
            )
        ],
        ctx(active, message="new report is waiting on Sam"),
    )
    assert plan.mutations[0].kind == "capture"


def test_new_recurrence_misclassified_as_series_edit_is_recovered():
    plan = reconcile(
        [Recur(target="default", op="anchor", count=5)],
        ctx(
            ACTIVE,
            message="check the filters every 2 weeks after I finish, stop after 5 times",
        ),
    )
    mutation = plan.mutations[0]
    assert mutation.kind == "capture" and mutation.task == "check the filters"
    assert mutation.recurrence["frequency"] == "week"
    assert mutation.recurrence["interval"] == 2
    assert mutation.recurrence["anchor"] == "completion"
    assert mutation.recurrence["count"] == 5

    dropped_count = reconcile(
        [Capture(
            task="check the filters",
            raw="check the filters every 2 weeks after I finish, stop after 5 times",
            repeat="every:2:week",
        )],
        ctx(message="check the filters every 2 weeks after I finish, stop after 5 times"),
    )
    assert dropped_count.mutations[0].recurrence["anchor"] == "completion"
    assert dropped_count.mutations[0].recurrence["count"] == 5

    redundant_edit = reconcile(
        [
            Capture(
                task="check the filters every 2 weeks after I finish",
                raw=(
                    "check the filters every 2 weeks after I finish, "
                    "stop after 5 times"
                ),
                repeat="every:2:week",
            ),
            Recur(target="a2", op="stop", end=When(kind="offset", n=5)),
        ],
        ctx(
            ACTIVE,
            message=(
                "check the filters every 2 weeks after I finish, "
                "stop after 5 times"
            ),
        ),
    )
    assert [mutation.kind for mutation in redundant_edit.mutations] == ["capture"]
    assert redundant_edit.mutations[0].recurrence["anchor"] == "completion"
    assert redundant_edit.mutations[0].recurrence["count"] == 5


def test_resume_retargets_to_the_only_waiting_item():
    from core.models import Resume

    active = [
        {"id": "a1", "label": "grab milk", "due_date": None, "waiting": False},
        {"id": "a2", "label": "send jerry the contract", "due_date": None, "waiting": True},
    ]
    # Model picked the non-waiting focus item; the planner retargets.
    plan = reconcile([Resume(target="a1")], ctx(active))
    assert plan.mutations[0].kind == "resume" and plan.mutations[0].target == "a2"
    # With nothing waiting: a question, no mutation.
    none_waiting = [dict(a, waiting=False) for a in active]
    plan2 = reconcile([Resume(target="a1")], ctx(none_waiting))
    assert not plan2.mutations and plan2.questions


def test_weekday_in_message_beats_misclassified_intent():
    # The model read "monday" as tomorrow; the named weekday wins.
    plan = reconcile(
        [Capture(task="pay my taxes", raw="pay my taxes Monday", when=When(kind="tomorrow"))],
        ctx(message="Remind me to pay my taxes Monday"),
    )
    assert plan.mutations[0].due_date == "2026-07-06"  # next Monday, not 06-30


def test_reminder_prefix_stripped_from_label():
    plan = reconcile(
        [Capture(task="Remind me to pay my taxes", raw="remind me to pay my taxes")],
        ctx(message="Remind me to pay my taxes"),
    )
    assert plan.mutations[0].task == "pay my taxes"


def test_clean_label_strips_only_unambiguous_date_tails():
    from core.planner import _clean_label as c

    # stripped: unambiguous day/time tails the model left in the label
    assert c("update gdp tomorrow night") == "update gdp"
    assert c("call the vet at 3pm") == "call the vet"
    assert c("gdp tomorrow night at 9") == "gdp"
    assert c("meeting today") == "meeting"
    # kept: bare day/night/weekday words that are also real content
    assert c("plan my day tomorrow") == "plan my day"  # only "tomorrow" goes
    assert c("work the night shift") == "work the night shift"
    assert c("visit mystic aquarium during day") == "visit mystic aquarium during day"
    assert c("pay my taxes monday") == "pay my taxes monday"
    assert c("meet at gate 3") == "meet at gate 3"


def test_capture_label_and_date_from_intent_tail():
    # The screenshot case end to end: date is right, label is clean.
    plan = reconcile(
        [Capture(task="update gdp tomorrow night", raw="update gdp tomorrow night",
                 when=When(kind="tomorrow"), time="21:00")],
        ctx(message="update gdp tomorrow night"),
    )
    assert plan.mutations[0].task == "update gdp"
    assert plan.mutations[0].due_date == "2026-06-30"  # tomorrow
    assert plan.mutations[0].due_time == "21:00"


def test_complex_temporal_capture_keeps_a_clean_task_label():
    plan = reconcile(
        [
            Capture(
                task="draft the board report Friday; it is due Monday and takes three hours",
                raw="draft the board report Friday; it is due Monday and takes three hours",
                when=When(kind="weekday", day="fri"),
                duration_minutes=180,
                splittable=True,
            )
        ],
        ctx(message="draft the board report Friday; it is due Monday and takes three hours"),
    )
    assert plan.mutations[0].task == "draft the board report"
    assert plan.mutations[0].due_date == "2026-07-03"
    assert plan.mutations[0].deadline_date == "2026-07-06"


def test_bulk_complete_with_exclusions():
    plan = reconcile(
        [Bulk(op="complete", scope="today", exclude=["a3"])],
        ctx(ACTIVE, message="did everything today but the audit"),
    )
    assert {m.target for m in plan.mutations} == {"a1", "a2"}  # a3 spared
    # excluding everything applies nothing and says so
    plan2 = reconcile(
        [Bulk(op="complete", scope="all", exclude=["a1", "a2", "a3"])], ctx(ACTIVE)
    )
    assert not plan2.mutations and plan2.questions


def test_everything_but_inverts_a_lone_complete():
    # The model completed exactly the item the user excluded; the backstop
    # inverts it into a bulk over the rest.
    plan = reconcile(
        [Complete(target="a3", confidence=1.0)],
        ctx(ACTIVE, message="I did everything today but the SR audit"),
    )
    assert {m.target for m in plan.mutations} == {"a1", "a2"}
    assert all(m.kind == "complete" for m in plan.mutations)


def test_everything_but_resolves_a_noisy_excluded_target():
    plan = reconcile(
        [Complete(target="id: a1", confidence=1.0)],
        ctx(ACTIVE, message="I did everything today but the prez deck"),
    )
    assert {m.target for m in plan.mutations} == {"a2", "a3"}


def test_everything_but_fills_empty_bulk_exclude():
    plan = reconcile(
        [Bulk(op="complete", scope="today", exclude=[])],
        ctx(ACTIVE, message="did everything except the audit"),
    )
    assert {m.target for m in plan.mutations} == {"a1", "a2"}


def test_numbered_bulk_exclusions_override_mixed_model_actions():
    digest = [
        {"id": f"a{number}", "label": f"task {number}"}
        for number in range(1, 7)
    ]
    active = [digest[index] | {"due_date": None} for index in (0, 1, 3, 5)]
    plan = reconcile(
        [
            Complete(target="a1"),
            Complete(target="a2"),
            Note(target="a4", text="finished except for item 1 and item 6"),
        ],
        ctx(
            active,
            message="Finished it all except 1 and 6",
            digest=digest,
        ),
    )

    assert [(mutation.kind, mutation.target) for mutation in plan.mutations] == [
        ("complete", "a2"),
        ("complete", "a4"),
    ]
    for phrase in (
        "Finished it all except one and six please",
        "Finished it all except the first and sixth",
    ):
        alternate = reconcile(
            [Complete(target="a1")],
            ctx(active, message=phrase, digest=digest),
        )
        assert [mutation.target for mutation in alternate.mutations] == [
            "a2",
            "a4",
        ]


def test_numbered_bulk_exclusion_outside_displayed_list_changes_nothing():
    digest = [
        {"id": f"a{number}", "label": f"task {number}"}
        for number in range(1, 5)
    ]
    active = [item | {"due_date": None} for item in digest]
    plan = reconcile(
        [Complete(target="a1"), Complete(target="a2")],
        ctx(
            active,
            message="Finished it all except 1 and 6",
            digest=digest,
        ),
    )

    assert not plan.mutations
    assert plan.questions


def test_position_reference_does_not_shift_after_a_digest_item_closes():
    digest = [
        {"id": "a1", "label": "first task"},
        {"id": "a2", "label": "second task"},
        {"id": "a3", "label": "third task"},
    ]
    active = [
        {"id": "a2", "label": "second task", "due_date": None},
        {"id": "a3", "label": "third task", "due_date": None},
    ]

    plan = reconcile(
        [Complete(target="2")],
        ctx(active, message="done 2", digest=digest),
    )

    assert [(mutation.kind, mutation.target) for mutation in plan.mutations] == [
        ("complete", "a2")
    ]


def test_everything_but_repairs_an_incomplete_model_proposal():
    # The model proposed only one included item, but the literal bulk contract
    # still owns the complete set.
    plan = reconcile(
        [Complete(target="a1", confidence=1.0)],
        ctx(ACTIVE, message="I did everything today but the SR audit"),
    )
    assert {m.target for m in plan.mutations} == {"a1", "a2"}


def test_bulk_today_excludes_waiting():
    active = [
        {"id": "a1", "label": "x", "due_date": None, "waiting": False},
        {"id": "a2", "label": "parked", "due_date": None, "waiting": True},
    ]
    plan = reconcile([Bulk(op="complete", scope="today")], ctx(active))
    assert {m.target for m in plan.mutations} == {"a1"}


def test_query_waiting_kind():
    plan = reconcile([Query(kind="waiting")], ctx(ACTIVE))
    assert plan.queries[0].kind == "waiting"


def test_chitchat_sets_reply():
    plan = reconcile([Chitchat(reply="anytime!")], ctx())
    assert plan.chitchat == "anytime!"
    assert not plan.mutations and not plan.questions


def test_typed_zero_completion_recap_acknowledges_noop_in_eod_context():
    plan = reconcile(
        [Recap(outcome="none", confidence=1.0)],
        ctx(
            ACTIVE,
            message="nada",
            presented=ACTIVE[:2],
            presented_kind="eod",
        ),
    )
    assert not plan.mutations
    assert plan.acknowledgement == (
        "okay. nothing marked done. both items stay open on deck."
    )
    assert not plan.questions


def test_contradictory_zero_recap_proposal_does_not_hide_a_completion():
    plan = reconcile(
        [
            Recap(outcome="none", confidence=1.0),
            Complete(target="a2", confidence=1.0),
        ],
        ctx(
            ACTIVE,
            message="Nothing got done on taxes, but I finished the pool call",
            presented=ACTIVE[:2],
            presented_kind="eod",
        ),
    )
    assert plan.acknowledgement is None
    assert [(m.kind, m.target) for m in plan.mutations] == [("complete", "a2")]


def test_recap_requires_machine_owned_eod_context_and_confidence():
    plan = reconcile(
        [Recap(outcome="none", confidence=1.0)],
        ctx(ACTIVE, message="nada", presented=ACTIVE[:2]),
    )
    assert plan.acknowledgement is None
    assert plan.questions

    low = reconcile(
        [Recap(outcome="none", confidence=0.2)],
        ctx(
            ACTIVE,
            message="nada",
            presented=ACTIVE[:2],
            presented_kind="eod",
        ),
    )
    assert low.acknowledgement is None and low.questions


def test_misclassified_recap_does_not_override_setup_or_forwarding():
    setup = reconcile(
        [Recap(outcome="none")],
        ctx(
            ACTIVE,
            message="none",
            presented=ACTIVE[:2],
            presented_kind="eod",
            pending=[{"kind": "setting", "key": "break_window"}],
        ),
    )
    assert setup.acknowledgement is None
    assert not setup.settings and setup.questions

    clarification = reconcile(
        [Recap(outcome="none")],
        ctx(
            ACTIVE,
            message="none",
            presented=ACTIVE[:2],
            presented_kind="eod",
            pending=[{
                "kind": "capture",
                "question": "when is call mom due?",
                "task": "call mom",
            }],
        ),
    )
    assert clarification.acknowledgement is None
    assert not clarification.mutations and clarification.questions

    forwarded = reconcile(
        [Recap(outcome="none")],
        ctx(
            ACTIVE,
            message="Nothing got done",
            presented=ACTIVE[:2],
            presented_kind="eod",
            forwarded="Sam",
        ),
    )
    assert forwarded.acknowledgement is None
    assert not forwarded.mutations and forwarded.questions


def test_typo_correction_acked_not_nagged():
    from core.planner import _is_typo_correction as f

    assert f("Hobbie*") and f("friday not thursday*")
    assert not f("*") and not f("call bob")
    assert not f("send the whole quarterly report by end of friday*")  # too long

    plan = reconcile([Unknown(note="?")], ctx(message="Hobbie*"))
    assert plan.chitchat is not None and not plan.questions
    # a genuinely unclear message still asks
    plain = reconcile([Unknown(note="?")], ctx(message="asdfghjkl"))
    assert plain.questions and plain.chitchat is None


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


def test_planning_frame_settings_parse_ranges_deterministically():
    plan = reconcile(
        [
            Setting(key="work_hours", raw="9 to 5"),
            Setting(key="break_window", raw="noon to 1"),
        ],
        ctx(),
    )
    assert [(s.key, s.value) for s in plan.settings] == [
        ("work_hours", "09:00-17:00"),
        ("break_window", "12:00-13:00"),
    ]


def test_effort_and_buffer_settings_parse_and_validate_minutes():
    plan = reconcile(
        [
            Setting(key="default_duration", raw="assume 45 minutes"),
            Setting(key="transition_buffer", raw="leave 10 minutes"),
        ],
        ctx(),
    )
    assert [(s.key, s.value) for s in plan.settings] == [
        ("default_duration", "45"),
        ("transition_buffer", "10"),
    ]
    no_buffer = reconcile(
        [Setting(key="transition_buffer", raw="no buffer")], ctx()
    )
    assert no_buffer.settings[0].value == "0"
    invalid = reconcile(
        [Setting(key="default_duration", raw="900 minutes")], ctx()
    )
    assert not invalid.settings and invalid.pending


def test_work_days_setting_parses_ranges_every_day_exclusions_and_invalid():
    for raw, expected in (
        ("weekdays", "mon,tue,wed,thu,fri"),
        ("monday through saturday", "mon,tue,wed,thu,fri,sat"),
        ("every day except sunday", "mon,tue,wed,thu,fri,sat"),
        ("weekends", "sat,sun"),
        ("not weekends", "mon,tue,wed,thu,fri"),
        ("weekdays and saturday", "mon,tue,wed,thu,fri,sat"),
        ("monday through friday but not wednesday", "mon,tue,thu,fri"),
    ):
        plan = reconcile([Setting(key="work_days", raw=raw)], ctx())
        assert plan.settings[0].value == expected
    invalid = reconcile([Setting(key="work_days", raw="never")], ctx())
    assert not invalid.settings and invalid.pending[0].key == "work_days"


def test_query_today_and_all():
    plan = reconcile([Query(kind="today")], ctx(ACTIVE))
    assert plan.queries[0].kind == "today"
    plan = reconcile([Query(kind="all")], ctx(ACTIVE))
    assert plan.queries[0].kind == "all"


def test_query_date_from_intent():
    # The day comes from the query's date intent; the core does the math.
    plan = reconcile([Query(kind="date", when=When(kind="tomorrow"))], ctx(ACTIVE))
    assert plan.queries[0].kind == "date"
    assert plan.queries[0].date == "2026-06-30"


def test_plan_query_resolves_named_day_and_refuses_past_day():
    tomorrow = reconcile(
        [Query(kind="plan", when=When(kind="tomorrow"), constraint="plan tomorrow")],
        ctx(ACTIVE, message="plan tomorrow"),
    )
    assert tomorrow.queries[0].kind == "plan"
    assert tomorrow.queries[0].date == "2026-06-30"
    yesterday = reconcile(
        [Query(kind="plan", when=When(kind="yesterday"))],
        ctx(ACTIVE, message="plan yesterday"),
    )
    assert not yesterday.queries
    assert "today or later" in yesterday.questions[0]
    misclassified = reconcile(
        [Query(kind="date", when=When(kind="tomorrow"))],
        ctx(ACTIVE, message="plan tomorrow"),
    )
    assert misclassified.queries[0].kind == "plan"
    assert misclassified.queries[0].date == "2026-06-30"
    status = reconcile(
        [Query(kind="today")], ctx(ACTIVE, message="what is on my plan?")
    )
    assert status.queries[0].kind == "plan_status"


def test_outlook_literal_backstop_corrects_flat_week_query():
    plan = reconcile(
        [Query(kind="week")],
        ctx(ACTIVE, message="what won't fit this week?"),
    )
    assert len(plan.queries) == 1
    assert plan.queries[0].kind == "outlook"
    assert "fit this week" in plan.queries[0].constraint

    deadline = reconcile(
        [Query(kind="outlook")],
        ctx(ACTIVE, message="can I finish everything by Friday?"),
    )
    assert deadline.queries[0].date == "2026-07-03"


def test_plan_actions_have_literal_consent_backstops():
    for message, expected in (
        ("use this plan", "adopt"),
        ("replace my plan with this", "replace"),
        ("cancel my plan", "cancel"),
    ):
        plan = reconcile([Unknown()], ctx(ACTIVE, message=message))
        assert plan.plan_action == expected
    low = reconcile(
        [PlanAction(op="adopt", confidence=0.2)],
        ctx(ACTIVE, message="maybe use it"),
    )
    assert low.plan_action is None and low.questions


def test_session_nudge_interruption_becomes_replan_not_anchored_task_mutation():
    plan = reconcile(
        [Reschedule(target="a2", time="10:00")],
        ctx(
            ACTIVE,
            message="meeting ran over, I got interrupted; replan",
            replied={"id": "a2", "label": "call the pool guy"},
        ),
    )
    assert not plan.mutations
    assert len(plan.queries) == 1 and plan.queries[0].kind == "plan"
    assert "interrupted" in plan.queries[0].constraint


def test_query_today_intent_is_today_query():
    plan = reconcile([Query(kind="date", when=When(kind="today"))], ctx(ACTIVE))
    assert plan.queries[0].kind == "today"


def test_query_dropped_tomorrow_corrected():
    # "What about tomorrow" came back as a bare today query; the day word wins.
    plan = reconcile(
        [Query(kind="today", when=None)], ctx(ACTIVE, message="What about tomorrow")
    )
    assert plan.queries[0].kind == "date"
    assert plan.queries[0].date == "2026-06-30"


def test_capture_dated_from_intent():
    # A lone capture's date comes straight from its typed intent.
    plan = reconcile(
        [Capture(task="harass Jerry", raw="harass Jerry tomorrow", when=When(kind="tomorrow"))],
        ctx(),
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
    plan = reconcile(
        [Capture(task="take out the trash", raw="in 200 years",
                 when=When(kind="offset", n=200, unit="year"))],
        ctx(),
    )
    assert not plan.mutations
    assert plan.confirm is not None
    assert plan.confirm.mutations[0].kind == "capture"
    assert "years out" in plan.confirm.question


def test_capture_near_future_applies():
    # A couple of years out is plausible; apply without confirming.
    plan = reconcile(
        [Capture(task="renew passport", raw="in 2 years",
                 when=When(kind="offset", n=2, unit="year"))],
        ctx(),
    )
    assert plan.mutations and plan.confirm is None


def test_reschedule_far_future_confirms():
    plan = reconcile(
        [Reschedule(target="a3", when=When(kind="offset", n=100, unit="year"), confidence=0.9)],
        ctx(ACTIVE),
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
        [Capture(task="bring soda", raw="bring soda Friday",
                 when=When(kind="weekday", which="next", day="fri"), relate="a3")],
        ctx(ACTIVE),
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
    assert not plan.mutations and plan.confirm is not None


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
        Reschedule(target="a3", when=When(kind="weekday", which="next", day="fri"), confidence=0.9),
    ]
    plan = reconcile(actions, ctx(ACTIVE))
    kinds = [m.kind for m in plan.mutations]
    assert kinds == ["complete", "drop", "reschedule"]
    assert not plan.questions


# --- reference-verification guards: the model can name the wrong target on a
# terse completion, or read a negation as an action. The core checks the target
# against the literal words before mutating.

TAXES = [
    {"id": "a1", "label": "pay my taxes Monday", "due_date": "2026-07-06", "waiting": False},
    {"id": "a2", "label": "finish the MOR slides", "due_date": None, "waiting": False},
    {"id": "a3", "label": "send Jerry the message", "due_date": None, "waiting": False},
]


def test_negation_suppresses_completion_of_the_negated_item():
    # "did not pay taxes" must not mark the taxes task done.
    plan = reconcile([Complete(target="a1")], ctx(TAXES, message="did not pay taxes"))
    assert not plan.mutations
    assert not plan.questions


def test_negation_keeps_the_positive_half_of_a_compound():
    # "did the slides but not the taxes" -> slides done, taxes untouched.
    plan = reconcile(
        [Complete(target="a2"), Complete(target="a1")],
        ctx(TAXES, message="did the slides but not the taxes"),
    )
    assert [(m.kind, m.target) for m in plan.mutations] == [("complete", "a2")]


def test_negation_drops_a_recaptured_negated_task():
    # The model sometimes re-captures the thing you said you did NOT do.
    plan = reconcile(
        [Complete(target="a2"),
         Capture(task="pay my taxes Monday", raw="pay my taxes Monday")],
        ctx(TAXES, message="did the slides but not the taxes"),
    )
    assert [(m.kind, m.target) for m in plan.mutations] == [("complete", "a2")]


def test_negation_drops_a_capture_that_is_only_the_negation():
    plan = reconcile(
        [Capture(task="did not pay taxes", raw="did not pay taxes")],
        ctx(TAXES, message="did not pay taxes"),
    )
    assert not plan.mutations


def test_legit_capture_survives_alongside_a_negation():
    # A genuinely new task in a message that also negates something is kept.
    plan = reconcile(
        [Capture(task="buy milk", raw="buy milk")],
        ctx(TAXES, message="buy milk, did not pay the taxes"),
    )
    assert [m.kind for m in plan.mutations] == ["capture"]


def test_wrong_target_completion_asks_did_you_mean():
    # An Unknown where the words fuzzy-match an item -> confirm, not silence.
    plan = reconcile(
        [Unknown()],
        ctx([{"id": "a1", "label": "on Tuesday fable goes away", "due_date": None,
              "waiting": False}],
            message="finished the fabel thing"),
    )
    assert plan.confirm is not None
    assert plan.confirm.mutations[0].kind == "complete"
    assert plan.confirm.mutations[0].target == "a1"
