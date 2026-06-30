# SPDX-License-Identifier: MIT
"""Interpreter eval: run representative messages through the real model and check
the resulting Plan. Unlike the unit suite (fake LLM), this exercises the live
interpreter + planner against Ollama, so it catches prompt/model regressions and
is the thing to run after tuning the prompt or swapping HOB_MODEL.

    HOB_MODEL=qwen2.5:14b-instruct uv run python evals/interpreter_eval.py

Exit code is non-zero if any case fails.
"""
from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from typing import Callable

from adapters.llm_ollama import OllamaLlm
from core.interpreter import interpret
from core.models import InterpreterContext
from core.planner import Plan, reconcile

TODAY = "2026-06-29"  # a Monday; tomorrow=06-30, Friday=07-03
TZ = "America/New_York"
# A small standing list the cases reference (position order = list order).
ACTIVE = [
    {"id": "a1", "label": "prep the prez deck", "due_date": None},
    {"id": "a2", "label": "call the pool guy", "due_date": None},
    {"id": "a3", "label": "review the SR audit", "due_date": "2026-06-28"},
]


@dataclass
class Case:
    msg: str
    check: Callable[[Plan], bool]
    desc: str
    active: list | None = None


def kinds(p: Plan) -> list[str]:
    return [m.kind for m in p.mutations]


def cap_due(p: Plan):
    caps = [m for m in p.mutations if m.kind == "capture"]
    return caps[0].due_date if caps else "<no capture>"


CASES = [
    Case("call mom",
         lambda p: kinds(p) == ["capture"] and cap_due(p) is None,
         "undated capture"),
    Case("dentist tomorrow",
         lambda p: cap_due(p) == "2026-06-30",
         "dated capture (tomorrow)"),
    Case("Tomorrow I need to harass Jerry",
         lambda p: cap_due(p) == "2026-06-30",
         "relative date recovered even if model drops it from raw"),
    Case("lunch with sam thursday or friday",
         lambda p: not p.mutations and bool(p.questions),
         "ambiguous date asks"),
    Case("in 200 years take out the trash",
         lambda p: p.confirm is not None and "years out" in p.confirm.question,
         "implausibly far date confirms"),
    Case("push the audit to friday",
         lambda p: kinds(p) == ["reschedule"] and p.mutations[0].due_date == "2026-07-03",
         "reschedule by description"),
    Case("did the prez one",
         lambda p: kinds(p) == ["complete"] and p.mutations[0].target == "a1",
         "complete by description"),
    Case("drop 2",
         lambda p: kinds(p) == ["drop"] and p.mutations[0].target == "a2",
         "reference by position number"),
    Case("the third one is done",
         lambda p: kinds(p) == ["complete"] and p.mutations[0].target == "a3",
         "reference by ordinal"),
    Case("change the prez task to prep the Q3 deck",
         lambda p: kinds(p) == ["amend"] and p.mutations[0].target == "a1",
         "amend item text"),
    Case("bring soda for the prez thing",
         lambda p: kinds(p) == ["capture"],
         "relate captures a new task (date inherited if model relates)"),
    Case("water the plants daily",
         lambda p: kinds(p) == ["capture"] and p.mutations[0].repeat == "daily",
         "recurring capture (daily)"),
    Case("take out the trash every monday",
         lambda p: kinds(p) == ["capture"] and p.mutations[0].repeat == "weekly:mon",
         "recurring capture (weekly)"),
    Case("did everything today",
         lambda p: kinds(p) and all(k == "complete" for k in kinds(p)),
         "bulk complete"),
    Case("delete everything",
         lambda p: p.confirm is not None,
         "multi-day delete confirms"),
    Case("what's on today?",
         lambda p: [q.kind for q in p.queries] == ["today"],
         "today query"),
    Case("what's my schedule tomorrow",
         lambda p: any(q.kind == "date" and q.date == "2026-06-30" for q in p.queries),
         "tomorrow -> date query"),
    Case("what's your favorite color?",
         lambda p: not p.mutations and not p.queries,
         "chit-chat is not a query"),
]


def main() -> int:
    model = os.environ.get("HOB_MODEL", "qwen2.5:14b-instruct")
    llm = OllamaLlm(model, os.environ.get("HOB_OLLAMA_HOST", "http://localhost:11434"))
    print(f"interpreter eval | model={model} | today={TODAY}\n")
    passed = 0
    for c in CASES:
        ctx = InterpreterContext(
            message=c.msg, today=TODAY, now=f"{TODAY}T09:00:00", timezone=TZ,
            active_items=c.active or ACTIVE, last_digest=[],
        )
        try:
            plan = reconcile(interpret(llm, ctx), ctx)
            ok = c.check(plan)
        except Exception as exc:  # noqa: BLE001
            ok, plan = False, exc
        passed += ok
        mark = "PASS" if ok else "FAIL"
        print(f"  [{mark}] {c.desc}")
        if not ok:
            detail = plan if isinstance(plan, Exception) else (
                f"mutations={kinds(plan)} q={plan.questions} "
                f"queries={[(q.kind, q.date) for q in plan.queries]} "
                f"confirm={'yes' if plan.confirm else 'no'}"
            )
            print(f"         msg={c.msg!r}\n         got: {detail}")
    print(f"\n{passed}/{len(CASES)} passed")
    return 0 if passed == len(CASES) else 1


if __name__ == "__main__":
    sys.exit(main())
