# SPDX-License-Identifier: MIT
"""Planner: reconciled Actions plus context -> concrete mutations and questions.

Pure, no I/O. This is where correctness lives: the model's output is a proposal,
not a command. For any date, the model's ISO value is ignored and re-resolved
from the raw phrasing (core.dates). Ambiguity, a parser/model disagreement, or a
parser that finds nothing where a date was intended all produce a clarifying
question and apply nothing for that action.

Mutations are intents, not finished items: the planner is pure, so it cannot
allocate ids or read the clock. The edge (MessageService) materializes captures
into Items. Phase 5 handles capture and unknown; Phase 7 adds the rest.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date

from core import dates
from core.models import Capture, Unknown

# Below this, a reference-bearing action (complete/drop/reschedule) is treated as
# a guess and asked about rather than applied. Used from Phase 7.
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
class Plan:
    mutations: list[Mutation] = field(default_factory=list)
    questions: list[str] = field(default_factory=list)


def _norm_iso(value: str | None) -> str | None:
    """Normalize a model-supplied ISO date, or None if it is not a clean date."""
    if not value:
        return None
    try:
        return date.fromisoformat(value).isoformat()
    except ValueError:
        return None


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


def reconcile(actions: list, ctx) -> Plan:
    today = date.fromisoformat(ctx.today)
    plan = Plan()
    for action in actions:
        if isinstance(action, Capture):
            _reconcile_capture(action, today, plan)
        elif isinstance(action, Unknown):
            plan.questions.append("i did not catch a task there. can you rephrase?")
    return plan
