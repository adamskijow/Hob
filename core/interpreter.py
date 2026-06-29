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
    Capture,
    Complete,
    Drop,
    InterpreterContext,
    Query,
    Reschedule,
    Unknown,
)
from core.ports import Llm

_STR = {"type": ["string", "null"]}
_NUM = {"type": ["number", "null"]}


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
                        {"task": _STR, "raw": _STR, "time": _STR, "confidence": _NUM},
                        ["type", "raw"],
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
                        {"target": _STR, "raw": {"type": "string"}, "confidence": _NUM},
                        ["type", "target", "raw"],
                    ),
                    _variant(
                        "query",
                        {"kind": _STR, "date": _STR},
                        ["type", "kind"],
                    ),
                    _variant("unknown", {"note": _STR}, ["type"]),
                ]
            },
        }
    },
    "required": ["actions"],
}

_PROMPT = """\
You convert a personal assistant's inbound text message into a JSON list of \
actions. Be literal. A separate program resolves real dates, so never invent or \
calculate a date; just copy the user's date words verbatim.

Context:
- Today: {today} ({weekday})
- Now: {now}
- Timezone: {timezone}
- Open items on deck (id: label):
{active}
- This morning's digest, in order (for position references):
{digest}

The user's message:
{message}

Return a JSON object {{"actions": [ ... ]}}. Each action is one of:
- capture: a NEW task to remember. Fields: type "capture", task (clean \
imperative label with no date words), raw (echo the user's words for this task, \
keeping any date and time words), time (HH:MM or null), confidence (0 to 1).
- complete: mark an EXISTING item done. Fields: type "complete", target (item \
id), confidence.
- drop: cancel an EXISTING item that no longer applies. Fields: type "drop", \
target, reason (optional), confidence.
- reschedule: move an EXISTING item to a new date. Fields: type "reschedule", \
target (item id), raw (the new date words copied verbatim, e.g. "Friday", \
"next Monday", "July 10"), confidence.
- query: the user is asking a question, not instructing. Fields: type "query", \
kind ("today", "date", or "all"), date (ISO if one specific day is named, else \
null).
- unknown: you cannot tell what they want. Fields: type "unknown", note (short).

Choosing the action:
- A question (phrased as what/when/anything/how, or ending with "?") is a query, \
never an edit. "what's on for tomorrow?" -> query.
- Use complete, drop, or reschedule only when the user clearly states they \
finished, cancelled, or moved an existing item: "did the prez", "drop the pool \
call", "push the audit to Friday". The instruction word is what licenses the edit.
- A message that just names a task, with no such instruction, is a NEW task: use \
capture. "dentist next Friday" -> capture. "call the pool guy" -> capture, even \
if a similar item already exists.

Resolving references:
- To point at an existing item, set target to its id from the open items list.
- The user may name it by description ("the prez one") or by position ("the \
third one", matching this morning's digest order). Map either to the right id.
- If you are unsure which item is meant, lower the confidence; never guess an id.

Rules:
- One message may do several things; emit one action each, for example "did the \
prez, drop the pool call, push the audit to Friday".
- Keep all date and time words inside raw exactly as written.
- If the message is not about tasks at all, return a single unknown action.
"""


def _format_active(items: list[dict]) -> str:
    if not items:
        return "  (none)"
    return "\n".join(
        f"  {i['id']}: {i['label']}"
        + (f" (due {i['due_date']})" if i.get("due_date") else "")
        for i in items
    )


def _format_digest(items: list[dict]) -> str:
    if not items:
        return "  (none)"
    return "\n".join(
        f"  {n}. {i['id']}: {i['label']}" for n, i in enumerate(items, start=1)
    )


def build_prompt(ctx: InterpreterContext) -> str:
    return _PROMPT.format(
        today=ctx.today,
        weekday=date.fromisoformat(ctx.today).strftime("%A"),
        now=ctx.now,
        timezone=ctx.timezone,
        active=_format_active(ctx.active_items),
        digest=_format_digest(ctx.last_digest),
        message=ctx.message,
    )


def _str(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def _float(value: object, default: float) -> float:
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


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
            time=_str(action.get("time")),
            confidence=conf,
        )
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
                raw=_str(action.get("raw")) or "",
                confidence=conf,
            )
            if target
            else Unknown(note="reschedule without target")
        )
    if kind == "query":
        return Query(kind=_str(action.get("kind")) or "today", date=_str(action.get("date")))
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
        return [Unknown(note="model call failed")]
    return parse_actions(payload)
