# SPDX-License-Identifier: MIT
"""Interpreter: the spine. Builds the model prompt, parses and validates the
forced JSON into Actions. Deterministic reconciliation happens in planner.py.

The model call is injected via core.ports.Llm; this module performs no I/O. The
model proposes; the core decides. Malformed or surprising output degrades to a
single Unknown action so the edge can ask rather than crash.

The model only ever proposes a target id and a date phrase. The core validates
the id against the active list and re-resolves every date itself.
"""
from __future__ import annotations

from datetime import date

from core.models import (
    Amend,
    Bulk,
    Capture,
    Chitchat,
    Complete,
    Drop,
    InterpreterContext,
    Note,
    Prioritize,
    Query,
    Reschedule,
    Resume,
    Setting,
    Snooze,
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
                         "tag": _STR, "waiting": {"type": ["boolean", "null"]},
                         "note": _STR, "confidence": _NUM},
                        ["type", "raw", "when"],
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
                        {"key": {"type": "string", "enum": ["wake_time", "eod_time"]},
                         "raw": _STR},
                        ["type", "key", "raw"],
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
                            "done", "tag", "waiting"]},
                         "when": _WHEN, "term": _STR, "tag": _STR},
                        ["type", "kind"],
                    ),
                    _variant(
                        "bulk",
                        {"op": _STR, "scope": _STR, "when": _WHEN, "confidence": _NUM},
                        ["type", "op", "scope"],
                    ),
                    _variant(
                        "snooze",
                        {"target": _STR, "minutes": _NUM, "confidence": _NUM},
                        ["type", "target", "minutes"],
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
{pending}{focus}{forwarded}
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
note to any extra detail worth keeping with the task, else null.
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
("wake_time" = when the morning digest is sent; "eod_time" = when the evening \
"what got done?" recap is sent), raw (the time words, e.g. "6:30", "8am"). Use \
for "change my wake time to 6:30", "send the digest at 8", "do the evening \
check-in at 9".
- prioritize: change the importance of an item ALREADY on the list. Fields: type \
"prioritize", target (item number), level ("high", "normal", or "low"), \
confidence. Use it when the user re-ranks an existing item: "make the prez deck \
urgent", "the audit can wait", "bump the audit to the top". Match the number \
exactly; never repurpose a different item because the words look similar.
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
-> done; set when if a day is named), "tag" (what is in a project/list; "what's \
left for the wedding" -> kind tag, tag "wedding"), "waiting" (what is parked on \
other people; "what am i waiting on").
- bulk: act on MANY items at once with ONE action; never list them individually. \
Fields: type "bulk", op ("complete", "drop", or "reschedule"), scope, when (op \
reschedule only: a date intent for the destination), confidence. Use bulk when \
the user means many items ("everything", "today's stuff", "push everything to \
tomorrow"). Pick scope:
  - "all": every open item. Use for "everything", "my whole list", "delete it all".
  - "today": only items on deck today. Use for "everything today", "today's stuff".
  - "date": one specific named day. Use for "all of friday", "monday's tasks".
- snooze: put off an item's reminder ping without moving the task. Fields: type \
"snooze", target (item id), minutes ("snooze 20" -> 20, "snooze an hour" -> 60, \
bare "snooze"/"not now" -> 10), confidence. Use when the user reacts to a \
reminder with snooze/"not now"/"remind me again in N"; a new date or time for \
the task itself is a reschedule instead.
- undo: the user wants to reverse their last change ("scratch that", "undo \
that"). Fields: type "undo".
- chitchat: a social pleasantry with NO task and NO question - a greeting, \
thanks, or an acknowledgment ("thanks", "thanks bud", "ok cool", "good morning", \
"nice", "lol", "you're the best"). Fields: type "chitchat", reply (a short, warm \
acknowledgment, a few words at most, e.g. "anytime!", "you got it"). Do NOT use \
chitchat for a question or a request.
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

repeat: if the task recurs, set repeat to "daily", "weekdays", or "weekly:<day>" \
(e.g. "weekly:monday"). "take out the trash every monday" -> weekly:monday. A \
one-off date is NOT a repeat; leave repeat null and set when instead.

Choosing the action:
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
today" -> bulk complete (scope today). "did" is a completion, not a question.
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
        + (f" (due {i['due_date']})" if i.get("due_date") else "")
        + (" (waiting)" if i.get("waiting") else "")
        for n, i in enumerate(items, start=1)
    )


def _format_digest(items: list[dict]) -> str:
    if not items:
        return "  (none)"
    return "\n".join(
        f"  {n}. {i['id']}: {i['label']}" for n, i in enumerate(items, start=1)
    )


def _format_pending(pending: list[dict]) -> str:
    """Render the clarifications Hob is waiting on, or "" if none. The model is
    told to answer with the user's date words verbatim (the core resolves them),
    or to ignore the pending question if the message is a new instruction."""
    if not pending:
        return ""
    lines = []
    for p in pending:
        if p.get("kind") == "capture":
            lines.append(
                f'- you asked "{p["question"]}" for a new task "{p["task"]}". to '
                f'answer, emit a capture with task "{p["task"]}" and when set to '
                'the date intent for the user\'s reply (e.g. {"kind":"weekday",'
                '"day":"thu"} for thursday).'
            )
        else:
            lines.append(
                f'- you asked "{p["question"]}" about "{p["label"]}". to answer, '
                f"emit a reschedule with target {p['target']} and when set to the "
                'date intent for the user\'s reply (e.g. {"kind":"weekday",'
                '"day":"fri"} for friday).'
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
        lines = "\n".join(f"  {f['id']}: {f['label']}" for f in ctx.focus)
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


def build_prompt(ctx: InterpreterContext) -> str:
    return _PROMPT.format(
        today=ctx.today,
        weekday=date.fromisoformat(ctx.today).strftime("%A"),
        now=ctx.now,
        timezone=ctx.timezone,
        active=_format_active(ctx.active_items),
        digest=_format_digest(ctx.last_digest),
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
            Setting(key=key, raw=raw)
            if key and raw
            else Unknown(note="setting without key or value")
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
        )
    if kind == "bulk":
        op = _str(action.get("op"))
        if op not in ("complete", "drop", "reschedule"):
            return Unknown(note="bulk without a valid op")
        return Bulk(
            op=op,
            scope=_str(action.get("scope")) or "today",
            when=_when(action.get("when")),
            confidence=conf,
        )
    if kind == "snooze":
        target = _str(action.get("target"))
        if not target:
            return Unknown(note="snooze without target")
        return Snooze(target=target, minutes=_int(action.get("minutes")) or 10, confidence=conf)
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


def interpret(llm: Llm, ctx: InterpreterContext) -> list:
    prompt = build_prompt(ctx)
    try:
        payload = llm.complete_json(prompt, ACTION_SCHEMA)
    except Exception:
        return [Unknown(note=MODEL_UNREACHABLE)]
    return parse_actions(payload)
