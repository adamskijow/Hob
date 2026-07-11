# SPDX-License-Identifier: MIT
"""Interpreter eval: run representative messages through the real model and check
the resulting Plan. Unlike the unit suite (fake LLM), this exercises the live
interpreter + planner against Ollama, so it catches prompt/model regressions and
is the thing to run after tuning the prompt or swapping HOB_MODEL.

    HOB_MODEL=qwen2.5:14b-instruct uv run python -m evals.interpreter_eval

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
    focus: list | None = None  # conversational focus, for follow-up cases
    replied: dict | None = None  # replied-to anchor, for reply cases


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
    Case("check the smoke alarms every 2 months",
         lambda p: kinds(p) == ["capture"]
         and p.mutations[0].repeat == "every:2:month",
         "recurring capture (interval)"),
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
    Case("push everything to tomorrow",
         lambda p: len(p.mutations) >= 1
         and all(m.kind == "reschedule" and m.due_date == "2026-06-30" for m in p.mutations),
         "bulk reschedule to tomorrow"),
    Case("what's overdue",
         lambda p: [q.kind for q in p.queries] == ["overdue"],
         "overdue query"),
    Case("I have 40 minutes and low energy, what should I do next?",
         lambda p: p.queries and p.queries[0].kind == "plan"
         and "40" in (p.queries[0].constraint or ""),
         "constraint-aware planning query"),
    Case("anything about the audit",
         lambda p: p.queries and p.queries[0].kind == "search"
         and "audit" in (p.queries[0].term or "").lower(),
         "free-text search query"),
    Case("what did I finish today",
         lambda p: p.queries and p.queries[0].kind == "done",
         "done-history query"),
    Case("scratch that",
         lambda p: p.undo is True,
         "conversational undo"),
    Case("pick up the dry cleaning, it's urgent",
         lambda p: kinds(p) == ["capture"] and p.mutations[0].priority == "high",
         "new task captured with high priority"),
    Case("the audit is urgent",
         lambda p: kinds(p) == ["prioritize"] and p.mutations[0].target == "a3"
         and p.mutations[0].priority == "high",
         "prioritize an existing item"),
    Case("the pool guy can wait",
         lambda p: kinds(p) == ["prioritize"] and p.mutations[0].target == "a2"
         and p.mutations[0].priority == "low",
         "deprioritize an existing item"),
    Case("water the plants in a couple days",
         lambda p: cap_due(p) == "2026-07-01",  # today 06-29 + 2
         "fuzzy relative date (a couple days)"),
    Case("finish the taxes by end of the month",
         lambda p: kinds(p) == ["capture"]
         and p.mutations[0].deadline_date == "2026-06-30",
         "by-date becomes a hard deadline, not a do date"),
    Case("draft the board report Friday; it is due Monday and takes three hours in two sessions",
         lambda p: kinds(p) == ["capture"]
         and p.mutations[0].due_date == "2026-07-03"
         and p.mutations[0].deadline_date == "2026-07-06"
         and p.mutations[0].duration_minutes == 180
         and p.mutations[0].splittable is True,
         "capture separates do date, deadline, duration, and splitting"),
    Case("the audit is due Friday and takes 90 minutes",
         lambda p: kinds(p) == ["schedule"]
         and p.mutations[0].target == "a3"
         and p.mutations[0].deadline_date == "2026-07-03"
         and p.mutations[0].duration_minutes == 90,
         "existing task gets deadline and effort without moving"),
    Case("remind me an hour and 10 minutes before the pool call",
         lambda p: kinds(p) == ["schedule"]
         and p.mutations[0].target == "a2"
         and p.mutations[0].reminder_offsets == [60, 10],
         "task-specific multiple reminder offsets"),
    Case("skip the next audit occurrence",
         lambda p: kinds(p) == ["recur"]
         and p.mutations[0].target == "a3"
         and p.mutations[0].recur_op == "skip",
         "recurring series skip is distinct from reschedule"),
    Case("check the filters every 2 weeks after I finish, stop after 5 times",
         lambda p: kinds(p) == ["capture"]
         and p.mutations[0].recurrence is not None
         and p.mutations[0].recurrence.get("anchor") == "completion"
         and p.mutations[0].recurrence.get("count") == 5,
         "structured completion-relative recurrence with count"),
    Case("for the wedding: book the caterer, order flowers",
         lambda p: kinds(p) == ["capture", "capture"]
         and all(m.tag == "wedding" for m in p.mutations),
         "tagged multi-capture under a project"),
    Case("what's left for the wedding",
         lambda p: p.queries and p.queries[0].kind == "tag"
         and p.queries[0].tag == "wedding",
         "tag query"),
    Case("send the morning digest at 7",
         lambda p: [(s.key, s.value) for s in p.settings] == [("wake_time", "07:00")],
         "NL setting (wake time)"),
    Case("plan my work from 9 to 5",
         lambda p: [(s.key, s.value) for s in p.settings] == [
             ("work_hours", "09:00-17:00")
         ],
         "NL setting (working hours)"),
    Case("protect lunch from noon to 1",
         lambda p: [(s.key, s.value) for s in p.settings] == [
             ("break_window", "12:00-13:00")
         ],
         "NL setting (protected break)"),
    Case("assume tasks take 45 minutes unless I say otherwise",
         lambda p: [(s.key, s.value) for s in p.settings] == [
             ("default_duration", "45")
         ],
         "NL setting (default task estimate)"),
    Case("leave 10 minutes between things",
         lambda p: [(s.key, s.value) for s in p.settings] == [
             ("transition_buffer", "10")
         ],
         "NL setting (transition buffer)"),
    Case("tomorrow I need to look at the slides, prep my 1130 meeting, and join the 2 o clock call",
         lambda p: kinds(p) == ["capture", "capture", "capture"]
         and all(m.due_date == "2026-06-30" for m in p.mutations),
         "leading date shared across tasks; 1130 is not the year 1130"),
    Case("thanks bud, you're the best",
         lambda p: p.chitchat is not None and not p.mutations and not p.queries,
         "pleasantry gets a warm reply, not a task nag"),
    Case("make it 4pm",
         lambda p: kinds(p) == ["reschedule"] and p.mutations[0].target == "a2"
         and p.mutations[0].due_time == "16:00" and p.mutations[0].due_date is None,
         "bare follow-up changes the time, not the day",
         focus=[{"id": "a2", "label": "call the pool guy"}]),
    Case("that's urgent",
         lambda p: kinds(p) == ["prioritize"] and p.mutations[0].target == "a2"
         and p.mutations[0].priority == "high",
         "follow-up prioritize via focus",
         focus=[{"id": "a2", "label": "call the pool guy"}]),
    Case("do the second one",
         lambda p: p.starts == ["a3"] and not p.mutations,
         "plan ordinal follows displayed plan order",
         focus=[
             {"id": "a2", "label": "call the pool guy", "context": "plan"},
             {"id": "a3", "label": "review the SR audit", "context": "plan"},
         ]),
    Case("plan tomorrow",
         lambda p: len(p.queries) == 1 and p.queries[0].kind == "plan"
         and p.queries[0].date == "2026-06-30",
         "named future planning day is preserved"),
    Case("use this plan",
         lambda p: p.plan_action == "adopt" and not p.mutations,
         "plan adoption is explicit"),
    Case("replace my plan with this",
         lambda p: p.plan_action == "replace" and not p.mutations,
         "plan replacement is explicit"),
    Case("cancel my plan",
         lambda p: p.plan_action == "cancel" and not p.mutations,
         "plan cancellation is explicit"),
    Case("what is on my plan?",
         lambda p: len(p.queries) == 1 and p.queries[0].kind == "plan_status",
         "adopted plan status query"),
    Case("meeting ran over, I got interrupted; replan",
         lambda p: len(p.queries) == 1 and p.queries[0].kind == "plan"
         and not p.mutations,
         "session interruption requests a proposal, not a task mutation",
         replied={"id": "a2", "label": "call the pool guy"}),
    Case("buy milk tomorrow",
         lambda p: kinds(p) == ["capture"] and cap_due(p) == "2026-06-30",
         "own-subject message is not hijacked by focus",
         focus=[{"id": "a2", "label": "call the pool guy"}]),
    Case("done",
         lambda p: kinds(p) == ["complete"] and p.mutations[0].target == "a2",
         "reply 'done' to a reminder completes that item",
         replied={"id": "a2", "label": "call the pool guy"}),
    Case("snooze 20",
         lambda p: kinds(p) == ["snooze"] and p.mutations[0].target == "a2"
         and p.mutations[0].minutes == 20,
         "reply 'snooze 20' snoozes that reminder",
         replied={"id": "a2", "label": "call the pool guy"}),
    Case("make it 4pm",
         lambda p: not p.mutations,
         "bare follow-up with no focus does not guess"),
    Case("add a note to the audit one: bring the Q3 numbers",
         lambda p: kinds(p) == ["note"] and p.mutations[0].target == "a3"
         and "q3" in (p.mutations[0].note or "").lower(),
         "note attaches to an existing item"),
    Case("the prez deck is waiting on sam's slides",
         lambda p: kinds(p) == ["wait"] and p.mutations[0].target == "a1",
         "wait parks an existing item"),
    Case("what am i waiting on",
         lambda p: p.queries and p.queries[0].kind == "waiting",
         "waiting query"),
    Case("Remind me to pay my taxes Monday",
         lambda p: kinds(p) == ["capture"] and cap_due(p) == "2026-07-06"
         and "remind me" not in (p.mutations[0].task or "").lower(),
         "named weekday wins; reminder prefix stripped"),
    Case("What about tomorrow",
         lambda p: any(q.kind == "date" and q.date == "2026-06-30" for q in p.queries),
         "bare follow-up query day is honored"),
    Case("Hobbie*",
         lambda p: p.chitchat is not None and not p.questions and not p.mutations,
         "asterisk typo-correction is acked, not nagged"),
    Case("Hob I love you",
         lambda p: p.chitchat is not None and not p.questions and not p.mutations,
         "affection gets a warm reply, not a task nag"),
    Case("how are you",
         lambda p: p.chitchat is not None and not p.questions,
         "small-talk question is chitchat, not a nag"),
    Case("I did everything today but the prez deck",
         lambda p: kinds(p) and all(k == "complete" for k in kinds(p))
         and "a1" not in {m.target for m in p.mutations}
         and len(p.mutations) >= 2,
         "bulk complete spares the excluded item"),
    Case("did the slides but not the taxes",
         lambda p: {m.target for m in p.mutations if m.kind == "complete"} == {"t2"}
         and not any(m.kind == "complete" and m.target == "t1" for m in p.mutations)
         and not any(m.kind == "capture" for m in p.mutations),
         "negated half is neither completed nor re-captured",
         active=[
             {"id": "t1", "label": "pay my taxes", "due_date": "2026-07-06"},
             {"id": "t2", "label": "finish the MOR slides", "due_date": None},
         ]),
    Case("nope, did not pay the taxes",
         lambda p: not p.mutations,
         "a bare negation touches nothing",
         active=[{"id": "t1", "label": "pay my taxes", "due_date": "2026-07-06"}]),
    Case("finished the fabel thing",
         lambda p: (p.confirm is not None
                    and p.confirm.mutations[0].target == "t1")
         or any(m.kind == "complete" and m.target == "t1" for m in p.mutations)
         or bool(p.questions),
         "misspelled target is confirmed or asked, never silently dropped",
         active=[{"id": "t1", "label": "on Tuesday fable goes away", "due_date": None}]),
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
            focus=c.focus or [], replied=c.replied,
        )
        try:
            plan = reconcile(interpret(llm, ctx), ctx)
            ok = bool(c.check(plan))
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
