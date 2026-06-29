# SPDX-License-Identifier: MIT
"""Planner: reconciled Actions plus context -> concrete mutations and questions.

Pure, no I/O. This is where correctness lives: the model's output is a proposal,
not a command.

- Dates: the model's ISO value is ignored and re-resolved from the raw phrasing
  (core.dates). Ambiguity, a parser/model disagreement, or a parser that finds
  nothing where a date was intended all produce a clarifying question and apply
  nothing for that action.
- References: every target must match a real id in the active list, and
  confidence must clear the threshold; otherwise ask, never mutate.

Mutations are intents, not finished items: the planner is pure, so it cannot
allocate ids or read the clock. The edge (MessageService) materializes them.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date

from core import dates
from core.models import Capture, Complete, Drop, Query, Reschedule, Unknown

# Below this, a reference-bearing action (complete/drop/reschedule) is treated as
# a guess and asked about rather than applied.
CONFIDENCE_THRESHOLD = 0.5


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
class Plan:
    mutations: list[Mutation] = field(default_factory=list)
    questions: list[str] = field(default_factory=list)
    queries: list[QueryIntent] = field(default_factory=list)


def _norm_iso(value: str | None) -> str | None:
    """Normalize a model-supplied ISO date, or None if it is not a clean date."""
    if not value:
        return None
    try:
        return date.fromisoformat(value).isoformat()
    except ValueError:
        return None


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
    model_due = _norm_iso(action.due)

    if resolution.ambiguous:
        plan.questions.append(
            f'when is "{action.task}" due? i read more than one date '
            f'in "{action.raw}".'
        )
        return
    if resolution.date is None and model_due is not None:
        plan.questions.append(
            f'i could not pin a date for "{action.task}". when is it due?'
        )
        return
    if (
        resolution.date is not None
        and model_due is not None
        and model_due != resolution.date
    ):
        plan.questions.append(
            f'is "{action.task}" due {resolution.date}? (you wrote "{action.raw}")'
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
    action: Reschedule, today: date, active: dict, plan: Plan
) -> None:
    target = _check_target(action.target, action.confidence, active, plan)
    if target is None:
        return
    resolution = dates.resolve(action.raw, today)
    model_due = _norm_iso(action.due)
    label = active[target]

    if resolution.ambiguous:
        plan.questions.append(f'when should i move "{label}" to? that read as more than one date.')
        return
    if resolution.date is None:
        plan.questions.append(f'to when should i move "{label}"?')
        return
    if model_due is not None and model_due != resolution.date:
        plan.questions.append(f'move "{label}" to {resolution.date}? (you wrote "{action.raw}")')
        return

    plan.mutations.append(
        Mutation(kind="reschedule", target=target, due_date=resolution.date)
    )


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
            _reconcile_reschedule(action, today, active, plan)
        elif isinstance(action, Query):
            _reconcile_query(action, today, ctx, plan)
        elif isinstance(action, Unknown):
            plan.questions.append("i did not catch a task there. can you rephrase?")
    return plan
