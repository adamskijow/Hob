# SPDX-License-Identifier: MIT
"""Interpreter: the spine. Builds the model prompt, parses and validates the
forced JSON into Actions. Deterministic reconciliation happens in planner.py.

The model call is injected via core.ports.Llm; this module performs no I/O. The
model proposes; the core decides. Malformed or surprising output degrades to a
single Unknown action so the edge can ask rather than crash.

The model proposes typed actions and date intents. The core validates item ids,
machine-owned conversational context, confidence, and every resulting effect;
it also resolves all calendar dates itself.
"""
from __future__ import annotations

from datetime import date
import json

from core.models import (
    Amend,
    Bulk,
    Capture,
    Chitchat,
    Complete,
    ConfirmationDecision,
    Drop,
    InterpreterContext,
    NudgeDecision,
    Note,
    OnboardingDecision,
    PlanAction,
    Prioritize,
    Query,
    Recap,
    Recur,
    Reschedule,
    Resume,
    Schedule,
    Setting,
    Snooze,
    Start,
    Undo,
    Unknown,
    Wait,
    When,
)
from core.ports import Llm

# Note set on the Unknown returned when the model call itself fails (ollama down,
# timeout, malformed). The edge recognizes it to log and reply distinctly rather
# than blaming the user with a generic "did not catch that".
MODEL_UNREACHABLE = "model call failed"

_STR = {"type": ["string", "null"]}
_NUM = {"type": ["number", "null"]}
_BOOL = {"type": ["boolean", "null"]}
_STRS = {"type": "array", "items": {"type": "string"}}
_NUMS = {"type": "array", "items": {"type": "number"}}
_LEVEL = {"type": "string", "enum": ["high", "normal", "low"]}
# A typed date intent: the model classifies, core.dates.resolve_intent does math.
_WHEN = {
    "type": "object",
    "properties": {
        "kind": {"type": "string", "enum": [
            "none", "today", "tomorrow", "yesterday", "weekday", "offset",
            "weekend", "week", "month", "month_day", "ordinal_day", "absolute",
            "ambiguous"]},
        "which": _STR, "day": _STR, "n": _NUM, "unit": _STR, "anchor": _STR,
        "part": _STR, "month": _NUM, "day_num": _NUM, "date": _STR,
    },
    "required": ["kind"],
}


def _variant(type_value: str, props: dict, required: list[str]) -> dict:
    """One oneOf branch: a fixed `type` plus exactly the fields it allows."""
    return {
        "type": "object",
        "properties": {"type": {"type": "string", "enum": [type_value]}, **props},
        "required": required,
    }


# Passed to Ollama as the structured-output format. Discriminated by `type` via
# oneOf (Ollama/llama.cpp grammar supports it). Per-variant `required` is the
# point: reschedule REQUIRES a non-null raw, so constrained decoding forces the
# model to emit the date phrase. A flat all-optional schema let the small model
# omit raw entirely, which broke every reschedule. The model never proposes a
# resolved date; the core resolves it from raw (core.dates), so there is no `due`
# field at all. The parser is the real validator; the schema forces structure.
ACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "actions": {
            "type": "array",
            "items": {
                "oneOf": [
                    _variant(
                        "capture",
                        {"task": _STR, "raw": _STR, "when": _WHEN, "time": _STR,
                         "relate": _STR, "repeat": _STR, "priority": _LEVEL,
                         "tag": _STR, "waiting": _BOOL,
                         "note": _STR, "deadline": _WHEN,
                         "duration_minutes": _NUM, "duration_confidence": _NUM,
                         "schedule_kind": _STR, "splittable": _BOOL,
                         "earliest": _WHEN, "earliest_time": _STR,
                         "preferred_window": _STR, "parent": _STR,
                         "depends_on": _STRS, "reminder_offsets": _NUMS,
                         "repeat_anchor": _STR, "repeat_end": _WHEN,
                         "repeat_count": _NUM, "confidence": _NUM},
                        ["type", "raw", "when"],
                    ),
                    _variant(
                        "schedule",
                        {"target": _STR, "deadline": _WHEN,
                         "duration_minutes": _NUM, "duration_confidence": _NUM,
                         "schedule_kind": _STR, "splittable": _BOOL,
                         "earliest": _WHEN, "earliest_time": _STR,
                         "preferred_window": _STR, "depends_on": _STRS,
                         "reminder_offsets": _NUMS, "clear": _STRS,
                         "confidence": _NUM},
                        ["type", "target"],
                    ),
                    _variant(
                        "recur",
                        {"target": _STR,
                         "op": {"type": "string", "enum": ["skip", "stop", "anchor", "end"]},
                         "anchor": _STR, "end": _WHEN, "count": _NUM,
                         "confidence": _NUM},
                        ["type", "target", "op"],
                    ),
                    _variant(
                        "note",
                        {"target": _STR, "text": _STR, "confidence": _NUM},
                        ["type", "target", "text"],
                    ),
                    _variant(
                        "wait",
                        {"target": _STR, "confidence": _NUM},
                        ["type", "target"],
                    ),
                    _variant(
                        "resume",
                        {"target": _STR, "confidence": _NUM},
                        ["type", "target"],
                    ),
                    _variant(
                        "setting",
                        {"key": {"type": "string", "enum": [
                            "wake_time", "eod_time", "work_hours", "break_window",
                            "work_days", "default_duration", "transition_buffer"
                        ]},
                         "raw": _STR, "time": _STR, "start_time": _STR,
                         "end_time": _STR, "days": _STRS, "minutes": _NUM,
                         "clear": _BOOL, "confidence": _NUM},
                        ["type", "key", "raw"],
                    ),
                    _variant(
                        "start",
                        {"target": _STR, "confidence": _NUM},
                        ["type", "target"],
                    ),
                    _variant(
                        "plan_action",
                        {"op": {"type": "string", "enum": [
                            "adopt", "replace", "cancel"
                        ]}, "confidence": _NUM},
                        ["type", "op"],
                    ),
                    _variant(
                        "prioritize",
                        {"target": _STR, "level": _LEVEL, "confidence": _NUM},
                        ["type", "target", "level"],
                    ),
                    _variant(
                        "amend",
                        {"target": _STR, "task": _STR, "confidence": _NUM},
                        ["type", "target", "task"],
                    ),
                    _variant(
                        "complete",
                        {"target": _STR, "confidence": _NUM},
                        ["type", "target"],
                    ),
                    _variant(
                        "drop",
                        {"target": _STR, "reason": _STR, "confidence": _NUM},
                        ["type", "target"],
                    ),
                    _variant(
                        "reschedule",
                        {"target": _STR, "when": _WHEN, "time": _STR,
                         "confidence": _NUM},
                        ["type", "target", "when"],
                    ),
                    _variant(
                        "query",
                        {"kind": {"type": "string", "enum": [
                            "today", "date", "all", "overdue", "week", "search",
                            "done", "tag", "waiting", "plan", "plan_status",
                            "outlook", "explain", "what_if"]},
                         "when": _WHEN, "term": _STR, "tag": _STR,
                         "constraint": _STR, "budget_minutes": _NUM,
                         "budget_delta_minutes": _NUM,
                         "budget_scope": _STR, "energy": _STR,
                         "earliest_time": _STR, "latest_time": _STR,
                         "period": _STR, "target": _STR,
                         "aspect": _STR,
                         "duration_minutes": _NUM, "splittable": _BOOL,
                         "work_start": _STR, "work_end": _STR},
                        ["type", "kind"],
                    ),
                    _variant(
                        "bulk",
                        {"op": _STR, "scope": _STR, "when": _WHEN,
                         "except": {"type": "array", "items": {"type": "string"}},
                         "confidence": _NUM},
                        ["type", "op", "scope", "except"],
                    ),
                    _variant(
                        "snooze",
                        {"target": _STR, "minutes": _NUM, "confidence": _NUM},
                        ["type", "target", "minutes"],
                    ),
                    _variant(
                        "recap",
                        {
                            "outcome": {
                                "type": "string",
                                "enum": ["none"],
                            },
                            "confidence": _NUM,
                        },
                        ["type", "outcome"],
                    ),
                    _variant(
                        "nudge_decision",
                        {"decision": {"type": "string", "enum": [
                            "keep", "tomorrow", "drop", "resume"
                        ]}, "confidence": _NUM},
                        ["type", "decision"],
                    ),
                    _variant(
                        "confirmation_decision",
                        {"decision": {"type": "string", "enum": [
                            "approve", "reject"
                        ]}, "confidence": _NUM},
                        ["type", "decision"],
                    ),
                    _variant(
                        "onboarding_decision",
                        {"decision": {"type": "string", "enum": [
                            "skip", "cancel"
                        ]}, "confidence": _NUM},
                        ["type", "decision"],
                    ),
                    _variant("undo", {}, ["type"]),
                    _variant("chitchat", {"reply": _STR}, ["type"]),
                    _variant("unknown", {"note": _STR}, ["type"]),
                ]
            },
        }
    },
    "required": ["actions"],
}

# A deliberately small second-pass contract for replies to a current evening
# recap. It validates direct recap proposals and recovers terse answers that the
# main model called chitchat or unknown, without a language-specific phrase list.
RECAP_OUTCOME_SCHEMA = {
    "type": "object",
    "properties": {
        "outcome": {
            "type": "string",
            "enum": ["none", "social", "other"],
        },
        "confidence": {"type": "number"},
    },
    "required": ["outcome", "confidence"],
}

CONTEXT_DECISION_SCHEMA = {
    "type": "object",
    "properties": {
        "outcome": {
            "type": "string",
            "enum": [
                "keep", "tomorrow", "drop", "resume",
                "approve", "reject", "skip", "cancel", "other",
            ],
        },
        "confidence": {"type": "number"},
    },
    "required": ["outcome", "confidence"],
}

BULK_SCOPE_SCHEMA = {
    "type": "object",
    "properties": {
        "scope": {
            "type": "string",
            "enum": ["all", "today", "date", "presented", "unclear"],
        },
        "when": _WHEN,
        "exclude": _STRS,
        "confidence": {"type": "number"},
    },
    "required": ["scope", "when", "exclude", "confidence"],
}

SHARED_CAPTURE_DATE_SCHEMA = {
    "type": "object",
    "properties": {
        "applies_to_all": {"type": "boolean"},
        "when": _WHEN,
        "confidence": {"type": "number"},
    },
    "required": ["applies_to_all", "when", "confidence"],
}

CAPTURE_AUDIT_SCHEMA = {
    "oneOf": [
        _variant(
            "capture",
            {
                "task": _STR, "raw": _STR, "when": _WHEN, "time": _STR,
                "relate": _STR, "repeat": _STR, "priority": _LEVEL,
                "tag": _STR, "waiting": _BOOL, "note": _STR,
                "deadline": _WHEN, "duration_minutes": _NUM,
                "duration_confidence": _NUM, "schedule_kind": _STR,
                "splittable": _BOOL, "earliest": _WHEN,
                "earliest_time": _STR, "preferred_window": _STR,
                "parent": _STR, "depends_on": _STRS,
                "reminder_offsets": _NUMS, "repeat_anchor": _STR,
                "repeat_end": _WHEN, "repeat_count": _NUM,
                "confidence": {"type": "number"},
            },
            [
                "type", "task", "raw", "when", "time", "repeat",
                "priority", "deadline", "duration_minutes", "splittable",
                "repeat_anchor", "repeat_end", "repeat_count", "confidence",
            ],
        ),
        _variant(
            "plan",
            {
                "when": _WHEN, "budget_minutes": _NUM,
                "budget_scope": _STR, "energy": _STR,
                "earliest_time": _STR, "latest_time": _STR,
                "confidence": {"type": "number"},
            },
            ["type", "when", "confidence"],
        ),
        _variant(
            "outlook",
            {
                "when": _WHEN, "budget_minutes": _NUM,
                "budget_scope": _STR, "energy": _STR,
                "earliest_time": _STR, "latest_time": _STR,
                "confidence": {"type": "number"},
            },
            ["type", "when", "confidence"],
        ),
        _variant(
            "explain",
            {
                "target": _STR,
                "aspect": _STR,
                "confidence": {"type": "number"},
            },
            ["type", "target", "aspect", "confidence"],
        ),
        _variant(
            "what_if",
            {
                "target": _STR, "budget_minutes": _NUM,
                "budget_delta_minutes": _NUM, "budget_scope": _STR,
                "energy": _STR, "earliest_time": _STR,
                "latest_time": _STR, "duration_minutes": _NUM,
                "work_start": _STR, "work_end": _STR,
                "splittable": _BOOL, "confidence": {"type": "number"},
            },
            [
                "type", "target", "budget_minutes", "budget_delta_minutes",
                "budget_scope", "energy", "earliest_time", "latest_time",
                "duration_minutes", "work_start", "work_end", "splittable",
                "confidence",
            ],
        ),
        _variant(
            "plan_action",
            {
                "op": {"type": "string", "enum": ["adopt", "replace", "cancel"]},
                "confidence": {"type": "number"},
            },
            ["type", "op", "confidence"],
        ),
        _variant(
            "undo", {"confidence": {"type": "number"}},
            ["type", "confidence"],
        ),
        _variant(
            "other", {"confidence": {"type": "number"}},
            ["type", "confidence"],
        ),
    ]
}

SETTING_AUDIT_SCHEMA = _variant(
    "setting",
    {
        "key": {"type": "string", "enum": [
            "wake_time", "eod_time", "work_hours", "break_window",
            "work_days", "default_duration", "transition_buffer",
        ]},
        "raw": _STR, "time": _STR, "start_time": _STR, "end_time": _STR,
        "days": _STRS, "minutes": _NUM, "clear": _BOOL,
        "confidence": {"type": "number"},
    },
    [
        "type", "key", "raw", "time", "start_time", "end_time", "days",
        "minutes", "clear", "confidence",
    ],
)

ROUTE_TIEBREAK_SCHEMA = {
    "type": "object",
    "properties": {
        "outcome": {"type": "string", "enum": [
            "capture", "plan", "outlook", "explain", "what_if",
            "plan_action", "undo", "other",
        ]},
        "confidence": {"type": "number"},
    },
    "required": ["outcome", "confidence"],
}

SCHEDULE_AUDIT_SCHEMA = {
    "oneOf": [
        _variant(
            "schedule",
            {
                "target": _STR, "deadline": _WHEN,
                "duration_minutes": _NUM, "duration_confidence": _NUM,
                "schedule_kind": _STR, "splittable": _BOOL,
                "earliest": _WHEN, "earliest_time": _STR,
                "preferred_window": _STR, "depends_on": _STRS,
                "reminder_offsets": _NUMS, "clear": _STRS,
                "confidence": {"type": "number"},
            },
            ["type", "target", "confidence"],
        ),
        _variant(
            "other", {"confidence": {"type": "number"}},
            ["type", "confidence"],
        ),
    ]
}

HYPOTHETICAL_AUDIT_SCHEMA = {
    "type": "object",
    "properties": {
        "outcome": {"type": "string", "enum": ["what_if", "durable"]},
        "target": _STR,
        "budget_minutes": _NUM,
        "budget_delta_minutes": _NUM,
        "budget_scope": _STR,
        "energy": _STR,
        "earliest_time": _STR,
        "latest_time": _STR,
        "duration_minutes": _NUM,
        "work_start": _STR,
        "work_end": _STR,
        "splittable": _BOOL,
        "confidence": {"type": "number"},
    },
    "required": [
        "outcome", "target", "budget_minutes", "budget_delta_minutes",
        "budget_scope", "energy", "earliest_time", "latest_time",
        "duration_minutes", "work_start", "work_end", "splittable",
        "confidence",
    ],
}

_PROMPT = """\
You convert a personal assistant's inbound text message into a JSON list of \
actions. Be literal. You classify any date into a typed intent (see DATES); a \
separate program does the calendar math, so never compute a date yourself.

Context:
- Today: {today} ({weekday})
- Now: {now}
- Timezone: {timezone}
- Open items on deck (id: label):
{active}
- This morning's digest, in order (for position references):
{digest}
{presented}{analysis}{nudge}{confirmation}{onboarding}{pending}{focus}{forwarded}
The user's message:
{message}

Return a JSON object {{"actions": [ ... ]}}. Each action is one of:
- capture: a NEW task to remember. Fields: type "capture", task (clean \
imperative label; the date, time, and repeat words belong in when/time/repeat, \
NOT in task: "call the vet next friday at 3pm" -> task "call the vet"; "water \
the plants in a couple days" -> task "water the plants"), raw (echo the user's \
words for this task), when (a typed date intent, see DATES), time (HH:MM clock \
time or null), relate (see below, else null), repeat (see below, else null), \
priority, tag, confidence (0 to 1). Set priority "high" for \
urgent/important/asap/"top priority"/"do first", "low" for "low priority"/"can \
wait"/"no rush"/"whenever/someday", else "normal". A new task is still NEW even \
when urgent and even if it resembles an item on the list: "call the plumber, \
it's urgent" is capture (priority high), not a change to "call the pool guy". \
Set tag to a project/list name when the user files tasks under one ("for the \
wedding: book the caterer, order flowers" -> two captures, each tag "wedding"), \
else null. Set waiting true when the new task is blocked on someone else from \
the start: "waiting on the plumber to call back" -> capture, waiting true. Set \
note to any extra detail worth keeping with the task, else null. Scheduling \
fields: deadline is a typed date intent ONLY for a hard "by/before/no later \
than" deadline (ordinary "on Friday" stays in when); duration_minutes is the \
estimated effort ("two hours" -> 120) and duration_confidence is 1 for an \
explicit estimate or about 0.6 for an inference; schedule_kind is "fixed" for \
an appointment or explicit immovable time, else "flexible"; splittable is true \
only when the user permits sessions/chunks; earliest is a typed date before \
which work cannot begin, earliest_time is its clock time; preferred_window is \
"morning", "afternoon", "evening", or "HH:MM-HH:MM"; parent is the existing \
parent task id for a subtask; depends_on is existing ids that must finish first; \
reminder_offsets is explicit minutes before the scheduled time ("an hour and \
10 minutes before" -> [60,10]). For recurring work, repeat_anchor is "fixed" \
unless the user says the interval starts after completion, repeat_end is an \
optional ending date intent, and repeat_count is an optional total occurrence count.
- schedule: change scheduling metadata on an EXISTING item without moving its \
current do date. Fields: type "schedule", target, deadline, duration_minutes, \
duration_confidence, schedule_kind, splittable, earliest, earliest_time, \
preferred_window, depends_on, reminder_offsets, clear, confidence. Emit only \
values the user actually changed. clear is a list drawn from "deadline", \
"duration", "earliest", "window", "dependencies", or "reminders" when the \
user explicitly removes one. "The deck is due Friday and takes 90 minutes" is \
schedule, not reschedule. "Remind me 1 hour and 10 minutes before the dentist" \
sets reminder_offsets [60,10].
- recur: change an EXISTING recurring series. Fields: type "recur", target, op, \
anchor, end, count, confidence. op "skip" skips only the next occurrence; \
"stop" ends the series after the current occurrence; "anchor" changes fixed \
versus completion-relative cadence; "end" sets an end date or total count. \
Use this for "skip the next one", "stop repeating", "repeat after I finish", \
or "end after five times". Rescheduling a recurring item moves only its current \
occurrence and does not change the series.
- note: attach a detail to an EXISTING item. Fields: type "note", target (item \
id), text (the detail), confidence. "add a note to the vet one: gate code is \
4412" -> note, target the vet item, text "gate code is 4412".
- wait: an EXISTING item is now blocked on ANOTHER PERSON ("the contract is \
waiting on jerry", "can't do the prez until sam sends slides"). Fields: type \
"wait", target, confidence. It leaves today's list and resurfaces on its own. \
Use wait only when someone else must act first. "the pool guy can wait" names \
no blocker: that is prioritize with level low and target set to that item's id, \
NOT wait.
- resume: the block on a waiting item cleared ("jerry got back to me", "sam \
sent the slides"). Fields: type "resume", target, confidence. If the user says \
the task is DONE, use complete instead.
- setting: change a preference, not a task. Fields: type "setting", key \
("wake_time" = morning digest; "eod_time" = evening recap; "work_hours" = \
the bounds Hob may plan inside; "break_window" = protected daily break; \
"work_days" = weekdays on which Hob may plan flexible work; \
"default_duration" = the estimate for tasks with no stated duration; \
"transition_buffer" = open minutes kept between commitments), raw \
(an exact literal substring copied from the user's message), confidence, and \
the typed value fields: time for wake/eod; start_time and end_time for ranges; \
days as mon..sun codes for work_days; minutes for durations; clear true only \
when the user explicitly removes a break or buffer. Never invent or normalize \
raw. Use for "send the digest at 8", "plan work from 9 \
to 5", "protect lunch from noon to 1", "assume tasks take 45 minutes", \
"leave 10 minutes between things", "plan work Monday through Friday", \
or "remove my lunch break".
- prioritize: change the importance of an item ALREADY on the list. Fields: type \
"prioritize", target (item number), level ("high", "normal", or "low"), \
confidence. Use it when the user re-ranks an existing item: "make the prez deck \
urgent", "the audit can wait", "bump the audit to the top". Match the number \
exactly; never repurpose a different item because the words look similar.
- start: choose an EXISTING item as the work to do next without marking it done. \
Fields: type "start", target, confidence. Use for "start the second one", "work \
on the first task", or "I will do number 2" when a plan/list is in context. \
Completed/past-tense wording still uses complete.
- plan_action: change which proposed day plan is explicitly being followed. \
Fields: type "plan_action", op ("adopt" for "use this plan" when no plan is \
active; "replace" for "replace my plan with this"; "cancel" for "cancel my \
plan"), confidence. Viewing, starting, or completing one task is never adoption.
- amend: REWORD an EXISTING item's label ("rename the prez task to prep Q3"). \
Fields: type "amend", target (item id), task (the full new label, keeping what \
is still true), confidence. To attach extra info WITHOUT changing the label \
("add a note to X: ...", a code, a detail), use note, not amend.
- complete: mark an EXISTING item done. Fields: type "complete", target, confidence.
- drop: cancel an EXISTING item. Fields: type "drop", target, reason (optional), \
confidence.
- reschedule: move an EXISTING item to a new date and/or time. Fields: type \
"reschedule", target (item id), when (a typed date intent for the new date, see \
DATES; {{"kind":"none"}} if only the time changes), time (HH:MM if the user \
gives a new clock time, else null; "make it 4pm" -> time "16:00"), confidence.
- query: the user is asking about their tasks. Fields: type "query", kind, when \
(a date intent, for a specific day), term (search keywords), tag (project/list \
name). kind is one of: "today", "date" (a specific day; also set when), "all", \
"overdue" (past due), "week" (next 7 days), "search" (free text about a topic; \
set term, e.g. "anything about the pool guy" -> term "pool guy"), "done" (things \
ALREADY finished / completed / got done / knocked out; "what did I finish today" \
-> done; set period "today" or "week", and set when if a day is named), "tag" (what is in a project/list; "what's \
left for the wedding" -> kind tag, tag "wedding"), "waiting" (what is parked on \
other people; "what am i waiting on"), "plan" (the user wants help choosing or \
replanning what to do: "plan my day", "what should I do next", "I have 40 \
minutes and low energy"), "plan_status" (report the plan already adopted: \
"what is on my plan", "what am I doing now", "what is next on the plan"), \
"outlook" (read-only seven-day capacity and deadline fit: "am I overloaded \
this week", "what will not fit", "can I finish everything by Friday"), \
"explain" (why something happened in the latest deterministic plan/outlook, \
what assumptions it used, or what could change), or "what_if" (temporarily \
rerun that analysis under a hypothetical). For explain, set target to the exact \
saved-analysis task id when one task is named; set aspect to "why", "changes", \
or "assumptions". For what_if, set target only for a task-specific assumption; \
set duration_minutes and/or splittable for that task, budget_minutes for an \
absolute available-time budget, budget_delta_minutes for "another hour" or \
"30 minutes less", plus typed energy/earliest/latest fields. Use work_start or \
work_end when the hypothetical temporarily expands working hours ("what if I \
can work until 7?" -> work_end "19:00"). A hypothetical \
never uses schedule, setting, reschedule, or plan_action and never mutates \
anything. Use explain/what_if only when Context contains a latest deterministic \
analysis that the user refers to; otherwise use plan/outlook for a fresh request. \
For plan, outlook, explain, and what_if, copy relevant prose into constraint and classify its \
meaning into typed fields: budget_minutes; budget_scope "day" or "horizon"; \
energy "low", "normal", or "high"; earliest_time and latest_time as HH:MM. \
Understand ordinary paraphrases: "I'm wiped" or "no gas left" means low energy; \
"the first half of the day is shot" means earliest_time 12:00. Do not require \
stock phrases. Leave a typed field null when the user did not imply it.
- bulk: act on MANY items at once with ONE action; never list them individually. \
Fields: type "bulk", op ("complete", "drop", or "reschedule"), scope, when (op \
reschedule only: a date intent for the destination), except (ids to LEAVE OUT \
when the user excludes some: "did everything today but the MOR slides" -> bulk \
complete scope today, except [that item's id]; never also emit an action for an \
excluded item), confidence. Use bulk when \
the user means many items ("everything", "today's stuff", "push everything to \
tomorrow"). Pick scope:
  - "all": every open item. Use for "everything", "my whole list", "delete it all".
  - "today": only items on deck today. Use for "everything today", "today's stuff".
  - "date": one specific named day. Use for "all of friday", "monday's tasks".
  - "presented": only the exact most recently presented proactive list. Use for \
"everything on that list" or numbered exclusions referring to that displayed list.
- snooze: put off an item's reminder ping without moving the task. Fields: type \
"snooze", target (item id), minutes ("snooze 20" -> 20, "snooze an hour" -> 60, \
bare "snooze"/"not now" -> 10), confidence. Use when the user reacts to a \
reminder with snooze/"not now"/"remind me again in N"; a new date or time for \
the task itself is a reschedule instead.
- recap: the user is answering the most recently presented EVENING RECAP and \
reports that zero listed items were completed. Fields: type "recap", outcome \
"none", confidence. Infer the meaning from ordinary language, including terse, \
idiomatic, humorous, or multilingual answers; do not require completion \
keywords or any particular stock phrase. Use it only when the semantic answer \
to the active evening recap is that no listed item was completed. Never use \
recap for a morning digest, forwarded content, a setup answer, or an unanchored \
message. If the user names completed work or gives task-specific progress, emit \
complete or note actions instead. Never combine recap outcome none with another \
action.
- nudge_decision: the user is semantically answering the active morning digest \
nudge shown in Context. Fields: type "nudge_decision", decision, confidence. For \
a stale task, decision is "keep", "tomorrow", or "drop"; for a waiting item it \
is "resume". Understand natural paraphrases such as "it needs to stay on", \
"leave that one there", "punt it a day", or "that blocker cleared". Use only \
for the exact active nudge and never combine it with another action.
- confirmation_decision: Context says a risky action is held. Use decision \
"approve" or "reject" only for a pure semantic answer to that confirmation. \
"yes, but exclude 2" is NOT pure approval: interpret the revised instruction \
instead. Never infer approval from a word prefix.
- onboarding_decision: while Context names an active setup step, use decision \
"skip" when the user means keep the current value and move on, or "cancel" when \
they mean pause setup. Understand natural wording such as "this is fine", "leave \
it as is", or "let's do this later". Do not use outside setup.
- undo: the user wants to reverse their last change ("scratch that", "undo \
that", "forget that", "belay that"). Fields: type "undo". Interpret meaning; \
there is no fixed retraction vocabulary.
- chitchat: a social remark to hob with NO task - a greeting, thanks, an \
acknowledgment, a compliment, a bit of affection, or light small talk ("thanks \
bud", "good morning", "nice", "lol", "you're the best", "hob I love you", "good \
bot", "how are you", "you crack me up"). Fields: type "chitchat", reply (a \
short, warm reply that fits what they said, hob's friendly voice, a sentence at \
most: "anytime!", "aw, love you too", "doing great, thanks for asking", "glad i \
could help"). Use chitchat for these even though they are not tasks. Do NOT use \
it for a task, a question about the user's own tasks or schedule (that is a \
query), a semantic answer to an active evening recap, or a general-knowledge \
question (that is unknown).
- unknown: you cannot tell what task they want, or it is some other message you \
cannot act on (a non-task question, small talk that is not a pleasantry). \
Fields: type "unknown", note (short).

DATES: set "when" to a typed date intent - classify the phrase, never compute a date:
- no date mentioned -> {{"kind":"none"}}
- "today"/"tonight" -> {{"kind":"today"}}; "tomorrow" -> {{"kind":"tomorrow"}}; "yesterday" -> {{"kind":"yesterday"}}
- a weekday BY NAME, even with "next" ("friday", "next friday", "this monday") -> {{"kind":"weekday","which":"this" or "next","day":"mon".."sun"}}
- "in N days/weeks/months/years" ("a couple"=2, "a few"=3) -> {{"kind":"offset","n":N,"unit":"day"/"week"/"month"/"year"}}. "in 2 weeks" is offset, NOT week.
- "this/next weekend" -> {{"kind":"weekend","which":"this" or "next"}}
- "next week"/"this week", with NO weekday name and NO number (maybe early/mid/late) -> {{"kind":"week","which":"next","part":"early"/"mid"/"late"}}
- start or end of this/next month -> {{"kind":"month","which":"this" or "next","anchor":"start" or "end"}}
- a day of the month ("the 15th") -> {{"kind":"ordinal_day","day_num":15}}
- an explicit month+day ("August 3") -> {{"kind":"month_day","month":8,"day_num":3}}
- an explicit full date -> {{"kind":"absolute","date":"YYYY-MM-DD"}}
- two or more possible days ("thursday or friday") -> {{"kind":"ambiguous"}}
A clock time is NOT a date: put it in "time" (HH:MM); "my 1130 meeting" -> time "11:30", when {{"kind":"none"}}.
A date at the START of a multi-task message ("Tomorrow I need to A, B, C") applies to EVERY task: give each that same "when".

relate: if a NEW captured task is FOR or PART OF an existing open item (e.g. \
"bring soda" for an existing birthday), set relate to that item's id so the new \
task inherits that item's date. Otherwise leave relate null.

repeat: if the task recurs, set repeat to one of: "daily", "weekdays", \
"weekly:<comma-separated days>" ("every monday and friday" -> \
"weekly:monday,friday"), "monthly:<day-of-month>", "yearly:<month>-<day>", or \
"every:<N>:<day|week|month|year>" ("every 2 weeks" -> "every:2:week"). \
"take out the trash every monday" -> weekly:monday. A one-off date is NOT a \
repeat; leave repeat null and set when instead.

Choosing the action:
- HIGH-PRIORITY CONTRASTS. Return the exact typed fields shown by these
patterns; do not rely on another program to recover missing meaning:
  - "did the prez one" with a matching open item -> complete using that exact
    item's id, never its label or the words "prez one" as target.
  - "plan tomorrow" -> query kind plan, when tomorrow. "what is on my plan?"
    -> query kind plan_status. "What about tomorrow" -> query kind date, when
    tomorrow. A question about a plan is never a task capture.
  - "I have 40 minutes and low energy, what next?" -> query kind plan,
    budget_minutes 40, budget_scope day, energy low. "I'm wiped" and "no gas
    left" also set energy low. "first half of the day is shot" sets
    earliest_time "12:00". Copy the message into constraint too.
  - With a latest analysis in context, "why didn't the tax task fit?" -> query
    kind explain, target that exact task id, aspect "why". "What would need to
    change?" -> query kind explain, aspect "changes". "What if the tax task only
    took 30 minutes?" -> query kind what_if, target that task id,
    duration_minutes 30. "Would another hour help?" -> query kind what_if,
    budget_delta_minutes 60. These are read-only; never emit a task or setting
    mutation for a hypothetical.
  - "meeting ran over; replan" -> query kind plan even when it replies to a
    task reminder. It is not reschedule unless the user names a destination.
  - "make it 4pm" with focus/reply -> reschedule that item with when none and
    time "16:00". Without focus/reply and without naming an item, unknown; never
    choose an arbitrary open item. Do not pad a time-only move with when today.
  - "finish taxes by end of month" -> capture with when none and deadline
    month/end. "draft report Friday; due Monday; three hours in two sessions"
    -> ONE capture with when Friday, deadline Monday, duration_minutes 180, and
    splittable true. "audit is due Friday and takes 90 minutes" -> ONE schedule
    for the audit id with deadline Friday and duration_minutes 90.
  - "remind me an hour and 10 minutes before the pool call" -> schedule the
    pool id with reminder_offsets [60,10]; it is not a new reminder task.
  - "remind me to pay my taxes Monday" -> capture task "pay my taxes", when
    weekday mon. The reminder-request prefix is not part of the task, and the
    named weekday must not be dropped.
  - "check filters every 2 weeks after I finish, stop after 5 times" -> ONE
    capture with repeat "every:2:week", repeat_anchor "completion", and
    repeat_count 5; do not emit a recur edit for an unrelated existing item.
  - "plan flexible work Monday through Friday" -> setting work_days, raw exact
    substring "Monday through Friday", days ["mon","tue","wed","thu","fri"].
    "protect lunch from noon to 1" -> setting break_window, raw "noon to 1",
    start_time "12:00", end_time "13:00". "remove my lunch break" -> setting
    break_window with a literal raw substring and clear true. "assume tasks take
    45 minutes" -> setting default_duration, raw "45 minutes", minutes 45.
  - A recent-change context plus "nevermind", "forget that", or "belay that"
    means undo when it is a standalone retraction. Do not require one spelling.
  - "finished it all except 1 and 6" -> ONE bulk complete whose except contains
    the exact ids at displayed positions 1 and 6. "did A but not B" must never
    mutate B and must not turn the negated clause into schedule/note/capture.
- A recent evening recap is a question from Hob, not merely a list. Read a \
short follow-up as an answer to that question unless it clearly starts a new \
task, command, or question. When its semantic meaning is zero completed items, \
use recap outcome none rather than chitchat or unknown.
- Machine-owned nudge, confirmation, and onboarding context are questions, not \
mere task words. Prefer their typed decision action only when the message \
semantically answers that exact question. A new task or unrelated instruction \
remains its ordinary action.
- Coordinated past-tense completion scopes across coordinated clauses: "I did A \
and hit B" means both A and B were completed unless the user signals future, \
ongoing, or partial work. For "everything except X", emit one bulk action with \
every excluded id in except; never emit completion of an excluded item.
- If the user adds a detail to an existing item itself, use amend. If it is a \
distinct new task that belongs with an existing event, use capture with relate.
- A question about the user's tasks or schedule is a query, never an edit. A \
question not about their tasks (small talk, general knowledge) is not \
actionable: return a single unknown action.
- Use complete, drop, or reschedule only when the user clearly states they \
finished, cancelled, or moved one existing item. The instruction word licenses \
the edit. Resembling an item on deck is not enough: "review the SR audit \
tomorrow" -> capture (even though an "SR audit" item exists); only "push the SR \
audit to friday" is a reschedule.
- When the user refers to many items, use one bulk action, never one per item. \
"delete everything"/"clear my list" -> bulk drop (scope all); "did everything \
today" -> bulk complete (scope today, except []). "did" is a completion, not a \
question. "everything BUT/EXCEPT X" means X is NOT included: put X's id in \
except ("did everything but the prez deck" -> bulk complete, except [the prez \
item's id]).
- A message that just names a task, with no instruction word, is a NEW task: \
capture. "dentist next Friday" -> capture. "call the pool guy" -> capture.

Resolving references:
- Each open item is listed as "number: id: label". To point at one, set target \
(or relate) to its id, mapping a number ("drop 2"), position ("the second one"), \
or description ("the prez one") to that id.
- If you are unsure which item is meant, lower the confidence; never guess an id.

Rules:
- One message may do several things; emit one action each.
- Put the date in when (a typed intent) and any clock time in time; echo the \
user's words for a captured task in raw.
- A bare follow-up with no subject of its own ("make it 4pm", "that's urgent", \
"actually thursday", "done with that") refers to the just-discussed or \
replied-to item listed in the context above. If no such item is listed, do not \
guess: return unknown. A message with its own subject ("buy milk tomorrow") is \
NOT a follow-up.
- If the message is a pleasantry (thanks, a greeting), use chitchat; if it is \
some other non-task message, return a single unknown action.
"""


def _format_active(items: list[dict]) -> str:
    if not items:
        return "  (none)"
    return "\n".join(
        f"  {n}: {i['id']}: {i['label']}"
        + (f" (scheduled {i['due_date']})" if i.get("due_date") else "")
        + (f" (deadline {i['deadline_date']})" if i.get("deadline_date") else "")
        + (f" ({i['duration_minutes']}m)" if i.get("duration_minutes") else "")
        + (f" ({i['schedule_kind']})" if i.get("schedule_kind") == "fixed" else "")
        + (f" (depends on {','.join(i['depends_on'])})" if i.get("depends_on") else "")
        + (" (waiting)" if i.get("waiting") else "")
        for n, i in enumerate(items, start=1)
    )


def _format_digest(items: list[dict]) -> str:
    if not items:
        return "  (none)"
    return "\n".join(
        f"  {n}. {i['id']}: {i['label']}" for n, i in enumerate(items, start=1)
    )


def _format_presented(items: list[dict], kind: str | None) -> str:
    if not items:
        return ""
    lines = "\n".join(
        f"  {n}. {i['id']}: {i['label']}" for n, i in enumerate(items, start=1)
    )
    label = "evening recap" if kind == "eod" else (kind or "proactive list")
    return (
        f"\nMost recently presented proactive list (kind: {label}). "
        "References to that displayed list are confined to these items:\n"
        + lines
        + "\n"
    )


def _format_nudge(nudge: dict | None) -> str:
    if not isinstance(nudge, dict):
        return ""
    item_id = nudge.get("item_id")
    label = nudge.get("label")
    kind = nudge.get("kind")
    if not item_id or not label or kind not in {"stale_task", "waiting"}:
        return ""
    choices = "keep, tomorrow, or drop" if kind == "stale_task" else "resume"
    return (
        "\nActive morning digest nudge (machine-owned):\n"
        f'- kind: {kind}; item: {item_id}: {label}; allowed decisions: {choices}.\n'
        "A natural answer to this exact nudge uses nudge_decision. The user does "
        "not need to repeat a command phrase.\n"
    )


def _format_confirmation(pending: bool) -> str:
    if not pending:
        return ""
    return (
        "\nPending risky-action confirmation (machine-owned): Hob is holding a "
        "previous action. A pure approval or rejection uses "
        "confirmation_decision. A revision, condition, new task, or unrelated "
        "message is not approval.\n"
    )


def _format_onboarding(stage: str | None) -> str:
    if not stage:
        return ""
    return (
        f"\nActive onboarding step (machine-owned): {stage}. A natural request "
        "to keep the current value and continue uses onboarding_decision skip; "
        "a request to pause setup uses onboarding_decision cancel.\n"
    )


def _format_pending(pending: list[dict]) -> str:
    """Render the clarifications Hob is waiting on, or "" if none. The model is
    told to answer with the user's date words verbatim (the core resolves them),
    or to ignore the pending question if the message is a new instruction."""
    if not pending:
        return ""
    lines = []
    for p in pending:
        kind = p.get("kind")
        if kind == "capture":
            lines.append(
                f'- you asked "{p["question"]}" for a new task "{p["task"]}". to '
                f'answer, emit a capture with task "{p["task"]}" and when set to '
                'the date intent for the user\'s reply (e.g. {"kind":"weekday",'
                '"day":"thu"} for thursday).'
            )
        elif kind == "reschedule":
            lines.append(
                f'- you asked "{p["question"]}" about "{p["label"]}". to answer, '
                f"emit a reschedule with target {p['target']} and when set to the "
                'date intent for the user\'s reply (e.g. {"kind":"weekday",'
                '"day":"fri"} for friday).'
            )
        elif kind == "setting":
            lines.append(
                f'- you asked "{p["question"]}". to answer, emit a setting with '
                f'key "{p["key"]}" and raw equal to the time words in the reply.'
            )
        elif kind == "query":
            lines.append(
                f'- you asked "{p["question"]}" for a task query. to answer, '
                'emit a query with kind "date" and when set to the date intent '
                "in the user's reply."
            )
        elif kind == "amend":
            lines.append(
                f'- you asked "{p["question"]}" about "{p["label"]}". to '
                f'answer, emit amend with target {p["target"]} and task equal '
                "to the replacement wording in the user's reply."
            )
    return (
        "\nPending question (you asked this last turn and are waiting for the "
        "answer):\n" + "\n".join(lines) + "\nIf the user's message answers a "
        "pending question, emit that action now. If it is instead a new, "
        "unrelated instruction, handle that and ignore the pending question.\n"
    )


def _format_focus(ctx: InterpreterContext) -> str:
    """The conversational anchor for bare follow-ups: the item a replied-to Hob
    message was about (strongest), else the recently touched items."""
    if ctx.replied:
        return (
            "\nThe user is REPLYING to hob's message about this item - bare "
            'words like "done", "snooze 20", "push it to friday" refer to it:\n'
            f"  {ctx.replied['id']}: {ctx.replied['label']}\n"
        )
    if ctx.focus:
        plan_focus = ctx.focus[0].get("context") == "plan"
        lines = "\n".join(
            f"  {n}. {f['id']}: {f['label']}"
            for n, f in enumerate(ctx.focus, start=1)
        )
        if plan_focus:
            return (
                "\nLast proposed plan, in the exact order shown to the user. "
                'Ordinal references such as "the second one" refer to this '
                "order, not the open-list order:\n" + lines + "\n"
            )
        return (
            "\nJust discussed (most recent first) - a bare follow-up refers to "
            "the first of these:\n" + lines + "\n"
        )
    return ""


def _format_forwarded(ctx: InterpreterContext) -> str:
    if not ctx.forwarded_from:
        return ""
    return (
        f'\nThis message was FORWARDED to hob from "{ctx.forwarded_from}". Its '
        "text is something the user wants remembered: capture it as a task with "
        f'a note crediting the sender (e.g. "from {ctx.forwarded_from}"), not as '
        "chit-chat or a command aimed at hob.\n"
    )


def _format_analysis(analysis: dict | None) -> str:
    if not isinstance(analysis, dict) or analysis.get("kind") not in {
        "plan", "outlook"
    }:
        return ""
    return (
        "\nLatest deterministic analysis (machine-owned; explain or test it, "
        "never treat it as permission to mutate):\n"
        + json.dumps(analysis, ensure_ascii=False, sort_keys=True)
        + "\n"
    )


def build_prompt(ctx: InterpreterContext) -> str:
    return _PROMPT.format(
        today=ctx.today,
        weekday=date.fromisoformat(ctx.today).strftime("%A"),
        now=ctx.now,
        timezone=ctx.timezone,
        active=_format_active(ctx.active_items),
        digest=_format_digest(ctx.last_digest),
        presented=_format_presented(ctx.presented_items, ctx.presented_kind),
        analysis=_format_analysis(ctx.analysis),
        nudge=_format_nudge(ctx.nudge),
        confirmation=_format_confirmation(ctx.confirmation_pending),
        onboarding=_format_onboarding(ctx.onboarding_stage),
        pending=_format_pending(ctx.pending),
        focus=_format_focus(ctx),
        forwarded=_format_forwarded(ctx),
        message=ctx.message,
    )


def _str(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def _float(value: object, default: float) -> float:
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _level(value: object) -> str:
    """Normalize a priority/level to high|normal|low; anything else is normal."""
    return value if value in ("high", "normal", "low") else "normal"


def _int(value: object) -> int | None:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


def _ints(value: object) -> list[int]:
    if not isinstance(value, list):
        return []
    return [parsed for parsed in (_int(item) for item in value) if parsed is not None]


def _strings(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return [parsed for parsed in (_str(item) for item in value) if parsed]


def _when(value: object) -> When | None:
    """Parse a typed date intent. Returns None for a missing or no-date intent so
    the planner treats the task as undated."""
    if not isinstance(value, dict):
        return None
    kind = _str(value.get("kind"))
    if kind is None or kind == "none":
        return None
    return When(
        kind=kind,
        which=_str(value.get("which")),
        day=_str(value.get("day")),
        n=_int(value.get("n")),
        unit=_str(value.get("unit")),
        anchor=_str(value.get("anchor")),
        part=_str(value.get("part")),
        month=_int(value.get("month")),
        day_num=_int(value.get("day_num")),
        date=_str(value.get("date")),
    )


def _complete_when_payload(value: object) -> bool:
    """Whether a non-empty typed date has the fields its kind requires."""
    if not isinstance(value, dict):
        return False
    kind = value.get("kind")
    if kind in {"today", "tomorrow", "yesterday", "ambiguous"}:
        return True
    if kind == "weekday":
        return value.get("day") in {"mon", "tue", "wed", "thu", "fri", "sat", "sun"}
    if kind == "offset":
        return _int(value.get("n")) is not None and value.get("unit") in {
            "day", "week", "month", "year"
        }
    if kind in {"weekend", "week"}:
        return value.get("which") in {"this", "next"}
    if kind == "month":
        return (
            value.get("which") in {"this", "next"}
            and value.get("anchor") in {"start", "end"}
        )
    if kind == "month_day":
        return _int(value.get("month")) is not None and _int(
            value.get("day_num")
        ) is not None
    if kind == "ordinal_day":
        return _int(value.get("day_num")) is not None
    if kind == "absolute":
        return bool(_str(value.get("date")))
    return False


def _parse_one(action: object):
    if not isinstance(action, dict):
        return Unknown(note="non-object action")
    kind = action.get("type")
    conf = _float(action.get("confidence"), 1.0)

    if kind == "capture":
        task = _str(action.get("task"))
        raw = _str(action.get("raw"))
        if not task and not raw:
            return Unknown(note="capture without text")
        return Capture(
            task=task or raw,
            raw=raw or task,
            when=_when(action.get("when")),
            time=_str(action.get("time")),
            relate=_str(action.get("relate")),
            repeat=_str(action.get("repeat")),
            priority=_level(action.get("priority")),
            tag=_str(action.get("tag")),
            waiting=bool(action.get("waiting")),
            note=_str(action.get("note")),
            deadline=_when(action.get("deadline")),
            duration_minutes=_int(action.get("duration_minutes")),
            duration_confidence=_float(action.get("duration_confidence"), 1.0),
            schedule_kind=_str(action.get("schedule_kind")) or "flexible",
            splittable=bool(action.get("splittable")),
            earliest=_when(action.get("earliest")),
            earliest_time=_str(action.get("earliest_time")),
            preferred_window=_str(action.get("preferred_window")),
            parent=_str(action.get("parent")),
            depends_on=_strings(action.get("depends_on")),
            reminder_offsets=_ints(action.get("reminder_offsets")),
            repeat_anchor=_str(action.get("repeat_anchor")) or "fixed",
            repeat_end=_when(action.get("repeat_end")),
            repeat_count=_int(action.get("repeat_count")),
            confidence=conf,
        )
    if kind == "schedule":
        target = _str(action.get("target"))
        if not target:
            return Unknown(note="schedule without target")
        return Schedule(
            target=target,
            deadline=_when(action.get("deadline")),
            duration_minutes=_int(action.get("duration_minutes")),
            duration_confidence=_float(action.get("duration_confidence"), 1.0),
            schedule_kind=_str(action.get("schedule_kind")),
            splittable=(
                bool(action.get("splittable"))
                if action.get("splittable") is not None
                else None
            ),
            earliest=_when(action.get("earliest")),
            earliest_time=_str(action.get("earliest_time")),
            preferred_window=_str(action.get("preferred_window")),
            depends_on=_strings(action.get("depends_on")),
            reminder_offsets=_ints(action.get("reminder_offsets")),
            clear=_strings(action.get("clear")),
            confidence=conf,
        )
    if kind == "recur":
        target = _str(action.get("target"))
        op = _str(action.get("op"))
        if not target or op not in ("skip", "stop", "anchor", "end"):
            return Unknown(note="recur without target or valid op")
        return Recur(
            target=target,
            op=op,
            anchor=_str(action.get("anchor")),
            end=_when(action.get("end")),
            count=_int(action.get("count")),
            confidence=conf,
        )
    if kind == "note":
        target, text = _str(action.get("target")), _str(action.get("text"))
        return (
            Note(target=target, text=text, confidence=conf)
            if target and text
            else Unknown(note="note without target or text")
        )
    if kind == "wait":
        target = _str(action.get("target"))
        return Wait(target=target, confidence=conf) if target else Unknown(
            note="wait without target"
        )
    if kind == "resume":
        target = _str(action.get("target"))
        return Resume(target=target, confidence=conf) if target else Unknown(
            note="resume without target"
        )
    if kind == "setting":
        key = _str(action.get("key"))
        raw = _str(action.get("raw"))
        return (
            Setting(
                key=key,
                raw=raw,
                time=_str(action.get("time")),
                start_time=_str(action.get("start_time")),
                end_time=_str(action.get("end_time")),
                days=_strings(action.get("days")),
                minutes=_int(action.get("minutes")),
                clear=bool(action.get("clear")),
                confidence=conf,
            )
            if key and raw
            else Unknown(note="setting without key or value")
        )
    if kind == "start":
        target = _str(action.get("target"))
        return Start(target=target, confidence=conf) if target else Unknown(
            note="start without target"
        )
    if kind == "plan_action":
        op = _str(action.get("op"))
        return (
            PlanAction(op=op, confidence=conf)
            if op in {"adopt", "replace", "cancel"}
            else Unknown(note="plan action without valid operation")
        )
    if kind == "prioritize":
        target = _str(action.get("target"))
        return (
            Prioritize(target=target, level=_level(action.get("level")), confidence=conf)
            if target
            else Unknown(note="prioritize without target")
        )
    if kind == "amend":
        target = _str(action.get("target"))
        new_task = _str(action.get("task"))
        if not target or not new_task:
            return Unknown(note="amend without target or text")
        return Amend(target=target, task=new_task, confidence=conf)
    if kind == "complete":
        target = _str(action.get("target"))
        return Complete(target=target, confidence=conf) if target else Unknown(
            note="complete without target"
        )
    if kind == "drop":
        target = _str(action.get("target"))
        return (
            Drop(target=target, reason=_str(action.get("reason")), confidence=conf)
            if target
            else Unknown(note="drop without target")
        )
    if kind == "reschedule":
        target = _str(action.get("target"))
        return (
            Reschedule(
                target=target,
                when=_when(action.get("when")),
                time=_str(action.get("time")),
                confidence=conf,
            )
            if target
            else Unknown(note="reschedule without target")
        )
    if kind == "query":
        return Query(
            kind=_str(action.get("kind")) or "today",
            when=_when(action.get("when")),
            term=_str(action.get("term")),
            tag=_str(action.get("tag")),
            constraint=_str(action.get("constraint")),
            budget_minutes=_int(action.get("budget_minutes")),
            budget_delta_minutes=_int(action.get("budget_delta_minutes")),
            budget_scope=_str(action.get("budget_scope")),
            energy=_str(action.get("energy")),
            earliest_time=_str(action.get("earliest_time")),
            latest_time=_str(action.get("latest_time")),
            period=_str(action.get("period")),
            target=_str(action.get("target")),
            aspect=_str(action.get("aspect")),
            duration_minutes=_int(action.get("duration_minutes")),
            splittable=(
                bool(action.get("splittable"))
                if action.get("splittable") is not None
                else None
            ),
            work_start=_str(action.get("work_start")),
            work_end=_str(action.get("work_end")),
        )
    if kind == "bulk":
        op = _str(action.get("op"))
        if op not in ("complete", "drop", "reschedule"):
            return Unknown(note="bulk without a valid op")
        return Bulk(
            op=op,
            scope=_str(action.get("scope")) or "today",
            when=_when(action.get("when")),
            exclude=[e for e in map(_str, action.get("except") or []) if e],
            confidence=conf,
        )
    if kind == "snooze":
        target = _str(action.get("target"))
        if not target:
            return Unknown(note="snooze without target")
        return Snooze(target=target, minutes=_int(action.get("minutes")) or 10, confidence=conf)
    if kind == "recap":
        outcome = _str(action.get("outcome"))
        return (
            Recap(outcome=outcome, confidence=conf)
            if outcome == "none"
            else Unknown(note="recap without a valid outcome")
        )
    if kind == "nudge_decision":
        decision = _str(action.get("decision"))
        return (
            NudgeDecision(decision=decision, confidence=conf)
            if decision in {"keep", "tomorrow", "drop", "resume"}
            else Unknown(note="nudge decision without a valid outcome")
        )
    if kind == "confirmation_decision":
        decision = _str(action.get("decision"))
        return (
            ConfirmationDecision(decision=decision, confidence=conf)
            if decision in {"approve", "reject"}
            else Unknown(note="confirmation decision without a valid outcome")
        )
    if kind == "onboarding_decision":
        decision = _str(action.get("decision"))
        return (
            OnboardingDecision(decision=decision, confidence=conf)
            if decision in {"skip", "cancel"}
            else Unknown(note="onboarding decision without a valid outcome")
        )
    if kind == "undo":
        return Undo()
    if kind == "chitchat":
        return Chitchat(reply=_str(action.get("reply")))
    if kind == "unknown":
        return Unknown(note=_str(action.get("note")))
    return Unknown(note=f"unhandled type {kind!r}")


def parse_actions(payload: object) -> list:
    if not isinstance(payload, dict):
        return [Unknown(note="non-object response")]
    actions = payload.get("actions")
    if not isinstance(actions, list):
        return [Unknown(note="missing actions array")]
    parsed = [_parse_one(a) for a in actions]
    return parsed or [Unknown(note="empty actions")]


def _recap_adjudication_prompt(ctx: InterpreterContext) -> str:
    listed = "\n".join(
        f"- {item.get('id', '?')}: {item.get('label', '')}"
        for item in ctx.presented_items
    )
    return f"""\
The assistant most recently asked the user an evening recap question about
which displayed tasks they completed:
{listed}

The user's answer:
{ctx.message}

Classify the answer by meaning in this conversational context, not by matching
particular words. Interpret terse language, slang, idiom, humor, and the user's
language naturally.

The existence of the recap is not evidence that every later message answers it.
First decide whether the message actually makes a claim about the user's work
outcome. Gratitude, a greeting, affection, or a conversational acknowledgment
alone is social and does not imply zero work.

Return outcome "none" only when the message semantically reports that zero
displayed tasks were completed. Return outcome "social" for a social remark
with no task or recap answer. Return outcome "other" for questions, new tasks,
commands, partial progress, or any report that some work was completed. Include
a confidence from 0 to 1.
"""


def _context_decision_prompt(ctx: InterpreterContext) -> str:
    if ctx.nudge:
        context = (
            f"a morning digest asked about {ctx.nudge.get('item_id')}: "
            f"{ctx.nudge.get('label')}. Its kind is {ctx.nudge.get('kind')}. "
            "A stale-task answer may mean keep it on deck, defer it to tomorrow, "
            "or drop it. A waiting-task answer may mean its blocker cleared."
        )
    elif ctx.confirmation_pending:
        context = (
            "the assistant is holding a risky action and asked whether to apply "
            "or cancel it. Approval must be pure; a revision, exception, "
            "condition, new task, or unrelated message is not approval."
        )
    else:
        context = (
            f"setup is asking for the {ctx.onboarding_stage} preference. The "
            "user may keep the displayed value and continue, pause setup, give "
            "a new value, or say something unrelated."
        )
    return f"""\
Classify the user's message against this exact machine-owned conversational
question:
{context}

User message:
{ctx.message}

Reason by meaning, including paraphrase, slang, idiom, humor, or another
language. Return keep, tomorrow, drop, resume, approve, reject, skip, or cancel
only when that is the semantic answer to this exact question. Return other for
any new task, query, setting value, revised/conditional instruction, or
unrelated message. Include confidence from 0 to 1.
"""


def _adjudicate_context(actions: list, ctx: InterpreterContext, llm: Llm) -> list:
    if not (ctx.nudge or ctx.confirmation_pending or ctx.onboarding_stage):
        return actions
    try:
        verdict = llm.complete_json(
            _context_decision_prompt(ctx), CONTEXT_DECISION_SCHEMA
        )
    except Exception:
        return actions
    if not isinstance(verdict, dict):
        return actions
    outcome = verdict.get("outcome")
    confidence = _float(verdict.get("confidence"), 0.0)
    if outcome == "other":
        return actions
    if ctx.nudge and outcome in {"keep", "tomorrow", "drop", "resume"}:
        return [NudgeDecision(decision=outcome, confidence=confidence)]
    if ctx.confirmation_pending and outcome == "approve":
        # Releasing a held mutation requires two independent model passes to
        # agree on pure approval. A conditional revision commonly looks like
        # assent in isolation, so one classifier can never release it alone.
        if len(actions) == 1 and isinstance(actions[0], ConfirmationDecision):
            if actions[0].decision == "approve":
                return [ConfirmationDecision(decision=outcome, confidence=confidence)]
        return actions
    if ctx.confirmation_pending and outcome == "reject":
        return [ConfirmationDecision(decision=outcome, confidence=confidence)]
    if ctx.onboarding_stage and outcome in {"skip", "cancel"}:
        return [OnboardingDecision(decision=outcome, confidence=confidence)]
    return actions


def _bulk_scope_prompt(ctx: InterpreterContext) -> str:
    displayed = ctx.presented_items or ctx.last_digest
    presented = "\n".join(
        f"{position}. {item.get('id')}: {item.get('label')}"
        for position, item in enumerate(displayed, start=1)
    ) or "(none)"
    active = "\n".join(
        f"{position}. {item.get('id')}: {item.get('label')}"
        for position, item in enumerate(ctx.active_items, start=1)
    ) or "(none)"
    return f"""\
The user's message was interpreted as an action over several tasks.
Independently classify which set of tasks the user semantically selected and
which exact task ids the user excluded:
- all: every open task, regardless of date
- today: work currently on deck today
- date: tasks on one specifically named date
- presented: only the exact recently displayed list below
- unclear: no reliable bulk set

Recently displayed list:
{presented}

All currently open tasks:
{active}

User message:
{ctx.message}

Use ordinary language understanding, not a stock phrase list. Resolve numbered
exclusions against the displayed positions. Return exclude as an empty list
when nothing was excluded. Never put an excluded task into the selected set.
"Everything on that list" selects presented even though it contains the word
"everything"; plain "everything" with no displayed-list reference selects all.
When one displayed task gets a different destination, it remains inside the
presented set rather than expanding the other destination to unrelated tasks.
For a bulk reschedule, also classify the destination date words as a typed when
intent; otherwise use kind none. Include confidence from 0 to 1.
"""


def _adjudicate_bulk_scope(actions: list, ctx: InterpreterContext, llm: Llm) -> list:
    bulks = [action for action in actions if isinstance(action, Bulk)]
    direct = [
        action for action in actions
        if isinstance(action, (Complete, Drop, Reschedule))
    ]
    displayed = ctx.presented_items or ctx.last_digest
    displayed_ids = {
        str(item.get("id"))
        for item in displayed
        if item.get("id") is not None
    }
    direct_scope_risk = (
        len(direct) >= 2
        and bool(displayed_ids)
        and any(action.target not in displayed_ids for action in direct)
    )
    if not bulks and not direct_scope_risk:
        return actions
    try:
        verdict = llm.complete_json(_bulk_scope_prompt(ctx), BULK_SCOPE_SCHEMA)
    except Exception:
        return [Unknown(note=MODEL_UNREACHABLE)] if direct_scope_risk else actions
    if not isinstance(verdict, dict):
        return [Unknown(note=MODEL_UNREACHABLE)] if direct_scope_risk else actions
    scope = verdict.get("scope")
    proposed_when = _when(verdict.get("when"))
    proposed_exclusions = verdict.get("exclude")
    confidence = _float(verdict.get("confidence"), 0.0)
    if scope == "presented" and not displayed_ids:
        # The model cannot select a machine-owned list that does not exist.
        # Preserve the first-pass typed scope instead of turning a valid bulk
        # action into an impossible presented-list operation.
        return actions
    if scope == "unclear" or confidence < 0.5:
        if direct_scope_risk:
            return [Unknown(note="multi-task scope was not clear")]
        for action in bulks:
            action.confidence = min(action.confidence, confidence)
        return actions
    if scope in {"all", "today", "date", "presented"}:
        valid_ids = {
            str(item.get("id"))
            for item in [*ctx.active_items, *ctx.presented_items, *ctx.last_digest]
            if item.get("id") is not None
        }
        for action in bulks:
            action.scope = scope
            if action.op == "reschedule" and proposed_when is not None:
                action.when = proposed_when
            if isinstance(proposed_exclusions, list):
                action.exclude = list(dict.fromkeys(
                    str(item_id)
                    for item_id in proposed_exclusions
                    if str(item_id) in valid_ids
                ))
            action.confidence = min(action.confidence, confidence)
        if scope == "presented" and direct:
            actions = [
                action for action in actions
                if not isinstance(action, (Complete, Drop, Reschedule))
                or action.target in displayed_ids
            ]
    return actions


def _shared_capture_date_prompt(actions: list, ctx: InterpreterContext) -> str:
    captures = [
        {
            "index": index,
            "task": action.task,
            "raw": action.raw,
            "when": action.when.__dict__ if action.when else None,
        }
        for index, action in enumerate(actions, start=1)
        if isinstance(action, Capture)
    ]
    return f"""\
Several tasks were captured from one message, but the first pass applied a date
to only some of them. Decide whether one date phrase semantically scopes every
captured task.

Today is {ctx.today}. Classify date words into a typed intent; never compute the
calendar date.

User message:
{ctx.message}

First-pass captures:
{json.dumps(captures, ensure_ascii=False, sort_keys=True)}

Set applies_to_all true only when the message gives one shared date for the
whole coordinated task list. A leading date such as "tomorrow I need to A, B,
and C" applies to all three, even when later tasks contain clock times. A clock
time is not a competing date. Set applies_to_all false when tasks have distinct
dates, a task is explicitly left undated, or the scope is uncertain. When true,
return the shared typed date in when. When false, return kind none. Include
confidence.
"""


def _adjudicate_shared_capture_date(
    actions: list, ctx: InterpreterContext, llm: Llm
) -> list:
    captures = [action for action in actions if isinstance(action, Capture)]
    if (
        len(captures) < 2
        or not any(action.when is not None for action in captures)
        or not any(action.when is None for action in captures)
    ):
        return actions
    try:
        verdict = llm.complete_json(
            _shared_capture_date_prompt(actions, ctx),
            SHARED_CAPTURE_DATE_SCHEMA,
        )
    except Exception:
        return actions
    if (
        not isinstance(verdict, dict)
        or verdict.get("applies_to_all") is not True
        or _float(verdict.get("confidence"), 0.0) < 0.6
        or not _complete_when_payload(verdict.get("when"))
    ):
        return actions
    shared = _when(verdict["when"])
    if shared is None:
        return actions
    for action in captures:
        if action.when is None:
            action.when = shared
    return actions


def _audit_context(ctx: InterpreterContext) -> str:
    active = "\n".join(
        f"{position}. {item.get('id')}: {item.get('label')}"
        for position, item in enumerate(ctx.active_items, start=1)
    ) or "(none)"
    focus = "\n".join(
        f"- {item.get('id')}: {item.get('label')}"
        for item in ctx.focus
    ) or "(none)"
    return f"""\
Today is {ctx.today} ({date.fromisoformat(ctx.today).strftime('%A')}). Do not
compute dates; represent date words with typed intents.

Open tasks, in position order:
{active}

Just-discussed or replied-to tasks:
{focus}

Recent undoable change timestamp: {ctx.last_change_at or 'none'}

Latest deterministic analysis:
{json.dumps(ctx.analysis, ensure_ascii=False, sort_keys=True) if ctx.analysis else '(none)'}
"""


def _capture_audit_prompt(payload: object, ctx: InterpreterContext) -> str:
    return f"""\
Independently audit a first-pass interpretation. Classify the user's complete
communicative goal as exactly one type:
- capture: remember a concrete new piece of work;
- plan: choose or replan what work to do, including constraints implied by
  ordinary descriptions of time, energy, or lost availability;
- outlook: read-only capacity or fit analysis, without choosing a plan;
- explain: ask why the latest deterministic plan/outlook produced a result,
  what assumptions it used, or what would need to change;
- what_if: rerun that latest analysis with an explicitly hypothetical time,
  energy, estimate, or split assumption, without making it durable;
- plan_action: explicitly adopt, replace, or cancel a proposed/adopted plan;
- undo: retract the recent change shown in context;
- other: none of those.

{_audit_context(ctx)}

User message:
{ctx.message}

First-pass JSON:
{json.dumps(payload, ensure_ascii=False, sort_keys=True)}

Reason by meaning, including idiom, slang, paraphrase, and negation. The first
pass is evidence, not authority. A task containing planning-related words is
still capture when the user wants it remembered. A request to choose or replan
work is plan, not a task or plan adoption. A plain task description remains a
capture even when it begins with a date or says "I need to"; "Tomorrow I need
to call Jerry" is capture, and "lunch with Sam Thursday or Friday" is capture
with an ambiguous date. "No gas left, give me a realistic plan" is plan.
Questions about overload or what will fit are outlook. "Use this plan" is
plan_action adopt and "replace my plan with this" is plan_action replace. A
standalone retraction is undo only when a recent change exists.

Use explain or what_if only when a latest deterministic analysis exists and
the user semantically refers to it. A hypothetical estimate ("what if taxes
took 30 minutes?") is what_if, never a durable schedule edit. Extract its exact
task id from the saved analysis. "Why did this not fit?" is explain. "What
would need to change?" is explain with aspect changes.

For capture, extract a clean task and every scheduling detail. A hard
"by/before/no later than" date belongs in deadline while the intended work date
belongs in when. Preserve effort, split permission, fixed appointment status,
earliest start, window, dependencies, reminders, recurrence interval,
completion-relative anchor, ending date/count, priority, tag, waiting state,
and note when the user actually implies them. Named weekdays are weekday
intents. Recurrence belongs in repeat, never in when: daily -> "daily"; every
Monday -> "weekly:monday"; every 2 months -> "every:2:month". A cadence after
completion uses repeat_anchor "completion"; preserve an explicit total in
repeat_count. Never move a date from the user's words to a different kind.
"Remind me to pay my taxes Monday" is capture task "pay my taxes" with when
weekday mon; strip the reminder-request prefix but never drop its weekday.
For every capture, explicitly return kind none for absent deadline/repeat-end
dates and null for absent scalar fields rather than omitting them. A sentence
with a do date and a separate due date must return both.

For plan, return the planning date intent plus typed budget, scope, energy, and
earliest/latest clock bounds. With no date words, when must be kind none; never
invent a planning day. Infer ordinary constraints: "no gas left" means energy
low, and "the first half of the day is shot" means earliest_time 12:00. These
are planning constraints, not dates.

For explain, return target when a task is named and aspect why, changes, or
assumptions. For what_if, return a task target only for a task-specific
assumption, a temporary duration/splittable value, an absolute budget or signed
budget delta, and typed energy/earliest/latest values. Never turn a hypothetical
into a setting or task mutation. Return only the audit object.
"""


def _schedule_audit_prompt(payload: object, ctx: InterpreterContext) -> str:
    return f"""\
Independently audit a proposed scheduling-metadata edit to an existing task.
Return type schedule only if the user actually changes a deadline, effort,
fixed/flexible status, split permission, earliest start, preferred window,
dependency, reminder offset, or clears one of those. Otherwise return other.

{_audit_context(ctx)}

User message:
{ctx.message}

First-pass JSON:
{json.dumps(payload, ensure_ascii=False, sort_keys=True)}

Use the exact matching task id from context. A hard due/by/before date is the
deadline and must be represented as the user's typed date intent; do not
compute it and do not substitute today or tomorrow for a named weekday.
Extract explicit effort and all other metadata without moving the task's do
date. The first pass is evidence, not authority. Return only the audit object.
"""


def _setting_audit_prompt(payload: object, ctx: InterpreterContext) -> str:
    return f"""\
Independently audit a first-pass user-preference change. Return the same typed
setting contract with every value field present. The raw field must be a
literal substring of the user's message; never invent or normalize it.

{_audit_context(ctx)}

User message:
{ctx.message}

First-pass JSON:
{json.dumps(payload, ensure_ascii=False, sort_keys=True)}

Extract clock values as HH:MM, day ranges as mon..sun codes, and durations as
minutes. A working-hours or protected-break range needs both start_time and
end_time. A wake/evening setting uses time. Removal uses clear true. Use null,
false, or an empty list for value fields the user did not set. The first pass
is evidence, not authority. Return only the setting object.
"""


def _route_tiebreak_prompt(
    ctx: InterpreterContext, first_route: str, audit_route: str
) -> str:
    return f"""\
Independently classify the communicative goal of one user message. Do not vote
for a prior classifier and do not assume an audit is better; return the actual
semantic outcome.

User message:
{ctx.message}

Two earlier passes disagreed between {first_route} and {audit_route}.

Meanings:
- capture: remember a concrete new task, including a standalone task phrase or
  "I need to" statement with a date;
- plan: ask the assistant to choose or replan work;
- outlook: ask read-only what fits or whether capacity is overloaded;
- explain: ask why the latest deterministic analysis produced its result;
- what_if: test a temporary assumption against the latest analysis;
- plan_action: explicitly adopt, replace, or cancel a plan;
- undo: retract a recent change;
- other: none of these.

For example, "lunch with Sam Thursday or Friday" is capture even though its
date is ambiguous; "the first half of the day is shot, replan" is plan, not a
plan action; and a request for a realistic plan is plan. Reason semantically,
including idiom and paraphrase. Include confidence.
"""


def _route_name(action: object) -> str | None:
    if isinstance(action, Capture):
        return "capture"
    if isinstance(action, PlanAction):
        return "plan_action"
    if isinstance(action, Query) and action.kind in {
        "plan", "outlook", "explain", "what_if"
    }:
        return action.kind
    if isinstance(action, Undo):
        return "undo"
    if isinstance(action, (Unknown, Chitchat)):
        return "other"
    return None


def _candidate_audit_kind(actions: list, ctx: InterpreterContext) -> str | None:
    if (
        len(actions) != 1
        or (ctx.presented_kind == "eod" and ctx.presented_items)
        or ctx.nudge
        or ctx.confirmation_pending
        or ctx.onboarding_stage
        or ctx.pending
    ):
        return None
    action = actions[0]
    if isinstance(action, Schedule):
        return "schedule"
    if isinstance(action, Setting):
        return "setting"
    if isinstance(action, (Capture, PlanAction, Unknown)):
        return "capture"
    if isinstance(action, Chitchat) and ctx.last_change_at:
        return "capture"
    if isinstance(action, Query) and action.kind in {
        "plan", "outlook", "explain", "what_if"
    }:
        return "capture"
    return None


def _review_candidate(
    payload: object, actions: list, ctx: InterpreterContext, llm: Llm
) -> list:
    audit_kind = _candidate_audit_kind(actions, ctx)
    if audit_kind is None:
        return actions
    try:
        if audit_kind == "schedule":
            verdict = llm.complete_json(
                _schedule_audit_prompt(payload, ctx), SCHEDULE_AUDIT_SCHEMA
            )
        elif audit_kind == "setting":
            verdict = llm.complete_json(
                _setting_audit_prompt(payload, ctx), SETTING_AUDIT_SCHEMA
            )
        else:
            verdict = llm.complete_json(
                _capture_audit_prompt(payload, ctx), CAPTURE_AUDIT_SCHEMA
            )
    except Exception:
        return actions
    if not isinstance(verdict, dict):
        return actions
    outcome = verdict.get("type")
    first_route = _route_name(actions[0])
    if (
        audit_kind == "capture"
        and outcome in {
            "capture", "plan", "outlook", "explain", "what_if",
            "plan_action", "undo",
        }
        and first_route is not None
        and outcome != first_route
        and not (
            outcome == "undo"
            and bool(ctx.last_change_at)
            and _float(verdict.get("confidence"), 0.0) >= 0.8
        )
    ):
        try:
            tiebreak = llm.complete_json(
                _route_tiebreak_prompt(ctx, first_route, outcome),
                ROUTE_TIEBREAK_SCHEMA,
            )
        except Exception:
            return actions
        if (
            not isinstance(tiebreak, dict)
            or tiebreak.get("outcome") != outcome
            or _float(tiebreak.get("confidence"), 0.0) < 0.6
        ):
            return actions
    if outcome == "capture" and isinstance(actions[0], Capture):
        first = (
            payload.get("actions", [None])[0]
            if isinstance(payload, dict) and isinstance(payload.get("actions"), list)
            and payload.get("actions")
            else None
        )
        if isinstance(first, dict):
            # A focused pass corrects semantic routing and extraction, but it
            # must not erase useful typed detail the independent first pass
            # supplied merely by returning null/none. This merge is structural,
            # never an interpretation of the user's English.
            for key in (
                "time", "relate", "repeat", "tag", "note",
                "duration_minutes", "duration_confidence", "earliest_time",
                "preferred_window", "parent", "repeat_anchor", "repeat_count",
            ):
                if verdict.get(key) is None and first.get(key) is not None:
                    verdict[key] = first[key]
            for key in ("depends_on", "reminder_offsets"):
                if not verdict.get(key) and first.get(key):
                    verdict[key] = first[key]
            for key in ("deadline", "repeat_end"):
                reviewed_when = verdict.get(key)
                first_when = first.get(key)
                if (
                    isinstance(reviewed_when, dict)
                    and reviewed_when.get("kind") == "none"
                    and isinstance(first_when, dict)
                    and first_when.get("kind") != "none"
                ):
                    verdict[key] = first_when
            if (
                _complete_when_payload(first.get("when"))
                and not _complete_when_payload(verdict.get("when"))
            ):
                verdict["when"] = first["when"]
            if not verdict.get("splittable") and first.get("splittable"):
                verdict["splittable"] = True
    if outcome in {"capture", "schedule", "setting", "plan_action"}:
        return [_parse_one(verdict)]
    if outcome == "undo" and ctx.last_change_at:
        return [Undo()]
    if outcome in {"plan", "outlook", "explain", "what_if"}:
        return [Query(
            kind=outcome,
            when=_when(verdict.get("when")),
            constraint=ctx.message,
            budget_minutes=_int(verdict.get("budget_minutes")),
            budget_delta_minutes=_int(verdict.get("budget_delta_minutes")),
            budget_scope=_str(verdict.get("budget_scope")),
            energy=_str(verdict.get("energy")),
            earliest_time=_str(verdict.get("earliest_time")),
            latest_time=_str(verdict.get("latest_time")),
            target=_str(verdict.get("target")),
            aspect=_str(verdict.get("aspect")),
            duration_minutes=_int(verdict.get("duration_minutes")),
            splittable=(
                bool(verdict.get("splittable"))
                if verdict.get("splittable") is not None
                else None
            ),
            work_start=_str(verdict.get("work_start")),
            work_end=_str(verdict.get("work_end")),
        )]
    return actions


def _hypothetical_audit_prompt(
    payload: object, actions: list, ctx: InterpreterContext
) -> str:
    return f"""\
Independently decide whether the user is testing a temporary counterfactual
against the latest deterministic analysis or making a durable change now.

Latest deterministic analysis:
{json.dumps(ctx.analysis, ensure_ascii=False, sort_keys=True)}

User message:
{ctx.message}

First-pass JSON:
{json.dumps(payload, ensure_ascii=False, sort_keys=True)}

Parsed first-pass action types:
{[type(action).__name__ for action in actions]}

Return outcome what_if when the user asks what would happen under an imagined,
conditional, tentative, or counterfactual assumption. This includes a
hypothetical task duration, split permission, available-minute budget, energy,
working bound, move, completion, deletion, or preference. A what-if never
authorizes the corresponding durable mutation. Extract only supported temporary
inputs: exact saved-analysis task id, duration_minutes, splittable,
budget_minutes, signed budget_delta_minutes, budget_scope, energy,
earliest_time, latest_time, work_start, or work_end. Unsupported hypothetical
changes may leave all typed inputs null; the core will ask a safe follow-up.
Set target null when no specific saved-analysis task is named.

Extract every temporary assumption in a combined message. For example, "what
if the pool call only took 30 minutes and I could work until 10:30?" must return
target for the pool task, duration_minutes 30, and work_end "10:30". "What if I
had 90 minutes a day?" returns budget_minutes 90 and budget_scope "day".
"Would another hour help?" returns budget_delta_minutes 60. Use null for every
typed value the user did not imply; do not omit required fields.

Return outcome durable when the user states or commands a real change now,
such as "the audit takes 30 minutes", "change it to 30 minutes", "move it to
Friday", "drop it", or "buy milk tomorrow". A durable declaration does not
become a what-if merely because a previous analysis exists, because it includes
a date/time, or because the first pass proposed a scheduling edit.

High-priority contrasts:
- "the audit takes 30 minutes now" -> durable;
- "what if the audit only took 30 minutes?" -> what_if;
- "buy milk tomorrow" -> durable;
- "if I can grind until 7, does the rest fit?" -> what_if with work_end 19:00.

A question mark alone is not decisive; interpret the communicative meaning,
including idiom and slang. Include confidence.
"""


def _adjudicate_hypothetical(
    payload: object, actions: list, ctx: InterpreterContext, llm: Llm
) -> list:
    """A counterfactual about a saved result can never leak into a mutation."""
    mutating = (
        Capture,
        Schedule,
        Recur,
        Note,
        Wait,
        Resume,
        Setting,
        Start,
        PlanAction,
        Prioritize,
        Amend,
        Complete,
        Drop,
        Reschedule,
        Bulk,
        Snooze,
        Undo,
    )
    if (
        not isinstance(ctx.analysis, dict)
        or ctx.forwarded_from
        or ctx.nudge
        or ctx.confirmation_pending
        or ctx.onboarding_stage
        or ctx.pending
        or not any(isinstance(action, mutating) for action in actions)
    ):
        return actions
    try:
        verdict = llm.complete_json(
            _hypothetical_audit_prompt(payload, actions, ctx),
            HYPOTHETICAL_AUDIT_SCHEMA,
        )
    except Exception:
        return [Unknown(note=MODEL_UNREACHABLE)]
    if not isinstance(verdict, dict):
        return [Unknown(note=MODEL_UNREACHABLE)]
    outcome = verdict.get("outcome")
    confidence = _float(verdict.get("confidence"), 0.0)
    if outcome == "durable" and confidence >= 0.6:
        return actions
    if outcome != "what_if" or confidence < 0.6:
        return [Unknown(note=MODEL_UNREACHABLE)]
    return [
        Query(
            kind="what_if",
            constraint=ctx.message,
            target=_str(verdict.get("target")),
            budget_minutes=_int(verdict.get("budget_minutes")),
            budget_delta_minutes=_int(verdict.get("budget_delta_minutes")),
            budget_scope=_str(verdict.get("budget_scope")),
            energy=_str(verdict.get("energy")),
            earliest_time=_str(verdict.get("earliest_time")),
            latest_time=_str(verdict.get("latest_time")),
            duration_minutes=_int(verdict.get("duration_minutes")),
            splittable=(
                bool(verdict.get("splittable"))
                if verdict.get("splittable") is not None
                else None
            ),
            work_start=_str(verdict.get("work_start")),
            work_end=_str(verdict.get("work_end")),
        )
    ]


def _needs_recap_adjudication(actions: list, ctx: InterpreterContext) -> bool:
    """Whether a recap-adjacent result needs focused semantic validation."""
    return (
        ctx.presented_kind == "eod"
        and bool(ctx.presented_items)
        and not ctx.forwarded_from
        and not ctx.pending
        and len(actions) == 1
        and isinstance(actions[0], (Recap, Chitchat, Unknown))
    )


def interpret(llm: Llm, ctx: InterpreterContext) -> list:
    prompt = build_prompt(ctx)
    try:
        payload = llm.complete_json(prompt, ACTION_SCHEMA)
    except Exception:
        return [Unknown(note=MODEL_UNREACHABLE)]
    actions = parse_actions(payload)
    actions = _adjudicate_context(actions, ctx, llm)
    actions = _review_candidate(payload, actions, ctx, llm)
    actions = _adjudicate_shared_capture_date(actions, ctx, llm)
    actions = _adjudicate_hypothetical(payload, actions, ctx, llm)
    actions = _adjudicate_bulk_scope(actions, ctx, llm)
    if not _needs_recap_adjudication(actions, ctx):
        return actions
    try:
        verdict = llm.complete_json(
            _recap_adjudication_prompt(ctx), RECAP_OUTCOME_SCHEMA
        )
    except Exception:
        return actions
    outcome = verdict.get("outcome") if isinstance(verdict, dict) else None
    if outcome == "none":
        return [
            Recap(
                outcome="none",
                confidence=_float(verdict.get("confidence"), 0.0),
            )
        ]
    if outcome == "social":
        return actions if isinstance(actions[0], Chitchat) else [Chitchat()]
    if isinstance(actions[0], Recap):
        return [Unknown(note="recap outcome not confirmed")]
    return actions
