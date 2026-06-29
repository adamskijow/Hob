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
from core.models import Capture, Complete, Drop, Query, Reschedule, Unknown

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
class Plan:
    mutations: list[Mutation] = field(default_factory=list)
    questions: list[str] = field(default_factory=list)
    queries: list[QueryIntent] = field(default_factory=list)


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
        plan.questions.append(
            f'when is "{action.task}" due? i read more than one date '
            f'in "{action.raw}".'
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
        plan.questions.append(f'did you want to move "{label}"? if so, to when?')
        return

    resolution = dates.resolve(action.raw, today)

    if resolution.ambiguous:
        plan.questions.append(f'when should i move "{label}" to? that read as more than one date.')
        return
    if resolution.date is None:
        plan.questions.append(f'to when should i move "{label}"?')
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
            _reconcile_reschedule(action, today, active, ctx.message, plan)
        elif isinstance(action, Query):
            _reconcile_query(action, today, ctx, plan)
        elif isinstance(action, Unknown):
            plan.questions.append("i did not catch a task there. can you rephrase?")
    return plan
