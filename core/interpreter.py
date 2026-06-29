# SPDX-License-Identifier: MIT
"""Interpreter: the spine. Builds the model prompt, parses and validates JSON
into Actions, then hands them to deterministic reconciliation.

The model call is injected via core.ports.Llm; this module performs no I/O.

Filled in Phase 5 (capture only) and Phase 7 (full action set: complete, drop,
reschedule, query, unknown). The model proposes; the core decides.
"""
from __future__ import annotations

from datetime import date

from core.models import Capture, InterpreterContext, Unknown
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
                    "type": {"type": "string", "enum": ["capture", "unknown"]},
                    "task": {"type": ["string", "null"]},
                    "raw": {"type": ["string", "null"]},
                    "due": {"type": ["string", "null"]},
                    "time": {"type": ["string", "null"]},
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
- Open items on deck:
{active}

The user's message:
{message}

Return a JSON object of the form {{"actions": [ ... ]}}. Each action is one of:
- capture: a new task. Fields: type "capture", task (a short clean imperative \
label with no date or time words), raw (echo the user's words for this task, \
keeping any date and time words exactly), due (your best guess ISO date \
YYYY-MM-DD, or null), time (HH:MM 24h, or null), confidence (0 to 1).
- unknown: you cannot tell what they want. Fields: type "unknown", note (short).

Rules:
- One message may hold several tasks; emit one capture per task.
- Keep all date and time words inside raw exactly as written.
- When you fill due, a weekday name means its next future occurrence relative \
to today; this keeps your guess aligned with the resolver.
- If the message is not about tasks, return a single unknown action.
"""


def build_prompt(ctx: InterpreterContext) -> str:
    weekday = date.fromisoformat(ctx.today).strftime("%A")
    if ctx.active_items:
        active = "\n".join(
            f"  {i['id']}: {i['label']}"
            + (f" (due {i['due_date']})" if i.get("due_date") else "")
            for i in ctx.active_items
        )
    else:
        active = "  (none)"
    return _PROMPT.format(
        today=ctx.today,
        weekday=weekday,
        now=ctx.now,
        timezone=ctx.timezone,
        active=active,
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
            confidence=_float(action.get("confidence"), 1.0),
        )
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
