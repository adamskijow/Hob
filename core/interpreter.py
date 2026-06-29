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

# Passed to Ollama as the structured-output format. A single flat item shape with
# a `type` discriminator is friendlier to small models than oneOf. The parser is
# the real validator; the schema just forces well-formed JSON.
ACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "actions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "enum": [
                            "capture",
                            "complete",
                            "drop",
                            "reschedule",
                            "query",
                            "unknown",
                        ],
                    },
                    "task": {"type": ["string", "null"]},
                    "raw": {"type": ["string", "null"]},
                    "due": {"type": ["string", "null"]},
                    "time": {"type": ["string", "null"]},
                    "target": {"type": ["string", "null"]},
                    "reason": {"type": ["string", "null"]},
                    "kind": {"type": ["string", "null"]},
                    "date": {"type": ["string", "null"]},
                    "confidence": {"type": ["number", "null"]},
                    "note": {"type": ["string", "null"]},
                },
                "required": ["type"],
            },
        }
    },
    "required": ["actions"],
}

_PROMPT = """\
You convert a personal assistant's inbound text message into a JSON list of \
actions. Be literal. A separate program resolves real dates, so never invent or \
calculate a date.

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
- capture: a new task. Fields: type "capture", task (clean imperative label with \
no date words), raw (echo the user's words for this task, keeping any date and \
time words), due (best guess ISO date YYYY-MM-DD or null), time (HH:MM or null), \
confidence (0 to 1).
- complete: mark an existing item done. Fields: type "complete", target (item \
id), confidence.
- drop: cancel an existing item that no longer applies. Fields: type "drop", \
target, reason (optional), confidence.
- reschedule: change an item's date. Fields: type "reschedule", target, raw \
(the user's date words, e.g. "to Friday"), due (best guess ISO or null), \
confidence.
- query: the user is asking, not instructing. Fields: type "query", kind \
("today", "date", or "all"), date (ISO if one specific day is named, else null).
- unknown: you cannot tell what they want. Fields: type "unknown", note (short).

Resolving references:
- To point at an existing item, set target to its id from the open items list.
- The user may name it by description ("the prez one") or by position ("the \
third one", matching this morning's digest order). Map either to the right id.
- If you are unsure which item is meant, lower the confidence; never guess an id.

Rules:
- One message may do several things; emit one action each, for example "did the \
prez, drop the pool call, push the audit to Friday".
- Keep all date and time words inside raw exactly as written.
- When you fill due, a weekday name means its next future occurrence relative \
to today.
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
            due=_str(action.get("due")),
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
                due=_str(action.get("due")),
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
