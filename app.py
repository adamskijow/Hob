# SPDX-License-Identifier: MIT
"""Composition root: wire adapters into the core and run the daemon.

Every inbound message takes one path: interpret -> reconcile -> apply. Captures,
EOD reports, corrections, and queries all flow through it. MessageService and
DigestService are edge orchestrators, unit-testable with an in-memory store, a
fake clock, and a fake LLM; the daemon wiring lives in _run_daemon.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import sys
from dataclasses import asdict
from datetime import date, datetime, timedelta

from config import Config, ConfigError
from core import recurrence
from core.digest import marks, ordered_open, render_digest, select_digest_items
from core.interpreter import MODEL_UNREACHABLE, interpret
from core.models import (
    SOURCE_CAPTURE,
    STATUS_DONE,
    STATUS_DROPPED,
    STATUS_OPEN,
    ActionLogEntry,
    Digest,
    DigestItem,
    InterpreterContext,
    Item,
    Unknown,
)
from core.planner import Mutation, QueryIntent, SettingChange, reconcile
from core.ports import Clock, Llm, Store
from core.undo import plan_undo
from adapters.clock import SystemClock
from adapters.llm_ollama import OllamaLlm
from adapters.scheduler import DigestScheduler
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage, TelegramAdapter

log = logging.getLogger("hob.message")

HELP = (
    'send tasks in plain language: "call the vet at 3pm", "take out the trash '
    'every monday". correct the same way: "did the prez one", "push it to friday", '
    '"drop 2", or follow up with "make it 4pm" / "that\'s urgent". reply to a '
    'reminder with "done" or "snooze 20"; edit a message and i take the edit. '
    'ask: "what\'s on today", "what\'s overdue", "what did i finish this week". '
    '/today lists what is open; /undo (or "scratch that") reverts your last change.'
)

# meta key for the single user's chat id, learned from inbound messages.
CHAT_ID_KEY = "chat_id"
# meta key holding the JSON of clarifications awaiting an answer (see core.planner
# Pending). One inbound message replaces it: resolved -> cleared, still unclear ->
# re-set.
PENDING_KEY = "pending"
# meta key holding a destructive bulk (JSON {op, ids}) held back for a yes/no.
CONFIRM_KEY = "pending_confirm"
# meta key holding the user-set wake time (HH:MM), overriding the configured
# default at runtime so "send the digest at 8" takes effect without a restart.
WAKE_KEY = "wake_time"
# meta key for the user-set evening recap time; same contract as WAKE_KEY.
EOD_KEY = "eod_time"
# meta key holding the conversational focus: the items the last message touched
# (JSON {ts, items: [{id, label}]}), so a bare follow-up ("make it 4pm") can
# resolve. Stale focus is ignored after this many minutes.
FOCUS_KEY = "focus"
FOCUS_TTL_MINUTES = 15
# Reactions on a Hob message that maps to an item: these complete it, this drops
# it. Anything else (hearts on chit-chat) is appreciation, not an instruction.
REACT_COMPLETE = {"\U0001F44D", "\U0001F44C", "\U0001F4AF", "\U0001F3C6"}
REACT_DROP = {"\U0001F44E"}

_AFFIRMATIONS = {
    "yes", "y", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm",
    "do it", "go ahead", "yes please", "please do", "absolutely", "definitely",
}


def _is_affirmation(text: str) -> bool:
    return text in _AFFIRMATIONS or text.startswith("yes")


def _relative(due_iso: str, today: date) -> str:
    """A human 'in X' (or 'X ago') for a due date, so the reply always makes the
    timing plain: 'tomorrow', 'in 3 days', 'in 200 years'."""
    try:
        n = (date.fromisoformat(due_iso) - today).days
    except (TypeError, ValueError):
        return ""
    if n == 0:
        return "today"
    if n == 1:
        return "tomorrow"
    if n == -1:
        return "yesterday"
    past, n = n < 0, abs(n)
    if n < 14:
        val, unit = n, "day"
    elif n < 60:
        val, unit = round(n / 7), "week"
    elif n < 365:
        val, unit = round(n / 30), "month"
    else:
        val, unit = round(n / 365), "year"
    phrase = f"{val} {unit}{'s' if val != 1 else ''}"
    return f"{phrase} ago" if past else f"in {phrase}"


def _dump(item: Item) -> str:
    return json.dumps(item.to_dict())


class MessageService:
    """Runs every inbound message through the interpreter, reconciles the result,
    applies mutations, and produces a reply. The transport (Telegram) and the
    core stay on opposite sides of this seam.
    """

    def __init__(
        self, store: Store, clock: Clock, llm: Llm, timezone: str, wake_time: str = "07:00"
    ) -> None:
        self._store = store
        self._clock = clock
        self._llm = llm
        self._timezone = timezone
        self._wake_time = wake_time

    def _welcome(self) -> str:
        return (
            'hi, i am hob. text me small tasks through the day ("call the vet at '
            '3pm", "take out the trash every monday") and each morning at '
            f"{self._wake_time} i will send one organized digest. correct it in "
            'plain language ("did the vet one", "push it to friday"), ask me '
            'things ("what is on today", "what is overdue"), and i will keep it '
            "all right here. /help anytime."
        )

    def handle(self, msg: InboundMessage) -> str:
        # Learn where to send the unsolicited morning digest.
        self._store.set_meta(CHAT_ID_KEY, str(msg.chat_id))
        if msg.edited:
            return self._handle_edit(msg)
        text = msg.text.strip()
        low = text.lower()
        if low == "/start":
            return self._welcome()
        if low == "/help":
            return HELP
        if low == "/today":
            return self._today()
        if low == "/undo":
            return self._undo()
        message_id = str(msg.message_id)
        # A destructive bulk held back for confirmation: apply it on yes, drop it
        # on anything else (and let that message be handled normally).
        pending_confirm = self._store.get_meta(CONFIRM_KEY)
        if pending_confirm:
            self._store.set_meta(CONFIRM_KEY, "")
            if _is_affirmation(low):
                return self._apply_confirmed(json.loads(pending_confirm), message_id)
        # Idempotency backstop: if a crash redelivered this message after its
        # mutations were already applied, do not apply or reply again. Normal
        # restarts are covered by the persisted poll offset; this guards the
        # narrow window between applying and advancing it.
        if self._store.has_actions_for_message(message_id):
            return ""
        return self._interpret_and_apply(
            text, message_id, reply_to=msg.reply_to,
            forwarded_from=msg.forwarded_from,
        )

    def _replied_item(self, reply_to: int | None) -> dict | None:
        """The item a replied-to Hob message (e.g. a reminder) was about, so bare
        words in the reply ('done', 'snooze 20') anchor to it deterministically."""
        if reply_to is None:
            return None
        item_id = self._store.ref_for(reply_to)
        if item_id is None:
            return None
        item = self._store.get_item(item_id)
        if item is None or item.status != STATUS_OPEN:
            return None
        return {"id": item.id, "label": item.task}

    def _context(
        self,
        text: str,
        reply_to: int | None = None,
        forwarded_from: str | None = None,
    ) -> InterpreterContext:
        # Canonical order so the position numbers the model sees match what the
        # user sees in /today and the digest.
        ordered = ordered_open(self._store.open_items(), self._clock.today().isoformat())
        active = [
            {"id": i.id, "label": i.task, "due_date": i.due_date,
             "waiting": bool(i.waiting_since)}
            for i in ordered
        ]
        last = self._store.last_digest()
        last_items = (
            [{"id": d.id, "label": d.label} for d in last.items] if last else []
        )
        raw_pending = self._store.get_meta(PENDING_KEY)
        return InterpreterContext(
            message=text,
            today=self._clock.today().isoformat(),
            now=self._clock.now().isoformat(),
            timezone=self._timezone,
            active_items=active,
            last_digest=last_items,
            pending=json.loads(raw_pending) if raw_pending else [],
            focus=self._load_focus(),
            replied=self._replied_item(reply_to),
            forwarded_from=forwarded_from,
        )

    def _load_focus(self) -> list[dict]:
        """The items the last message touched, if recent enough to still be the
        conversational subject; otherwise nothing."""
        raw = self._store.get_meta(FOCUS_KEY)
        if not raw:
            return []
        data = json.loads(raw)
        try:
            ts = datetime.fromisoformat(data.get("ts", ""))
        except ValueError:
            return []
        age = self._clock.now() - ts
        if age > timedelta(minutes=FOCUS_TTL_MINUTES):
            return []
        return data.get("items", [])

    def _save_focus(self, applied: list[tuple[str, Item]]) -> None:
        """Remember what this message touched (drops excluded: a dropped item is
        gone, not the new subject). Empty applied leaves the prior focus alone so
        a question or chitchat does not wipe the anchor."""
        items = [
            {"id": it.id, "label": it.task}
            for kind, it in reversed(applied)  # most recent action first
            if kind != "drop"
        ][:3]
        if items:
            self._store.set_meta(
                FOCUS_KEY,
                json.dumps({"ts": self._clock.now().isoformat(), "items": items}),
            )

    def handle_reaction(self, message_id: int, emojis: list[str]) -> str:
        """A reaction on a Hob message that maps to an item: a thumbs-up family
        emoji completes it, a thumbs-down drops it. Reactions on anything else
        (hearts on chit-chat) are appreciation, not instructions: ignored."""
        item_id = self._store.ref_for(message_id)
        if item_id is None:
            return ""
        item = self._store.get_item(item_id)
        if item is None or item.status != STATUS_OPEN:
            return ""
        kind = None
        if any(e in REACT_COMPLETE for e in emojis):
            kind = "complete"
        elif any(e in REACT_DROP for e in emojis):
            kind = "drop"
        if kind is None:
            return ""
        # One reaction is one undoable batch; re-reacting the same message is
        # idempotent via the message guard.
        inbound = f"reaction:{message_id}"
        if self._store.has_actions_for_message(inbound):
            return ""
        applied = self._apply([Mutation(kind=kind, target=item_id)], inbound)
        return self._reply(applied, [], [])

    def _interpret_and_apply(
        self,
        text: str,
        message_id: str,
        reply_to: int | None = None,
        forwarded_from: str | None = None,
    ) -> str:
        ctx = self._context(text, reply_to, forwarded_from)
        actions = interpret(self._llm, ctx)
        # A model outage degrades to a single Unknown with this note. Don't treat
        # it as a confusing message: say so, change nothing, and leave any pending
        # clarification intact so a retry still resolves it.
        if (
            len(actions) == 1
            and isinstance(actions[0], Unknown)
            and actions[0].note == MODEL_UNREACHABLE
        ):
            log.warning("model unreachable; not applying message %s", message_id)
            return "i can't reach the model right now. give it a few seconds and resend."
        plan = reconcile(actions, ctx)
        if plan.undo:  # "scratch that" / "undo that"
            return self._undo()
        applied = self._apply(plan.mutations, message_id)
        self._save_focus(applied)
        answers = [self._answer_query(q) for q in plan.queries]
        answers += [self._apply_setting(s) for s in plan.settings]
        # Persist this turn's clarifications for the next message; "" clears any
        # that were just resolved or superseded.
        self._store.set_meta(
            PENDING_KEY,
            json.dumps([asdict(p) for p in plan.pending]) if plan.pending else "",
        )
        questions = list(plan.questions)
        if plan.confirm is not None:
            self._store.set_meta(
                CONFIRM_KEY,
                json.dumps([asdict(m) for m in plan.confirm.mutations]),
            )
            questions.append(plan.confirm.question)
        reply = self._reply(applied, questions, answers)
        # A bare pleasantry ("thanks bud") gets a warm reply, not a task nag.
        if plan.chitchat and reply == "ok":
            return plan.chitchat
        return reply

    def _apply_setting(self, s: SettingChange) -> str:
        if s.key == "wake_time":
            self._store.set_meta(WAKE_KEY, s.value)
            return f"ok, morning digest at {s.value} from now on."
        if s.key == "eod_time":
            self._store.set_meta(EOD_KEY, s.value)
            return f"ok, evening recap at {s.value} from now on."
        return "ok"

    def _apply_confirmed(self, data: list, message_id: str) -> str:
        """Apply the mutations that were held back, now that the user confirmed."""
        mutations = [Mutation(**d) for d in data]
        applied = self._apply(mutations, message_id)
        self._save_focus(applied)
        return self._reply(applied, [], [])

    def _apply(
        self, mutations: list[Mutation], message_id: str
    ) -> list[tuple[str, Item]]:
        if not mutations:
            return []
        # One inbound message is one batch; the actions undo together.
        batch_id = self._store.next_batch_id()
        ts = self._clock.now().isoformat()
        applied: list[tuple[str, Item]] = []
        entries: list[ActionLogEntry] = []
        for m in mutations:
            if m.kind == "capture":
                item = Item(
                    id=self._store.next_item_id(),
                    raw_text=m.raw,
                    task=m.task,
                    due_date=m.due_date,
                    due_time=m.due_time,
                    status=STATUS_OPEN,
                    source=SOURCE_CAPTURE,
                    created_at=ts,
                    updated_at=ts,
                    repeat=m.repeat,
                    priority=m.priority or "normal",
                    tag=m.tag,
                    note=m.note,
                    waiting_since=(
                        self._clock.today().isoformat() if m.waiting else None
                    ),
                )
                self._store.add_item(item)
                entries.append(
                    ActionLogEntry(
                        batch_id=batch_id,
                        ts=ts,
                        action_type="capture",
                        item_id=item.id,
                        before_json=None,
                        after_json=_dump(item),
                        inbound_message_id=message_id,
                    )
                )
                applied.append(("capture", item))
                continue
            item = self._store.get_item(m.target)
            if item is None:
                continue  # vanished between reconcile and apply; skip defensively
            before = _dump(item)
            if m.kind == "complete":
                if item.repeat:
                    # A recurring task advances to its next occurrence rather
                    # than closing, so it reappears on the following matching day.
                    base = self._clock.today()
                    if item.due_date:
                        base = max(base, date.fromisoformat(item.due_date))
                    nxt = recurrence.next_due(item.repeat, base, inclusive=False)
                    if nxt is not None:
                        item.due_date = nxt.isoformat()
                        item.reminded = False
                    else:
                        item.status = STATUS_DONE
                else:
                    item.status = STATUS_DONE
            elif m.kind == "drop":
                item.status = STATUS_DROPPED
            elif m.kind == "reschedule":
                if m.due_date is not None:
                    item.due_date = m.due_date
                if m.due_time is not None:
                    item.due_time = m.due_time
                    if item.due_date is None:
                        # A bare "make it 4pm" on an undated task means today.
                        item.due_date = self._clock.today().isoformat()
                item.reminded = False  # re-arm the reminder for the new time
            elif m.kind == "amend":
                item.task = m.task  # the model supplied the full new label
            elif m.kind == "prioritize":
                item.priority = m.priority or "normal"
            elif m.kind == "snooze":
                until = self._clock.now() + timedelta(minutes=m.minutes or 10)
                item.snooze_until = until.strftime("%Y-%m-%dT%H:%M")
                item.reminded = False  # re-arm so the ping fires again
            elif m.kind == "note":
                item.note = f"{item.note}; {m.note}" if item.note else m.note
            elif m.kind == "wait":
                item.waiting_since = self._clock.today().isoformat()
            elif m.kind == "resume":
                item.waiting_since = None
            item.updated_at = ts
            self._store.update_item(item)
            entries.append(
                ActionLogEntry(
                    batch_id=batch_id,
                    ts=ts,
                    action_type=m.kind,
                    item_id=item.id,
                    before_json=before,
                    after_json=_dump(item),
                    inbound_message_id=message_id,
                )
            )
            applied.append((m.kind, item))
        self._store.append_actions(entries)
        return applied

    def _undo(self) -> str:
        batch = self._store.last_batch()
        if not batch:
            return "nothing to undo"
        self._revert(batch)
        return f"undid {len(batch)} change(s)"

    def _revert(self, batch) -> None:
        for op in plan_undo(batch):
            if op.kind == "delete":
                self._store.delete_item(op.item_id)
            else:
                self._store.update_item(op.item)
        self._store.mark_batch_undone(batch[0].batch_id)

    def _handle_edit(self, msg: InboundMessage) -> str:
        """The user edited an earlier message (their natural typo fix): revert
        what the original produced, then interpret the corrected text fresh."""
        message_id = str(msg.message_id)
        batch = self._store.batch_for_message(message_id)
        if batch:
            self._revert(batch)
        out = self._interpret_and_apply(
            msg.text.strip(), message_id, reply_to=msg.reply_to
        )
        return ("took the edit. " + out) if out else "took the edit."

    def _answer_query(self, q: QueryIntent) -> str:
        today = self._clock.today().isoformat()
        if q.kind == "done":  # already-finished items (closed, so no positions)
            items = self._store.done_since(q.date or today)
            if not items:
                return "done: nothing yet"
            return "done:\n" + "\n".join(f'"{i.task}"' for i in items)
        open_items = self._store.open_items()
        ordered = ordered_open(open_items, today)
        pos = {i.id: n for n, i in enumerate(ordered, start=1)}
        if q.kind == "all":
            items, title = ordered, "all open:"
        elif q.kind == "overdue":
            items = [i for i in ordered if i.due_date and i.due_date < today]
            title = "overdue:"
        elif q.kind == "week":
            end = (self._clock.today() + timedelta(days=6)).isoformat()
            items = [i for i in ordered if i.due_date and today <= i.due_date <= end]
            title = "this week:"
        elif q.kind == "search":
            term = (q.term or "").lower()
            items = [i for i in ordered if term and term in i.task.lower()]
            title = f'matching "{q.term}":'
        elif q.kind == "tag":
            tag = (q.tag or "").lower()
            items = [i for i in ordered if i.tag and i.tag.lower() == tag]
            title = f'for "{q.tag}":'
        elif q.kind == "waiting":
            items = [i for i in ordered if i.waiting_since]
            if not items:
                return "waiting on: nothing"
            lines = []
            for i in items:
                days = (self._clock.today() - date.fromisoformat(i.waiting_since)).days
                lines.append(f"{pos[i.id]}: {i.task} ({days}d)")
            return "waiting on:\n" + "\n".join(lines)
        elif q.kind == "date":
            items = [i for i in ordered if i.due_date == q.date]
            title = f"on {q.date}:"
        else:
            items = select_digest_items(open_items, today)
            title = "today:"
        if not items:
            return f"{title} nothing"
        return title + "\n" + "\n".join(
            f"{pos[i.id]}: {i.task}{marks(i)}" for i in items
        )

    def _reply(
        self, applied: list[tuple[str, Item]], questions: list[str], answers: list[str]
    ) -> str:
        parts: list[str] = []
        today = self._clock.today()
        captures = [it for kind, it in applied if kind == "capture"]

        def _when(due_date: str) -> str:
            rel = _relative(due_date, today)
            return f" for {due_date}" + (f" ({rel})" if rel else "")

        def _cap_line(it: Item) -> str:
            line = f'"{it.task}"'
            if it.repeat:
                line += f" ({recurrence.describe(it.repeat)})"
            elif it.due_date:
                line += _when(it.due_date)
            if it.due_time:
                line += f" at {it.due_time}"
            if it.priority == "high":
                line += " (urgent)"
            elif it.priority == "low":
                line += " (low priority)"
            if it.waiting_since:
                line += " (waiting)"
            if it.note:
                line += f" ({it.note})"
            return line

        # Always restate what was captured, with its timing, not a bare "got it".
        if len(captures) == 1:
            parts.append("got it: " + _cap_line(captures[0]))
        elif len(captures) > 1:
            parts.append("got it:")
            parts.extend(_cap_line(c) for c in captures)
        for kind, item in applied:
            if kind == "complete":
                if item.repeat:  # advanced, not closed: show its next occurrence
                    rel = _relative(item.due_date, today)
                    nxt = item.due_date + (f", {rel}" if rel else "")
                    parts.append(f'done: "{item.task}" (next {nxt})')
                else:
                    parts.append(f'done: "{item.task}"')
            elif kind == "drop":
                parts.append(f'dropped: "{item.task}"')
            elif kind == "reschedule":
                rel = _relative(item.due_date, today)
                line = f'moved "{item.task}" to {item.due_date}'
                if rel:
                    line += f" ({rel})"
                if item.due_time:
                    line += f" at {item.due_time}"
                parts.append(line)
            elif kind == "amend":
                parts.append(f'updated: "{item.task}"')
            elif kind == "prioritize":
                label = {"high": "urgent", "low": "low priority"}.get(
                    item.priority, "normal priority"
                )
                parts.append(f'marked "{item.task}" {label}')
            elif kind == "snooze":
                at = (item.snooze_until or "")[-5:]  # HH:MM tail of the ISO stamp
                parts.append(f'snoozed "{item.task}", will ping again at {at}')
            elif kind == "note":
                parts.append(f'noted on "{item.task}": {item.note}')
            elif kind == "wait":
                parts.append(
                    f'parked "{item.task}" as waiting. i\'ll check in on it.'
                )
            elif kind == "resume":
                parts.append(f'back on: "{item.task}"')
        parts.extend(questions)
        parts.extend(answers)
        return "\n".join(parts) if parts else "ok"

    def _today(self) -> str:
        ordered = ordered_open(self._store.open_items(), self._clock.today().isoformat())
        if not ordered:
            return "nothing on deck"
        return "\n".join(
            f"{n}: {i.task}{marks(i)}" for n, i in enumerate(ordered, start=1)
        )


# meta key holding the Telegram message id of the currently pinned digest.
PINNED_KEY = "pinned_digest_mid"


class DigestService:
    """Builds the morning digest, sends it, and records what was presented so
    later references resolve. send is an async callable(chat_id, text); pin is
    an optional async callable(chat_id, message_id, unpin_message_id) that pins
    today's digest and unpins yesterday's.
    """

    def __init__(self, store: Store, clock: Clock, send, pin=None) -> None:
        self._store = store
        self._clock = clock
        self._send = send
        self._pin = pin

    async def fire(self) -> bool:
        """Send today's digest. Returns True if it went out, False if it could
        not (no chat id yet). The scheduler uses this to decide whether to mark
        the day done, so a digest owed before the first message is not lost."""
        today = self._clock.today().isoformat()
        open_items = self._store.open_items()
        ordered = select_digest_items(open_items, today)
        waiting = [i for i in open_items if i.waiting_since]
        text = render_digest(ordered, today, waiting)
        digest = Digest(
            sent_at=self._clock.now().isoformat(),
            items=[DigestItem(id=i.id, label=i.task) for i in ordered],
        )
        chat = self._store.get_meta(CHAT_ID_KEY)
        if chat is None:
            logging.getLogger("hob.digest").info("no chat id yet; digest not sent")
            return False
        # Send first; only record the digest once it is actually delivered, so a
        # send failure retries cleanly without leaving orphan digest rows.
        sent_id = await self._send(int(chat), text)
        self._store.save_digest(digest)
        if self._pin is not None and isinstance(sent_id, int):
            old = self._store.get_meta(PINNED_KEY)
            await self._pin(int(chat), sent_id, int(old) if old else None)
            self._store.set_meta(PINNED_KEY, str(sent_id))
        return True


class EODService:
    """The evening close of the loop the morning digest opens: ask what got
    done. The user's free-text answer flows through the normal interpreter
    (completes / bulk complete), so this needs no machinery of its own."""

    def __init__(self, store: Store, clock: Clock, send) -> None:
        self._store = store
        self._clock = clock
        self._send = send

    async def fire(self) -> bool:
        chat = self._store.get_meta(CHAT_ID_KEY)
        if chat is None:
            return False
        today = self._clock.today().isoformat()
        on_deck = select_digest_items(self._store.open_items(), today)
        if not on_deck:
            return True  # nothing was on deck; nothing to recap, day is done
        lines = "\n".join(f"{n}: {i.task}" for n, i in enumerate(on_deck, start=1))
        await self._send(
            int(chat),
            "evening. what got done today? tell me and i'll check them off.\n"
            + lines,
        )
        return True


class ReminderService:
    """Pings the user a lead time before a timed item's due moment, so "call at
    3pm" is a heads-up (say, 2:50) rather than only a digest line and not only a
    ping at 3:00 sharp. send is async(chat_id, text)."""

    def __init__(self, store: Store, clock: Clock, send, lead_minutes: int = 0) -> None:
        self._store = store
        self._clock = clock
        self._send = send
        self._lead = timedelta(minutes=max(0, lead_minutes))

    async def check(self) -> None:
        chat = self._store.get_meta(CHAT_ID_KEY)
        if chat is None:
            return
        # Fire when now reaches (due - lead): compare due moments to now + lead.
        # A snoozed item instead fires at its snooze_until (compared to now).
        now = self._clock.now().strftime("%Y-%m-%dT%H:%M")
        threshold = (self._clock.now() + self._lead).strftime("%Y-%m-%dT%H:%M")
        for item in self._store.due_reminders(threshold, now):
            text = f'reminder: "{item.task}" at {item.due_time}'
            if item.snooze_until:
                text = f'reminder (snoozed): "{item.task}" at {item.due_time}'
            if item.note:
                text += f" ({item.note})"
            sent_id = await self._send(int(chat), text)
            self._store.mark_reminded(item.id)
            # Remember which item this ping was about, so a Telegram reply to it
            # ("done", "snooze 20") anchors to the item with no guessing.
            if isinstance(sent_id, int):
                self._store.record_sent_ref(sent_id, item.id)


# The bot's kettle avatar: set once (a version bump re-applies), tracked in meta.
AVATAR_KEY = "profile_photo"
AVATAR_VERSION = "kettle-1"
AVATAR_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets", "hob-avatar.jpg")


async def _set_profile_photo_once(telegram, store, path=AVATAR_PATH, version=AVATAR_VERSION) -> bool:
    """Give the bot its kettle avatar on startup, once. Idempotent via a meta
    flag; failures are non-fatal (retried on the next start)."""
    if store.get_meta(AVATAR_KEY) == version or not os.path.exists(path):
        return False
    if await telegram.set_profile_photo(path):
        store.set_meta(AVATAR_KEY, version)
        logging.getLogger("hob").info("set bot profile photo (%s)", version)
        return True
    return False


def _model_ready(llm: OllamaLlm, model: str) -> bool:
    return any(model == m or model in m for m in llm.installed_models())


async def _run_daemon(cfg: Config, store: SqliteStore) -> None:
    clock = SystemClock(cfg.timezone)
    llm = OllamaLlm(cfg.model, cfg.ollama_host, keep_alive=cfg.keep_alive)
    log = logging.getLogger("hob")
    try:
        if not _model_ready(llm, cfg.model):
            log.warning(
                "model %s is not pulled; messages will fail until you run: "
                "ollama pull %s", cfg.model, cfg.model
            )
    except Exception:
        log.warning(
            "ollama not reachable at %s; messages will fail until it is up "
            "(ollama serve, or Hearth)", cfg.ollama_host
        )
    service = MessageService(store, clock, llm, cfg.timezone, cfg.wake_time)
    telegram = TelegramAdapter(
        store, service.handle, token=cfg.telegram_token,
        reaction_handler=service.handle_reaction,
    )
    digest = DigestService(store, clock, telegram.send, pin=telegram.pin)
    reminder = ReminderService(store, clock, telegram.send, cfg.reminder_lead)
    eod = EODService(store, clock, telegram.send)
    scheduler = DigestScheduler(
        clock, store, digest.fire, cfg.wake_time, remind=reminder.check,
        eod_fire=eod.fire, eod_time=cfg.eod_time,
    )

    def stop_all() -> None:
        telegram.stop()
        scheduler.stop()

    await _set_profile_photo_once(telegram, store)

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, getattr(signal, "SIGTERM", None)):
        if sig is None:
            continue
        try:
            loop.add_signal_handler(sig, stop_all)
        except NotImplementedError:
            # Windows dev box: add_signal_handler is unsupported; rely on
            # KeyboardInterrupt instead. The macOS target uses the handler.
            pass

    await asyncio.gather(telegram.run(), scheduler.run())


def _doctor() -> int:
    """Preflight: check the environment a fresh install needs before first run."""
    print("hob doctor")
    try:
        cfg = Config.from_env()
        print(f"  OK   config: tz={cfg.timezone} wake={cfg.wake_time} db={cfg.db_path}")
    except ConfigError as exc:
        print(f"  FAIL config: {exc}")
        return 2

    ok = True
    if cfg.telegram_enabled:
        print("  OK   HOB_TELEGRAM_TOKEN is set")
    else:
        print("  WARN HOB_TELEGRAM_TOKEN not set: create a bot with @BotFather and "
              "set it (the bot will not run without it)")
        ok = False
    try:
        SqliteStore(cfg.db_path).close()
        print(f"  OK   database writable: {cfg.db_path}")
    except Exception as exc:  # noqa: BLE001
        print(f"  FAIL database not writable: {cfg.db_path}: {exc}")
        ok = False
    llm = OllamaLlm(cfg.model, cfg.ollama_host)
    try:
        if _model_ready(llm, cfg.model):
            print(f"  OK   ollama reachable; model present: {cfg.model}")
        else:
            print(f"  FAIL ollama is up but model {cfg.model} is not pulled. "
                  f"Run: ollama pull {cfg.model}")
            ok = False
    except Exception:  # noqa: BLE001
        print(f"  FAIL ollama not reachable at {cfg.ollama_host}. Start it "
              "(ollama serve, or Hearth).")
        ok = False
    print("all good" if ok else "problems found (see above)")
    return 0 if ok else 1


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s"
    )
    # python-telegram-bot's httpx logs every getUpdates at INFO with the bot
    # token in the URL. Quiet it so the token never lands in the log file.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    if argv and argv[0] == "doctor":
        return _doctor()
    try:
        cfg = Config.from_env()
    except ConfigError as exc:
        print(f"hob: config error: {exc}", file=sys.stderr)
        return 2

    log = logging.getLogger("hob")
    log.info(
        "starting: model=%s tz=%s wake=%s db=%s",
        cfg.model,
        cfg.timezone,
        cfg.wake_time,
        cfg.db_path,
    )

    store = SqliteStore(cfg.db_path)
    try:
        if not cfg.telegram_enabled:
            print(
                "hob: HOB_TELEGRAM_TOKEN not set, nothing to run. Create a bot "
                "with @BotFather, set HOB_TELEGRAM_TOKEN, and check setup with "
                "`python app.py doctor`. See README.",
                file=sys.stderr,
            )
            return 0
        try:
            asyncio.run(_run_daemon(cfg, store))
        except KeyboardInterrupt:
            log.info("interrupted, shutting down")
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
