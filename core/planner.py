# SPDX-License-Identifier: MIT
"""Planner: reconciled Actions plus context -> concrete mutations and questions.

Pure, no I/O. This is where correctness lives: the model's output is a proposal,
not a command.

- Dates: the model never proposes a resolved date; it classifies the phrase into
  a typed intent and core.dates.resolve_intent does the calendar math. The model
  owns understanding, the core owns arithmetic. An intent of kind "ambiguous"
  produces a clarifying question and applies nothing; an unresolvable intent on a
  reschedule also asks.
- References: every target must match a real id in the active list, and
  confidence must clear the threshold; otherwise ask, never mutate.

Mutations are intents, not finished items: the planner is pure, so it cannot
allocate ids or read the clock. The edge (MessageService) materializes them.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, timedelta

from core import dates, recurrence
from core.models import (
    Amend,
    Bulk,
    Capture,
    Complete,
    Drop,
    Prioritize,
    Query,
    Reschedule,
    Setting,
    Undo,
    Unknown,
)

# Below this, a reference-bearing action (complete/drop/reschedule) is treated as
# a guess and asked about rather than applied.
CONFIDENCE_THRESHOLD = 0.5

# A resolved date further out than this is probably a typo or a joke ("in 200
# years"); confirm before applying rather than scheduling it silently.
FAR_FUTURE_DAYS = 365 * 5


@dataclass
class Mutation:
    kind: str  # capture | complete | drop | reschedule | amend | prioritize
    task: str | None = None
    raw: str | None = None
    due_date: str | None = None
    due_time: str | None = None
    target: str | None = None
    reason: str | None = None
    repeat: str | None = None  # recurrence rule for a capture
    priority: str | None = None  # high|normal|low, for capture and prioritize
    tag: str | None = None  # project/list for a capture


@dataclass
class QueryIntent:
    kind: str  # today | date | all | overdue | week | search | done | tag
    date: str | None = None  # ISO; for date, or the period start for done
    term: str | None = None  # search keywords, for kind=search
    tag: str | None = None  # project/list name, for kind=tag


@dataclass
class SettingChange:
    key: str  # wake_time
    value: str  # validated value, e.g. "06:30"


@dataclass
class Pending:
    """A clarification Hob is waiting on, persisted between turns so a short
    reply ("thursday") can be resolved against the question it answers. Only the
    resumable cases (a capture or reschedule whose date was unclear) become
    Pending; reference errors and hallucinated reschedules do not."""

    kind: str  # capture | reschedule
    question: str
    task: str | None = None  # capture: the clean label to re-capture
    target: str | None = None  # reschedule: the item id
    label: str | None = None  # reschedule: human label, for the next prompt


@dataclass
class ConfirmIntent:
    """Mutations held back for a yes/no. The edge persists them and applies them
    only if the next message confirms. Used for a sweeping delete and for an
    implausibly far-out date that is probably a typo."""

    mutations: list[Mutation] = field(default_factory=list)
    question: str = ""


@dataclass
class Plan:
    mutations: list[Mutation] = field(default_factory=list)
    questions: list[str] = field(default_factory=list)
    queries: list[QueryIntent] = field(default_factory=list)
    pending: list[Pending] = field(default_factory=list)
    confirm: ConfirmIntent | None = None
    undo: bool = False  # the user asked to undo the last change
    settings: list[SettingChange] = field(default_factory=list)


def _too_far(due_iso: str, today: date) -> int | None:
    """If a resolved date is implausibly far out, the rough number of years out;
    otherwise None."""
    try:
        days = (date.fromisoformat(due_iso) - today).days
    except (TypeError, ValueError):
        return None
    return round(days / 365) if days > FAR_FUTURE_DAYS else None


def _hold(plan: Plan, mutation: Mutation, question: str) -> None:
    """Stash a mutation for yes/no confirmation instead of applying it."""
    if plan.confirm is None:
        plan.confirm = ConfirmIntent()
    plan.confirm.mutations.append(mutation)
    plan.confirm.question = question


_NUM_WORDS = {
    "one": "1", "first": "1", "two": "2", "second": "2", "three": "3",
    "third": "3", "four": "4", "fourth": "4", "five": "5", "fifth": "5",
    "six": "6", "sixth": "6", "seven": "7", "seventh": "7", "eight": "8",
    "eighth": "8", "nine": "9", "ninth": "9", "ten": "10", "tenth": "10",
}


def _resolve_ref(ref: str, active: dict, by_pos: dict) -> str | None:
    """Map a target/relate reference to a stored id, tolerating the forms the
    model emits: an id (a1, any case), a list position (2), a stray "id:"/"#"
    prefix, a spelled ordinal (first/second), or the whole "id: label (due ...)"
    line copied verbatim (we take the leading token)."""
    if not ref:
        return None
    r = ref.strip().lower().removeprefix("id:").removeprefix("#").strip()
    r = _NUM_WORDS.get(r, r)
    if r in active:
        return r
    if r in by_pos:
        return by_pos[r]  # a 1-based list position
    # The model sometimes copies the whole list line ("a3: review the SR audit");
    # the id or position it put first still identifies the item.
    head = r.replace(":", " ").split()
    if head:
        first = _NUM_WORDS.get(head[0], head[0])
        if first in active:
            return first
        return by_pos.get(first)
    return None


def _check_target(
    target: str, confidence: float, active: dict, by_pos: dict, plan: Plan
) -> str | None:
    """Validate a reference. Queue a question and return None if it does not
    resolve confidently; otherwise return the id. Accepts an id or a position."""
    key = _resolve_ref(target, active, by_pos)
    if key is None:
        plan.questions.append("i could not find that item. check /today for the list.")
        return None
    if confidence < CONFIDENCE_THRESHOLD:
        plan.questions.append(f'did you mean: "{active[key]}"?')
        return None
    return key


def _reconcile_capture(
    action: Capture,
    today: date,
    shared_date: str | None,
    active_due: dict,
    by_pos: dict,
    plan: Plan,
) -> None:
    resolution = dates.resolve_intent(action.when, today)
    if resolution.date is None and not resolution.ambiguous and shared_date is not None:
        # A leading date shared across a multi-task message (computed above).
        resolution = dates.DateResolution(date=shared_date)

    if resolution.ambiguous:
        question = f'when is "{action.task}" due? that read as more than one date.'
        plan.questions.append(question)
        plan.pending.append(
            Pending(kind="capture", question=question, task=action.task)
        )
        return

    due_date = resolution.date
    if due_date is None and action.relate:
        # A task for an existing item (e.g. "bring soda" for a birthday) with no
        # date of its own inherits that item's date so it surfaces with it.
        rid = _resolve_ref(action.relate, active_due, by_pos)
        due_date = active_due.get(rid) if rid else None

    repeat = recurrence.normalize(action.repeat)
    if repeat is not None:
        # A recurring task's date is its next occurrence, decided by the rule.
        first = recurrence.next_due(repeat, today, inclusive=True)
        if first is not None:
            due_date = first.isoformat()

    # The model classifies dates (when); a clock time it parses directly (time).
    due_time = dates.parse_time(action.time)

    mutation = Mutation(
        kind="capture",
        task=action.task,
        raw=action.raw,
        due_date=due_date,
        due_time=due_time,
        repeat=repeat,
        priority=action.priority,
        tag=action.tag,
    )
    years = _too_far(due_date, today) if due_date else None
    if years is not None:
        _hold(plan, mutation, f"that is {due_date}, about {years} years out. reply yes to keep it.")
        return
    plan.mutations.append(mutation)


def _reconcile_amend(action: Amend, active: dict, by_pos: dict, plan: Plan) -> None:
    target = _check_target(action.target, action.confidence, active, by_pos, plan)
    if target is None:
        return
    if not action.task:
        plan.questions.append(f'what should "{active[target]}" say now?')
        return
    plan.mutations.append(Mutation(kind="amend", target=target, task=action.task))


def _reconcile_setting(action: Setting, plan: Plan) -> None:
    if action.key == "wake_time":
        value = dates.parse_time(action.raw)
        if value is None:
            plan.questions.append("what time should i send the morning digest?")
            return
        plan.settings.append(SettingChange(key="wake_time", value=value))
    else:
        plan.questions.append("i can only change the wake time right now.")


def _reconcile_prioritize(
    action: Prioritize, active: dict, by_pos: dict, plan: Plan
) -> None:
    target = _check_target(action.target, action.confidence, active, by_pos, plan)
    if target is None:
        return
    level = action.level if action.level in ("high", "normal", "low") else "normal"
    plan.mutations.append(Mutation(kind="prioritize", target=target, priority=level))


def _reconcile_reschedule(
    action: Reschedule, today: date, active: dict, by_pos: dict, plan: Plan
) -> None:
    target = _check_target(action.target, action.confidence, active, by_pos, plan)
    if target is None:
        return
    label = active[target]

    resolution = dates.resolve_intent(action.when, today)

    if resolution.ambiguous:
        question = f'when should i move "{label}" to? that read as more than one date.'
        plan.questions.append(question)
        plan.pending.append(
            Pending(kind="reschedule", question=question, target=target, label=label)
        )
        return
    if resolution.date is None:
        question = f'to when should i move "{label}"?'
        plan.questions.append(question)
        plan.pending.append(
            Pending(kind="reschedule", question=question, target=target, label=label)
        )
        return

    mutation = Mutation(kind="reschedule", target=target, due_date=resolution.date)
    years = _too_far(resolution.date, today)
    if years is not None:
        _hold(plan, mutation, f'move "{label}" to {resolution.date}, about {years} years out. reply yes to keep it.')
        return
    plan.mutations.append(mutation)


def _in_scope(item: dict, scope: str, today: str, target_date: str | None) -> bool:
    """Whether an open item falls in a bulk action's scope. 'today' mirrors the
    digest's on-deck set: undated, due today, or overdue (future excluded)."""
    due = item.get("due_date")
    if scope == "all":
        return True
    if scope == "date":
        return due == target_date
    return due is None or due <= today


def _reconcile_bulk(action: Bulk, today: date, ctx, plan: Plan) -> None:
    if action.op not in ("complete", "drop", "reschedule"):
        plan.questions.append("i did not catch a task there. can you rephrase?")
        return
    scope = action.scope if action.scope in ("today", "all", "date") else "today"
    when = dates.resolve_intent(action.when, today)
    target_date = None
    if scope == "date":
        if when.ambiguous or when.date is None:
            plan.questions.append("which day did you mean?")
            return
        target_date = when.date
    matching = [
        i for i in ctx.active_items if _in_scope(i, scope, ctx.today, target_date)
    ]
    if not matching:
        plan.questions.append("nothing matched, so i changed nothing.")
        return
    ids = [i["id"] for i in matching]
    if action.op == "reschedule":
        # Move them all to one destination date (non-destructive, so no confirm).
        if when.ambiguous or when.date is None:
            plan.questions.append("to when should i move them?")
            return
        for item_id in ids:
            plan.mutations.append(
                Mutation(kind="reschedule", target=item_id, due_date=when.date)
            )
        return
    if action.confidence < CONFIDENCE_THRESHOLD:
        # A sweeping mutation is the last place to guess; confirm, never apply.
        verb = "finish" if action.op == "complete" else "drop"
        plan.questions.append(f"that would {verb} {len(ids)} open item(s). confirm?")
        return
    # Deleting across more than one day is a big swing: hold it for a yes/no.
    if action.op == "drop":
        days = {(i.get("due_date") or "undated") for i in matching}
        if len(days) > 1:
            plan.confirm = ConfirmIntent(
                mutations=[Mutation(kind="drop", target=i) for i in ids],
                question=(
                    f"that deletes {len(ids)} items across {len(days)} days. "
                    "reply yes to confirm."
                ),
            )
            return
    for item_id in ids:
        plan.mutations.append(Mutation(kind=action.op, target=item_id))


def _reconcile_query(action: Query, today: date, ctx, plan: Plan) -> None:
    kind, term = action.kind, action.term
    if kind == "done":
        # "what did I finish": this week -> last 7 days, otherwise today.
        start = today - timedelta(days=6) if "week" in ctx.message.lower() else today
        plan.queries.append(QueryIntent(kind="done", date=start.isoformat()))
        return
    if term:
        # "anything about X" -> search, even if the model also guessed a tag.
        plan.queries.append(QueryIntent(kind="search", term=term))
        return
    if kind == "search":  # asked to search but gave no term
        plan.queries.append(QueryIntent(kind="all"))
        return
    if kind == "tag" and action.tag:
        plan.queries.append(QueryIntent(kind="tag", tag=action.tag))
        return
    if kind in ("overdue", "week"):
        plan.queries.append(QueryIntent(kind=kind))
        return
    model_kind = kind if kind in ("today", "date", "all") else "today"
    # A specific day named in the query (its when intent) is a date query for
    # that day; today -> today query.
    resolution = dates.resolve_intent(action.when, today)
    if resolution.ambiguous:
        plan.questions.append("which day did you mean?")
        return
    if resolution.date is not None:
        if resolution.date == today.isoformat():
            plan.queries.append(QueryIntent(kind="today"))
        else:
            plan.queries.append(QueryIntent(kind="date", date=resolution.date))
        return
    if model_kind == "date":
        # model wanted a specific day but the message names none
        plan.questions.append("which day did you mean?")
        return
    plan.queries.append(QueryIntent(kind=model_kind))


def reconcile(actions: list, ctx) -> Plan:
    today = date.fromisoformat(ctx.today)
    active = {i["id"]: i.get("label", "") for i in ctx.active_items}
    plan = Plan()
    captures = [a for a in actions if isinstance(a, Capture)]
    n_captures = len(captures)
    active_due = {i["id"].lower(): i.get("due_date") for i in ctx.active_items}
    # 1-based position -> id, so a typed "drop 2" resolves to the displayed item.
    by_pos = {str(n): i["id"] for n, i in enumerate(ctx.active_items, start=1)}
    # A date at the START of a multi-task message ("Tomorrow I need to A, B, C")
    # applies to all the tasks; the model attaches it to the first one and leaves
    # the rest with no date. Detect the leading date in the text, then take the
    # actual date from the first task's intent (exact math). A trailing date
    # ("call A and email B tomorrow") is not at the start, so it is not shared.
    shared_date = None
    if n_captures > 1 and dates.leading_date(ctx.message, today) is not None:
        first = dates.resolve_intent(captures[0].when, today)
        shared_date = first.date or dates.leading_date(ctx.message, today)
    for action in actions:
        if isinstance(action, Capture):
            _reconcile_capture(action, today, shared_date, active_due, by_pos, plan)
        elif isinstance(action, Amend):
            _reconcile_amend(action, active, by_pos, plan)
        elif isinstance(action, Prioritize):
            _reconcile_prioritize(action, active, by_pos, plan)
        elif isinstance(action, Setting):
            _reconcile_setting(action, plan)
        elif isinstance(action, Complete):
            target = _check_target(action.target, action.confidence, active, by_pos, plan)
            if target is not None:
                plan.mutations.append(Mutation(kind="complete", target=target))
        elif isinstance(action, Drop):
            target = _check_target(action.target, action.confidence, active, by_pos, plan)
            if target is not None:
                plan.mutations.append(
                    Mutation(kind="drop", target=target, reason=action.reason)
                )
        elif isinstance(action, Reschedule):
            _reconcile_reschedule(action, today, active, by_pos, plan)
        elif isinstance(action, Query):
            _reconcile_query(action, today, ctx, plan)
        elif isinstance(action, Bulk):
            _reconcile_bulk(action, today, ctx, plan)
        elif isinstance(action, Undo):
            plan.undo = True
        elif isinstance(action, Unknown):
            plan.questions.append("i did not catch a task there. can you rephrase?")
    return plan
