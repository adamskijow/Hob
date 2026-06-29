# SPDX-License-Identifier: MIT
"""Planner: reconciled Actions plus context -> concrete mutations and questions.

Pure, no I/O. This is where correctness lives: the model's output is a proposal,
not a command.

- Dates: the model never proposes a resolved date; the new date is re-resolved
  from the raw phrasing (core.dates). The parser owns dates entirely. Ambiguity
  (more than one date in the phrase) produces a clarifying question and applies
  nothing; a reschedule whose phrase resolves to nothing also asks.
- Reschedule guard: the model is told to copy date words verbatim, so a date
  phrase that does not actually appear in the message is a hallucination (a
  question or a plain capture misread as a reschedule). The planner asks rather
  than moving anything.
- References: every target must match a real id in the active list, and
  confidence must clear the threshold; otherwise ask, never mutate.

Mutations are intents, not finished items: the planner is pure, so it cannot
allocate ids or read the clock. The edge (MessageService) materializes them.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date

from core import dates
from core.models import Bulk, Capture, Complete, Drop, Query, Reschedule, Unknown

# Below this, a reference-bearing action (complete/drop/reschedule) is treated as
# a guess and asked about rather than applied.
CONFIDENCE_THRESHOLD = 0.5

_WORD = re.compile(r"\w+")


def _phrase_in_message(phrase: str, message: str) -> bool:
    """True if every word of the model's date phrase appears in the message.
    The prompt tells the model to copy date words verbatim; a phrase absent from
    the message is a hallucination, so the caller asks instead of mutating."""
    words = _WORD.findall(phrase.lower())
    if not words:
        return False
    haystack = set(_WORD.findall(message.lower()))
    return all(w in haystack for w in words)


@dataclass
class Mutation:
    kind: str  # capture | complete | drop | reschedule
    task: str | None = None
    raw: str | None = None
    due_date: str | None = None
    due_time: str | None = None
    target: str | None = None
    reason: str | None = None


@dataclass
class QueryIntent:
    kind: str  # today | date | all
    date: str | None = None


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
class Plan:
    mutations: list[Mutation] = field(default_factory=list)
    questions: list[str] = field(default_factory=list)
    queries: list[QueryIntent] = field(default_factory=list)
    pending: list[Pending] = field(default_factory=list)


def _check_target(target: str, confidence: float, active: dict, plan: Plan) -> str | None:
    """Validate a reference. Queue a question and return None if it does not
    resolve confidently; otherwise return the id."""
    if target not in active:
        open_ids = ", ".join(active) if active else "none"
        plan.questions.append(f"i could not find that item. open: {open_ids}.")
        return None
    if confidence < CONFIDENCE_THRESHOLD:
        plan.questions.append(f"did you mean: {active[target]}?")
        return None
    return target


def _reconcile_capture(action: Capture, today: date, plan: Plan) -> None:
    resolution = dates.resolve(action.raw, today)

    if resolution.ambiguous:
        question = (
            f'when is "{action.task}" due? i read more than one date '
            f'in "{action.raw}".'
        )
        plan.questions.append(question)
        plan.pending.append(
            Pending(kind="capture", question=question, task=action.task)
        )
        return

    plan.mutations.append(
        Mutation(
            kind="capture",
            task=action.task,
            raw=action.raw,
            due_date=resolution.date,
            due_time=resolution.time,
        )
    )


def _reconcile_reschedule(
    action: Reschedule, today: date, active: dict, message: str, plan: Plan
) -> None:
    target = _check_target(action.target, action.confidence, active, plan)
    if target is None:
        return
    label = active[target]

    if not _phrase_in_message(action.raw, message):
        # Likely a hallucination (a question or capture misread as a reschedule).
        # Ask, but do not make it resumable: a stray "friday" next turn must not
        # move this item.
        plan.questions.append(f'did you want to move "{label}"? if so, to when?')
        return

    resolution = dates.resolve(action.raw, today)

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

    plan.mutations.append(
        Mutation(kind="reschedule", target=target, due_date=resolution.date)
    )


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
    if action.op not in ("complete", "drop"):
        plan.questions.append("i did not catch a task there. can you rephrase?")
        return
    scope = action.scope if action.scope in ("today", "all", "date") else "today"
    target_date = None
    if scope == "date":
        # Never trust a model date; re-resolve the day from the message.
        resolution = dates.resolve(ctx.message, today)
        if resolution.ambiguous or resolution.date is None:
            plan.questions.append("which day did you mean?")
            return
        target_date = resolution.date
    matching = [
        i["id"]
        for i in ctx.active_items
        if _in_scope(i, scope, ctx.today, target_date)
    ]
    if not matching:
        plan.questions.append("nothing matched, so i changed nothing.")
        return
    if action.confidence < CONFIDENCE_THRESHOLD:
        # A sweeping mutation is the last place to guess; confirm, never apply.
        verb = "finish" if action.op == "complete" else "drop"
        plan.questions.append(f"that would {verb} {len(matching)} open item(s). confirm?")
        return
    for item_id in matching:
        plan.mutations.append(Mutation(kind=action.op, target=item_id))


def _reconcile_query(action: Query, today: date, ctx, plan: Plan) -> None:
    kind = action.kind if action.kind in ("today", "date", "all") else "today"
    if kind != "date":
        plan.queries.append(QueryIntent(kind=kind))
        return
    # Never trust a model date; re-resolve the day from the message itself.
    resolution = dates.resolve(ctx.message, today)
    if resolution.ambiguous or resolution.date is None:
        plan.questions.append("which day did you mean?")
        return
    plan.queries.append(QueryIntent(kind="date", date=resolution.date))


def reconcile(actions: list, ctx) -> Plan:
    today = date.fromisoformat(ctx.today)
    active = {i["id"]: i.get("label", "") for i in ctx.active_items}
    plan = Plan()
    for action in actions:
        if isinstance(action, Capture):
            _reconcile_capture(action, today, plan)
        elif isinstance(action, Complete):
            target = _check_target(action.target, action.confidence, active, plan)
            if target is not None:
                plan.mutations.append(Mutation(kind="complete", target=target))
        elif isinstance(action, Drop):
            target = _check_target(action.target, action.confidence, active, plan)
            if target is not None:
                plan.mutations.append(
                    Mutation(kind="drop", target=target, reason=action.reason)
                )
        elif isinstance(action, Reschedule):
            _reconcile_reschedule(action, today, active, ctx.message, plan)
        elif isinstance(action, Query):
            _reconcile_query(action, today, ctx, plan)
        elif isinstance(action, Bulk):
            _reconcile_bulk(action, today, ctx, plan)
        elif isinstance(action, Unknown):
            plan.questions.append("i did not catch a task there. can you rephrase?")
    return plan
