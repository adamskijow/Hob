# SPDX-License-Identifier: MIT
"""Composition root: wire adapters into the core and run the daemon.

Every inbound message takes one path: interpret -> reconcile -> apply. Captures,
EOD reports, corrections, and queries all flow through it. MessageService and
DigestService are edge orchestrators, unit-testable with an in-memory store, a
fake clock, and a fake LLM; the daemon wiring lives in _run_daemon.
"""
from __future__ import annotations

import asyncio
import getpass
import json
import logging
import os
import re
import signal
import sqlite3
import sys
from dataclasses import asdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from config import Config, ConfigError
from core import recurrence
from core.digest import (
    digest_nudge_item,
    marks,
    ordered_open,
    render_digest,
    select_digest_items,
)
from core.interpreter import MODEL_UNREACHABLE, interpret
from core.errors import RetryableMessageError
from core.feasibility import (
    CalendarSnapshot,
    build_day_plan,
    diff_day_plans,
    parse_plan_preferences,
)
from core.forecast import build_week_forecast
from core.local_time import wall_datetime, wall_time_status
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
    PlanRun,
    PlanSession,
    RecurrenceRule,
    Unknown,
)
from core.planner import Mutation, Pending, QueryIntent, SettingChange, reconcile
from core.ports import Calendar, Clock, Llm, Store
from core.undo import plan_undo
from core.version import __version__
from adapters.calendar_eventkit import EventKitCalendar
from adapters.clock import SystemClock
from adapters.data_files import (
    DatabaseBusyError,
    database_lease,
    import_export,
    restore_database,
)
from adapters.keychain import (
    KeychainError,
    delete_telegram_token,
    get_telegram_token,
    set_telegram_token,
)
from adapters.llm_ollama import OllamaLlm
from adapters.scheduler import DigestScheduler
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage, TelegramAdapter

log = logging.getLogger("hob.message")

# Second-pass chitchat reply: classification stays deterministic (temp 0); this
# runs hot so a repeated "thanks" does not get the same line every time.
CHITCHAT_SCHEMA = {
    "type": "object",
    "properties": {"reply": {"type": "string"}},
    "required": ["reply"],
}
CHITCHAT_PROMPT = (
    "You are Hob, a warm, upbeat personal task-assistant bot with a light "
    "sense of humor. The user sent a friendly, non-task message: \"{message}\". "
    "Reply in one short, casual sentence in your own voice. Do not mention their "
    "tasks or schedule, and do not ask a question back unless it is natural."
)

HELP = (
    'send tasks in plain language: "call the vet at 3pm", "take out the trash '
    'every monday". correct the same way: "did the prez one", "push it to friday", '
    '"drop 2", or follow up with "make it 4pm" / "that\'s urgent". reply to a '
    'reminder with "done" or "snooze 20"; edit a message and i take the edit. '
    'ask: "what\'s on today", "what\'s overdue", "what did i finish this week", '
    'or "am i overloaded this week?". '
    '/today shows today; /list shows every open item; /settings shows timing; '
    '/setup guides planning preferences; '
    '/undo (or "scratch that") reverts your last change. ask "plan my day" or '
    '"what should i do next?" for a short, reasoned plan. tell me deadlines, '
    'effort, fixed times, dependencies, preferred windows, and reminder offsets '
    'the same way: "the deck is due friday and takes 90 minutes". after the '
    'calendar bridge is connected, plans avoid calendar conflicts. say "plan '
    'work from 9 to 5", "plan work weekdays", or "protect lunch noon to 1" '
    'to set the daily frame. /outlook shows the read-only capacity result. '
    'say "use this plan" to adopt local sessions; /plan shows the active '
    'version. adoption never moves tasks or writes calendar events.'
)

# meta key for the single user's chat id, learned from inbound messages.
CHAT_ID_KEY = "chat_id"
# Telegram user id paired to this single-user Hob. Unlike a chat id, this is the
# authorization boundary; the first /start pairs when no configured owner exists.
OWNER_USER_KEY = "telegram_owner_user_id"
# meta key holding the JSON of clarifications awaiting an answer (see core.planner
# Pending). One inbound message replaces it: resolved -> cleared, still unclear ->
# re-set.
PENDING_KEY = "pending"
# meta key holding tokenized JSON {id, mutations} held back for a yes/no.
CONFIRM_KEY = "pending_confirm"
# meta key holding the user-set wake time (HH:MM), overriding the configured
# default at runtime so "send the digest at 8" takes effect without a restart.
WAKE_KEY = "wake_time"
# meta key for the user-set evening recap time; same contract as WAKE_KEY.
EOD_KEY = "eod_time"
WORK_HOURS_KEY = "work_hours"
WORK_DAYS_KEY = "work_days"
BREAKS_KEY = "breaks"
DEFAULT_DURATION_KEY = "default_duration"
TRANSITION_BUFFER_KEY = "transition_buffer"
ONBOARDING_STAGE_KEY = "onboarding_stage"
ONBOARDING_DONE_KEY = "onboarding_complete"
INSTALL_VERSION_KEY = "install_version"
RELEASE_NOTICE_KEY = "release_notice_version"
FIRST_PLAN_ADOPTED_KEY = "first_plan_adopted_at"
ONBOARDING_STEPS = (
    "work_hours",
    "work_days",
    "break_window",
    "default_duration",
    "transition_buffer",
)
DAY_CODES = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
# meta key holding the conversational focus: the items the last message touched
# (JSON {ts, items: [{id, label}]}), so a bare follow-up ("make it 4pm") can
# resolve. Stale focus is ignored after this many minutes.
FOCUS_KEY = "focus"
FOCUS_TTL_MINUTES = 15
LAST_PLAN_KEY = "last_day_plan"
# Reactions on a Hob message that maps to an item: these complete it, this drops
# it. Anything else (hearts on chit-chat) is appreciation, not an instruction.
REACT_COMPLETE = {"\U0001F44D", "\U0001F44C", "\U0001F4AF", "\U0001F3C6"}
REACT_DROP = {"\U0001F44E"}

_AFFIRMATIONS = {
    "yes", "y", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm",
    "do it", "go ahead", "yes please", "please do", "absolutely", "definitely",
}
_NEGATIONS = {
    "no", "n", "nope", "nah", "cancel", "never mind", "nevermind", "stop",
    "do not", "don't", "dont",
}

PLAN_SCHEMA = {
    "type": "object",
    "properties": {
        "headline": {"type": "string"},
        "picks": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"id": {"type": "string"}, "reason": {"type": "string"}},
                "required": ["id", "reason"],
            },
        },
    },
    "required": ["headline", "picks"],
}
PLAN_PROMPT = """\
You are Hob, a concise personal planning partner. A deterministic engine has
already produced a feasibility-checked timeline. Write one short headline and one
practical reason per scheduled item. Do not alter times, choose different work,
or invent tasks or ids. Calendar event names are intentionally unavailable.

Today: {today}
User constraint: {constraint}
Feasible timeline: {items}
"""

SEARCH_SCHEMA = {
    "type": "object",
    "properties": {
        "matches": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["matches"],
}
SEARCH_PROMPT = """\
Return the ids of open tasks semantically related to the user's memory or search
phrase. Match meaning, synonyms, notes, projects, and forwarded context, not just
exact words. Do not invent ids. Return an empty list when nothing is relevant.

Search phrase: {term}
Open tasks: {items}
"""

LOG_FORMAT = "%(asctime)s %(name)s %(levelname)s %(message)s"


class _RedactingFormatter(logging.Formatter):
    """Last-line defense against a transport exception rendering a bot token."""

    def __init__(self, secret: str) -> None:
        super().__init__(LOG_FORMAT)
        self._secret = secret

    def format(self, record: logging.LogRecord) -> str:
        rendered = super().format(record)
        return (
            rendered.replace(self._secret, "[REDACTED]")
            if self._secret
            else rendered
        )


def _redact_logging(secret: str) -> None:
    for handler in logging.getLogger().handlers:
        handler.setFormatter(_RedactingFormatter(secret))


def _is_affirmation(text: str) -> bool:
    return text in _AFFIRMATIONS or text.startswith("yes")


def _is_negation(text: str) -> bool:
    return text in _NEGATIONS or text.startswith("no ")


def _decode_confirm(raw: str) -> tuple[str | None, list]:
    """Read current tokenized confirmations and legacy list-only state."""
    data = json.loads(raw)
    if isinstance(data, dict):
        mutations = data.get("mutations")
        return str(data.get("id")) if data.get("id") else None, (
            mutations if isinstance(mutations, list) else []
        )
    return None, data if isinstance(data, list) else []


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
        self,
        store: Store,
        clock: Clock,
        llm: Llm,
        timezone: str,
        wake_time: str = "07:00",
        allowed_user_id: int | None = None,
        eod_time: str = "20:30",
        retry_model_outages: bool = False,
        calendar: Calendar | None = None,
        work_start: str = "09:00",
        work_end: str = "17:30",
        work_days: tuple[int, ...] = (0, 1, 2, 3, 4),
        breaks: tuple[tuple[str, str], ...] = (("12:00", "13:00"),),
        default_duration_minutes: int = 30,
        transition_buffer_minutes: int = 0,
    ) -> None:
        self._store = store
        self._clock = clock
        self._llm = llm
        self._timezone = timezone
        self._wake_time = wake_time
        self._allowed_user_id = allowed_user_id
        self._eod_time = eod_time
        self._retry_model_outages = retry_model_outages
        self._calendar = calendar
        self._work_start = work_start
        self._work_end = work_end
        self._work_days = work_days
        self._breaks = breaks
        self._default_duration_minutes = default_duration_minutes
        self._transition_buffer_minutes = transition_buffer_minutes

    def _welcome(self) -> str:
        return (
            'hi, i am hob. text me small tasks through the day ("call the vet at '
            '3pm", "take out the trash every monday") and each morning at '
            f"{self._wake_time} i will send one organized digest. correct it in "
            'plain language ("did the vet one", "push it to friday"), ask me '
            'things ("what is on today", "what is overdue"), and i will keep it '
            f"all right here. times use {self._timezone}. /setup tunes how i "
            "plan; /help shows the full shorthand."
        )

    def _calendar_status(self) -> str:
        if self._calendar is None:
            return "unavailable"
        status = getattr(self._calendar, "status", None)
        if status is None:
            return "available to planning"
        try:
            return status().status
        except Exception:
            return "unavailable"

    def _effective_work_days(self) -> tuple[int, ...]:
        """Preserve pre-v0.9 weekend behavior until an owner chooses days."""
        stored = self._store.get_meta(WORK_DAYS_KEY)
        if stored:
            try:
                parsed = tuple(
                    dict.fromkeys(DAY_CODES.index(day) for day in stored.split(","))
                )
            except ValueError:
                parsed = ()
            if parsed:
                return parsed
        if self._uses_legacy_work_days():
            return tuple(range(7))
        return self._work_days

    def _uses_legacy_work_days(self) -> bool:
        if self._store.get_meta(WORK_DAYS_KEY):
            return False
        if self._store.get_meta(ONBOARDING_DONE_KEY):
            return True
        return bool(self._store.get_meta(OWNER_USER_KEY)) and (
            self._store.get_meta(INSTALL_VERSION_KEY) != __version__
        )

    def _work_days_value(self) -> str:
        return ",".join(DAY_CODES[index] for index in self._effective_work_days())

    def _setup_value(self, key: str) -> str:
        if key == "work_hours":
            return self._store.get_meta(WORK_HOURS_KEY) or (
                f"{self._work_start}-{self._work_end}"
            )
        if key == "work_days":
            return self._work_days_value()
        if key == "break_window":
            value = self._store.get_meta(BREAKS_KEY)
            if value:
                return value
            return ",".join(f"{start}-{end}" for start, end in self._breaks) or "none"
        if key == "default_duration":
            return self._store.get_meta(DEFAULT_DURATION_KEY) or str(
                self._default_duration_minutes
            )
        return self._store.get_meta(TRANSITION_BUFFER_KEY) or str(
            self._transition_buffer_minutes
        )

    def _setup_prompt(self, stage: str) -> str:
        prompts = {
            "work_hours": (
                'setup 1/5: what hours may i plan inside? reply like "plan work '
                'from 9 to 5", or say "skip" to keep {current}.'
            ),
            "work_days": (
                'setup 2/5: which days may i plan work? reply like "weekdays", '
                '"monday through saturday", or "every day"; "skip" keeps '
                "{current}."
            ),
            "break_window": (
                'setup 3/5: what daily time should stay protected? reply like '
                '"protect lunch from noon to 1", "no break", or "skip" to keep '
                "{current}."
            ),
            "default_duration": (
                'setup 4/5: when a task has no estimate, what should i assume? '
                'reply like "assume 30 minutes", or say "skip" to keep {current}m.'
            ),
            "transition_buffer": (
                'setup 5/5: how much breathing room should i leave between '
                'commitments? reply like "leave 10 minutes between things", '
                '"no buffer", or "skip" to keep {current}m.'
            ),
        }
        question = prompts[stage].format(current=self._setup_value(stage))
        self._store.set_meta(
            PENDING_KEY,
            json.dumps(
                [
                    asdict(
                        Pending(
                            kind="setting",
                            question=question,
                            key=stage,
                        )
                    )
                ]
            ),
        )
        return question

    def _begin_onboarding(self, include_welcome: bool = False) -> str:
        stage = self._store.get_meta(ONBOARDING_STAGE_KEY)
        if stage not in ONBOARDING_STEPS:
            stage = ONBOARDING_STEPS[0]
            self._store.set_meta(ONBOARDING_STAGE_KEY, stage)
        prompt = self._setup_prompt(stage)
        intro = self._welcome() + "\n\n" if include_welcome else ""
        timezone_note = (
            f"times use {self._timezone}. if that is wrong, pause setup and "
            "set HOB_TIMEZONE before continuing.\n"
        )
        return (
            intro
            + timezone_note
            + prompt
            + '\nYou can also say "cancel setup" at any step.'
        )

    def _finish_onboarding(self) -> str:
        self._store.set_meta(ONBOARDING_STAGE_KEY, "")
        self._store.set_meta(ONBOARDING_DONE_KEY, self._clock.now().isoformat())
        self._store.set_meta(PENDING_KEY, "")
        calendar = self._calendar_status()
        calendar_line = (
            "calendar is connected."
            if calendar == "authorized"
            else "calendar is not connected; plans still use your hours. on the Mac, run `uv run python app.py calendar authorize` whenever you want live busy-time checks."
        )
        return (
            "setup complete. your planning assumptions are visible in /settings "
            "and each change is undoable. "
            + calendar_line
            + ' send me one real task, then ask "plan my day".'
        )

    def _advance_onboarding(self, settings: list[SettingChange]) -> str | None:
        stage = self._store.get_meta(ONBOARDING_STAGE_KEY)
        if stage not in ONBOARDING_STEPS or not any(s.key == stage for s in settings):
            return None
        index = ONBOARDING_STEPS.index(stage) + 1
        if index >= len(ONBOARDING_STEPS):
            return self._finish_onboarding()
        next_stage = ONBOARDING_STEPS[index]
        self._store.set_meta(ONBOARDING_STAGE_KEY, next_stage)
        return self._setup_prompt(next_stage)

    def _skip_onboarding(self) -> str:
        stage = self._store.get_meta(ONBOARDING_STAGE_KEY)
        if stage not in ONBOARDING_STEPS:
            return self._begin_onboarding()
        if stage == "work_days" and not self._store.get_meta(WORK_DAYS_KEY):
            # Record the displayed value so a fresh skip cannot later be
            # mistaken for an upgraded profile that predates this setting.
            self._store.set_meta(WORK_DAYS_KEY, self._work_days_value())
        index = ONBOARDING_STEPS.index(stage) + 1
        if index >= len(ONBOARDING_STEPS):
            return self._finish_onboarding()
        next_stage = ONBOARDING_STEPS[index]
        self._store.set_meta(ONBOARDING_STAGE_KEY, next_stage)
        return "kept the current value.\n" + self._setup_prompt(next_stage)

    def _cancel_onboarding(self) -> str:
        self._store.set_meta(PENDING_KEY, "")
        return (
            "setup paused. your saved values and current step are unchanged; "
            "/setup resumes anytime."
        )

    def _authorize(self, msg: InboundMessage, low: str) -> tuple[bool, str | None]:
        """Pair one Telegram user and reject every other sender before state access."""
        if msg.chat_type is not None and msg.chat_type != "private":
            return False, "hob only works in a private chat with its owner."
        if msg.user_id is None:
            return True, None  # non-Telegram tests/adapters without identity
        configured = self._allowed_user_id
        owner_raw = self._store.get_meta(OWNER_USER_KEY)
        owner = int(owner_raw) if owner_raw else None
        expected = configured or owner
        if expected is not None:
            if msg.user_id != expected:
                log.warning("rejected Telegram user %s", msg.user_id)
                return False, "this hob is already paired to its owner."
            if configured is not None and owner != configured:
                self._store.set_meta(OWNER_USER_KEY, str(configured))
            elif owner is None:
                self._store.set_meta(OWNER_USER_KEY, str(msg.user_id))
            return True, None
        if low != "/start":
            return False, "send /start to pair this hob before adding tasks."
        self._store.set_meta(OWNER_USER_KEY, str(msg.user_id))
        return True, None

    @staticmethod
    def _message_key(msg: InboundMessage) -> str:
        return f"{msg.chat_id}:{msg.message_id}"

    def handle(self, msg: InboundMessage) -> str:
        """Apply one user turn atomically, including settings and conversation state."""
        with self._store.transaction():
            return self._handle(msg)

    def _handle(self, msg: InboundMessage) -> str:
        text = msg.text.strip()
        low = text.lower()
        was_paired = bool(self._store.get_meta(OWNER_USER_KEY))
        authorized, denial = self._authorize(msg, low)
        if not authorized:
            return denial or ""
        # Learn where to send proactive messages only after owner authorization.
        self._store.set_meta(CHAT_ID_KEY, str(msg.chat_id))
        self._store.expire_plans(
            self._clock.today().isoformat(), self._clock.now().isoformat()
        )
        if msg.edited:
            return self._handle_edit(msg)
        if low == "/start":
            if self._store.get_meta(ONBOARDING_STAGE_KEY) in ONBOARDING_STEPS:
                return self._begin_onboarding(include_welcome=True)
            fresh = (
                not was_paired
                and not self._store.get_meta(ONBOARDING_DONE_KEY)
                and not self._store.open_items()
            )
            if fresh:
                self._store.set_meta(INSTALL_VERSION_KEY, __version__)
                self._store.set_meta(RELEASE_NOTICE_KEY, __version__)
                return self._begin_onboarding(include_welcome=True)
            return self._welcome()
        if low in ("/setup", "/onboarding"):
            return self._begin_onboarding()
        if low in {"cancel setup", "stop setup", "/cancelsetup"}:
            return self._cancel_onboarding()
        if (
            self._store.get_meta(ONBOARDING_STAGE_KEY) in ONBOARDING_STEPS
            and low in {"skip", "keep", "keep it", "next"}
        ):
            return self._skip_onboarding()
        if low == "/help":
            return HELP
        if low == "/today":
            return self._today()
        if low in ("/list", "/all"):
            return self._list()
        if low == "/settings":
            return self._settings()
        if low in {"/plan", "/next"}:
            return self._answer_plan_status()
        if low in {"/outlook", "/capacity"}:
            return self._answer_outlook("what will fit this week?")
        if low == "/undo":
            return self._undo()
        # A destructive bulk held back for confirmation: apply it on yes, drop it
        # on anything else (and let that message be handled normally).
        pending_confirm = self._store.get_meta(CONFIRM_KEY)
        if pending_confirm:
            self._store.set_meta(CONFIRM_KEY, "")
            if _is_affirmation(low):
                _, mutations = _decode_confirm(pending_confirm)
                return self._apply_confirmed(
                    mutations, self._message_key(msg)
                )
            if _is_negation(low):
                return "canceled. nothing changed."
        # Idempotency backstop: if a crash redelivered this message after its
        # mutations were already applied, do not apply or reply again. Normal
        # restarts are covered by the persisted poll offset; this guards the
        # narrow window between applying and advancing it.
        message_key = self._message_key(msg)
        if self._store.has_actions_for_message(message_key):
            return ""
        replied = self._replied_item(msg.reply_to)
        if replied and low in {"keep", "keep it", "still on", "yes keep it"}:
            applied = self._apply(
                [Mutation(kind="keep", target=replied["id"])], message_key
            )
            self._save_focus(applied)
            return self._reply(applied, [], [])
        return self._interpret_and_apply(
            text, message_key, reply_to=msg.reply_to,
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
             "deadline_date": i.deadline_date,
             "duration_minutes": i.duration_minutes,
             "schedule_kind": i.schedule_kind,
             "depends_on": i.depends_on,
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
            return self._active_plan_focus()
        try:
            data = json.loads(raw)
        except (TypeError, json.JSONDecodeError):
            return self._active_plan_focus()
        try:
            ts = datetime.fromisoformat(data.get("ts", ""))
        except ValueError:
            return self._active_plan_focus()
        age = self._clock.now() - ts
        if age > timedelta(minutes=FOCUS_TTL_MINUTES):
            return self._active_plan_focus()
        return data.get("items", [])

    def _active_plan_focus(self) -> list[dict]:
        run = self._store.active_plan(self._clock.today().isoformat())
        if run is None:
            return []
        focused = []
        seen: set[str] = set()
        for session in self._store.plan_sessions(run.id):
            if session.status not in {"planned", "started"}:
                continue
            item = self._store.get_item(session.item_id)
            if item is None or item.status != STATUS_OPEN or item.id in seen:
                continue
            seen.add(item.id)
            focused.append(
                {"id": item.id, "label": item.task, "context": "plan"}
            )
        return focused[:10]

    def _save_focus(self, applied: list[tuple[str, Item]]) -> None:
        """Remember what this message touched (drops excluded: a dropped item is
        gone, not the new subject). Empty applied leaves the prior focus alone so
        a question or chitchat does not wipe the anchor."""
        items = [
            it
            for kind, it in reversed(applied)  # most recent action first
            if kind != "drop"
        ][:3]
        self._save_focus_items(items, context="mutation", limit=3)

    def _save_focus_items(
        self, items: list[Item], *, context: str, limit: int
    ) -> None:
        focused = []
        seen: set[str] = set()
        for item in items:
            if item.id in seen:
                continue
            seen.add(item.id)
            focused.append(
                {"id": item.id, "label": item.task, "context": context}
            )
            if len(focused) >= limit:
                break
        if focused:
            self._store.set_meta(
                FOCUS_KEY,
                json.dumps(
                    {"ts": self._clock.now().isoformat(), "items": focused}
                ),
            )
        elif context == "plan":
            self._store.set_meta(FOCUS_KEY, "")

    def handle_reaction(
        self, message_id: int, emojis: list[str], user_id: int | None = None
    ) -> str:
        with self._store.transaction():
            return self._handle_reaction(message_id, emojis, user_id)

    def _handle_reaction(
        self, message_id: int, emojis: list[str], user_id: int | None = None
    ) -> str:
        """A reaction on a Hob message that maps to an item: a thumbs-up family
        emoji completes it, a thumbs-down drops it. Reactions on anything else
        (hearts on chit-chat) are appreciation, not instructions: ignored."""
        if user_id is not None:
            owner = self._allowed_user_id or int(
                self._store.get_meta(OWNER_USER_KEY) or "0"
            )
            if owner and user_id != owner:
                log.warning("rejected reaction from Telegram user %s", user_id)
                return ""
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

    def handle_callback(
        self,
        callback_id: str,
        data: str,
        user_id: int | None,
        chat_id: int | None,
    ) -> str:
        with self._store.transaction():
            return self._handle_callback(callback_id, data, user_id, chat_id)

    def _handle_callback(
        self,
        callback_id: str,
        data: str,
        user_id: int | None,
        chat_id: int | None,
    ) -> str:
        """Apply only whitelisted inline-button actions; never interpret callback text."""
        owner = self._allowed_user_id or int(
            self._store.get_meta(OWNER_USER_KEY) or "0"
        )
        if owner and user_id is not None and user_id != owner:
            log.warning("rejected callback from Telegram user %s", user_id)
            return ""
        inbound = f"callback:{callback_id}"
        if self._store.has_actions_for_message(inbound):
            return ""
        if data.startswith("hob:confirm:"):
            parts = data.split(":", 3)
            choice = parts[2] if len(parts) >= 3 else ""
            clicked_token = parts[3] if len(parts) == 4 else None
            pending = self._store.get_meta(CONFIRM_KEY)
            if not pending:
                return "that confirmation has expired."
            current_token, mutations = _decode_confirm(pending)
            if clicked_token and current_token and clicked_token != current_token:
                return "that confirmation has expired."
            self._store.set_meta(CONFIRM_KEY, "")
            if choice == "no":
                return "canceled. nothing changed."
            if choice == "yes":
                return self._apply_confirmed(mutations, inbound)
            return ""
        parts = data.split(":")
        if len(parts) != 4 or parts[:2] != ["hob", "item"]:
            return ""
        _, _, item_id, action = parts
        item = self._store.get_item(item_id)
        if item is None or item.status != STATUS_OPEN:
            return "that task is no longer open."
        mutation = {
            "complete": Mutation(kind="complete", target=item_id),
            "snooze": Mutation(kind="snooze", target=item_id, minutes=10),
            "drop": Mutation(kind="drop", target=item_id),
        }.get(action)
        if mutation is None:
            return ""
        if chat_id is not None:
            self._store.set_meta(CHAT_ID_KEY, str(chat_id))
        applied = self._apply([mutation], inbound)
        self._save_focus(applied)
        return self._reply(applied, [], [])

    def _interpret_and_apply(
        self,
        text: str,
        message_id: str,
        reply_to: int | None = None,
        forwarded_from: str | None = None,
        restore_on_outage: list[ActionLogEntry] | None = None,
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
            if restore_on_outage:
                self._restore_batch(restore_on_outage)
            if self._retry_model_outages:
                raise RetryableMessageError("local model unavailable")
            return "i can't reach the model right now. give it a few seconds and resend."
        plan = reconcile(actions, ctx)
        if plan.undo:  # "scratch that" / "undo that"
            return self._undo()
        batch_id = (
            self._store.next_batch_id()
            if plan.mutations or plan.settings or plan.plan_action
            else None
        )
        applied = self._apply(plan.mutations, message_id, batch_id=batch_id)
        self._save_focus(applied)
        answers = [self._answer_start(item_id) for item_id in plan.starts]
        answers += [self._answer_query(q) for q in plan.queries]
        setting_answers = [
            self._apply_setting(s, message_id, batch_id) for s in plan.settings
        ]
        answers += setting_answers
        if plan.plan_action:
            answers.append(
                self._apply_plan_action(plan.plan_action, message_id, batch_id)
            )
        # Persist this turn's clarifications for the next message; "" clears any
        # that were just resolved or superseded.
        self._store.set_meta(
            PENDING_KEY,
            json.dumps([asdict(p) for p in plan.pending]) if plan.pending else "",
        )
        onboarding_reply = self._advance_onboarding(plan.settings)
        if onboarding_reply:
            answers.append(onboarding_reply)
        questions = list(plan.questions)
        if plan.confirm is not None:
            self._store.set_meta(
                CONFIRM_KEY,
                json.dumps(
                    {
                        "id": message_id,
                        "mutations": [asdict(m) for m in plan.confirm.mutations],
                    }
                ),
            )
            questions.append(plan.confirm.question)
        reply = self._reply(applied, questions, answers)
        # A pleasantry gets a warm reply, not a task nag. A second, higher-temp
        # call writes it so the same message ("thanks") varies between turns;
        # classification stayed at temp 0. Falls back to the classified reply.
        if plan.chitchat and reply == "ok":
            return self._varied_reply(text) or plan.chitchat
        return reply

    def _varied_reply(self, message: str) -> str | None:
        """One short, warm reply, generated fresh at high temperature so chitchat
        does not repeat itself. None on any failure so the caller falls back."""
        try:
            out = self._llm.complete_json(
                CHITCHAT_PROMPT.format(message=message), CHITCHAT_SCHEMA, temperature=0.9
            )
        except Exception:
            return None
        reply = out.get("reply") if isinstance(out, dict) else None
        return reply.strip() if isinstance(reply, str) and reply.strip() else None

    def _apply_setting(
        self, s: SettingChange, message_id: str, batch_id: str | None
    ) -> str:
        key = {
            "wake_time": WAKE_KEY,
            "eod_time": EOD_KEY,
            "work_hours": WORK_HOURS_KEY,
            "work_days": WORK_DAYS_KEY,
            "break_window": BREAKS_KEY,
            "default_duration": DEFAULT_DURATION_KEY,
            "transition_buffer": TRANSITION_BUFFER_KEY,
        }.get(s.key, s.key)
        before = self._store.get_meta(key)
        self._store.set_meta(key, s.value)
        self._store.append_actions(
            [
                ActionLogEntry(
                    batch_id=batch_id or self._store.next_batch_id(),
                    ts=self._clock.now().isoformat(),
                    action_type="setting",
                    item_id=f"setting:{key}",
                    before_json=json.dumps(before),
                    after_json=json.dumps(s.value),
                    inbound_message_id=message_id,
                )
            ]
        )
        if s.key == "wake_time":
            return f"ok, morning digest at {s.value} from now on."
        if s.key == "eod_time":
            return f"ok, evening recap at {s.value} from now on."
        if s.key == "work_hours":
            return f"ok, i will plan inside {s.value} from now on."
        if s.key == "work_days":
            return f"ok, i will plan flexible work on {s.value} from now on."
        if s.key == "break_window":
            return (
                f"ok, i will protect {s.value} from planning."
                if s.value != "none"
                else "ok, daily protected break removed."
            )
        if s.key == "default_duration":
            return f"ok, i will estimate unstated tasks at {s.value} minutes."
        if s.key == "transition_buffer":
            return f"ok, i will leave {s.value} minutes between commitments."
        return "ok"

    def _apply_plan_action(
        self, op: str, message_id: str, batch_id: str | None
    ) -> str:
        """Change local execution state only after an explicit user action."""
        now = self._clock.now().isoformat()
        if op == "cancel":
            run = self._store.active_plan(self._clock.today().isoformat())
            run = run or self._store.active_plan()
            if run is None:
                return "there is no adopted plan to cancel. tasks and calendar are unchanged."
            before, after = self._store.cancel_plan(run.id, now)
            reply = (
                f"canceled the adopted plan for {run.day}. "
                "tasks and calendar are unchanged."
            )
        else:
            run = self._store.latest_proposed_plan()
            if run is None:
                return 'there is no current proposal to adopt; ask "plan my day" first.'
            sessions = self._store.plan_sessions(run.id)
            if not sessions:
                return (
                    f"the {run.day} proposal has no sessions to adopt. "
                    "tasks and calendar are unchanged."
                )
            active = self._store.active_plan(run.day)
            if active is not None and op != "replace":
                return (
                    f"you already have an adopted plan for {run.day}. "
                    'say "replace my plan with this" to switch explicitly.'
                )
            before, after = self._store.adopt_plan(run.id, now)
            sessions = self._store.plan_sessions(run.id)
            planned = [session for session in sessions if session.status == "planned"]
            if not planned:
                self._store.restore_plan_state(before)
                return (
                    f"nothing in the {run.day} proposal is still open to adopt. "
                    "ask me to replan."
                )
            tasks = len({session.item_id for session in planned})
            verb = "replaced" if active is not None else "adopted"
            reply = (
                f"{verb} the {run.day} plan: {len(planned)} session(s) across "
                f"{tasks} task(s). tasks and calendar are unchanged; ask "
                '"what is on my plan" anytime.'
            )
            skipped = len(sessions) - len(planned)
            if skipped:
                reply += f" {skipped} stale session(s) were left out."
            items = [
                item
                for session in planned
                for item in [self._store.get_item(session.item_id)]
                if item is not None and item.status == STATUS_OPEN
            ]
            self._save_focus_items(items, context="plan", limit=10)
            first_adoption = not self._store.get_meta(FIRST_PLAN_ADOPTED_KEY)
            if first_adoption:
                reply += (
                    ' first-run tip: if the day changes, say "replan"; the new '
                    'version stays a proposal until you say "replace my plan '
                    'with this".'
                )
                self._store.set_meta(FIRST_PLAN_ADOPTED_KEY, now)
        self._store.append_actions(
            [
                ActionLogEntry(
                    batch_id=batch_id or self._store.next_batch_id(),
                    ts=now,
                    action_type="plan",
                    item_id=f"plan:{run.id}",
                    before_json=json.dumps(before),
                    after_json=json.dumps(after),
                    inbound_message_id=message_id,
                )
            ]
        )
        return reply

    def _apply_confirmed(self, data: list, message_id: str) -> str:
        """Apply the mutations that were held back, now that the user confirmed."""
        mutations = [Mutation(**d) for d in data]
        applied = self._apply(mutations, message_id)
        self._save_focus(applied)
        return self._reply(applied, [], [])

    def _dependency_cycle(self, item_id: str, dependencies: list[str]) -> bool:
        """Reject direct and transitive dependency loops before persistence."""
        stack = list(dependencies)
        seen: set[str] = set()
        while stack:
            current = stack.pop()
            if current == item_id:
                return True
            if current in seen:
                continue
            seen.add(current)
            dependency = self._store.get_item(current)
            if dependency is not None:
                stack.extend(dependency.depends_on)
        return False

    def _apply(
        self,
        mutations: list[Mutation],
        message_id: str,
        *,
        batch_id: str | None = None,
    ) -> list[tuple[str, Item]]:
        if not mutations:
            return []
        # One inbound message is one batch; the actions undo together.
        batch_id = batch_id or self._store.next_batch_id()
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
                    deadline_date=m.deadline_date,
                    duration_minutes=m.duration_minutes,
                    duration_confidence=m.duration_confidence,
                    schedule_kind=m.schedule_kind or "flexible",
                    splittable=bool(m.splittable),
                    earliest_start=m.earliest_start,
                    preferred_window=m.preferred_window,
                    parent_id=m.parent_id,
                    depends_on=list(m.depends_on or []),
                    reminder_offsets=list(m.reminder_offsets or []),
                    recurrence=(
                        RecurrenceRule(**m.recurrence) if m.recurrence else None
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
                rule = item.recurrence or recurrence.parse(item.repeat)
                if rule:
                    # A recurring task advances to its next occurrence rather
                    # than closing, so it reappears on the following matching day.
                    rule = recurrence.completed(rule)
                    if rule.anchor == "completion":
                        base = self._clock.today()
                    else:
                        base = self._clock.today()
                        if item.due_date:
                            base = max(base, date.fromisoformat(item.due_date))
                    nxt = recurrence.next_due(rule, base, inclusive=False)
                    if nxt is not None:
                        item.due_date = nxt.isoformat()
                        item.reminded = False
                        item.reminded_offsets = []
                        item.recurrence = rule
                        item.repeat = recurrence.to_legacy(rule)
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
                item.reminded_offsets = []
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
            elif m.kind == "keep":
                pass  # updated_at below records an explicit keep/review decision
            elif m.kind == "schedule":
                for field_name in m.clear:
                    if field_name == "deadline":
                        item.deadline_date = None
                    elif field_name == "duration":
                        item.duration_minutes = None
                        item.duration_confidence = None
                    elif field_name == "earliest":
                        item.earliest_start = None
                    elif field_name == "window":
                        item.preferred_window = None
                    elif field_name == "dependencies":
                        item.depends_on = []
                    elif field_name == "reminders":
                        item.reminder_offsets = []
                        item.reminded_offsets = []
                if m.deadline_date is not None:
                    item.deadline_date = m.deadline_date
                if m.duration_minutes is not None:
                    item.duration_minutes = m.duration_minutes
                    item.duration_confidence = m.duration_confidence
                if m.schedule_kind is not None:
                    item.schedule_kind = m.schedule_kind
                if m.splittable is not None:
                    item.splittable = m.splittable
                if m.earliest_start is not None:
                    item.earliest_start = m.earliest_start
                if m.preferred_window is not None:
                    item.preferred_window = m.preferred_window
                if m.depends_on is not None:
                    if self._dependency_cycle(item.id, m.depends_on):
                        applied.append(("constraint_error", item))
                        continue
                    item.depends_on = list(m.depends_on)
                if m.reminder_offsets is not None:
                    item.reminder_offsets = list(m.reminder_offsets)
                    item.reminded_offsets = []
                    item.reminded = False
                if (
                    item.deadline_date
                    and item.due_date
                    and item.due_date > item.deadline_date
                ):
                    applied.append(("constraint_error", item))
                    continue
                if (
                    item.deadline_date
                    and item.earliest_start
                    and item.earliest_start[:10] > item.deadline_date
                ):
                    applied.append(("constraint_error", item))
                    continue
            elif m.kind == "recur":
                rule = item.recurrence or recurrence.parse(item.repeat)
                if m.recur_op == "stop":
                    item.recurrence = None
                    item.repeat = None
                elif rule is None:
                    applied.append(("constraint_error", item))
                    continue
                elif m.recur_op == "skip":
                    occurrence = (
                        date.fromisoformat(item.due_date)
                        if item.due_date
                        else self._clock.today()
                    )
                    rule = recurrence.with_exception(rule, occurrence)
                    nxt = recurrence.next_due(rule, occurrence, inclusive=False)
                    if nxt is None:
                        item.status = STATUS_DONE
                    else:
                        item.due_date = nxt.isoformat()
                        item.recurrence = rule
                        item.repeat = recurrence.to_legacy(rule)
                        item.reminded = False
                        item.reminded_offsets = []
                elif m.recur_op == "anchor":
                    rule.anchor = m.recur_anchor or rule.anchor
                    item.recurrence = rule
                    item.repeat = recurrence.to_legacy(rule)
                elif m.recur_op == "end":
                    if m.recur_end_date:
                        rule.end_date = m.recur_end_date
                    if m.recur_count:
                        rule.count = m.recur_count
                    item.recurrence = rule
                    item.repeat = recurrence.to_legacy(rule)
            item.updated_at = ts
            self._store.update_item(item)
            self._store.sync_plan_sessions(item, m.kind, ts)
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
        settings = [entry for entry in batch if entry.action_type == "setting"]
        plans = [entry for entry in batch if entry.action_type == "plan"]
        items = [
            entry
            for entry in batch
            if entry.action_type not in {"setting", "plan"}
        ]
        for entry in reversed(settings):
            key = entry.item_id.removeprefix("setting:")
            before = json.loads(entry.before_json) if entry.before_json else None
            self._store.set_meta(key, before or "")
        for entry in reversed(plans):
            if entry.before_json:
                self._store.restore_plan_state(json.loads(entry.before_json))
        for op in plan_undo(items):
            if op.kind == "delete":
                self._store.delete_item(op.item_id)
            else:
                self._store.update_item(op.item)
                self._store.sync_plan_sessions(op.item)
        self._store.mark_batch_undone(batch[0].batch_id)

    def _restore_batch(self, batch: list[ActionLogEntry]) -> None:
        """Restore an edit's original batch if replacement interpretation fails."""
        for entry in batch:
            if entry.action_type == "setting":
                key = entry.item_id.removeprefix("setting:")
                value = json.loads(entry.after_json) if entry.after_json else ""
                self._store.set_meta(key, value or "")
                continue
            if entry.action_type == "plan":
                if entry.after_json:
                    self._store.restore_plan_state(json.loads(entry.after_json))
                continue
            if not entry.after_json:
                continue
            item = Item.from_dict(json.loads(entry.after_json))
            if self._store.get_item(item.id) is None:
                self._store.add_item(item)
            else:
                self._store.update_item(item)
            self._store.sync_plan_sessions(item)
        self._store.mark_batch_redone(batch[0].batch_id)

    def _handle_edit(self, msg: InboundMessage) -> str:
        """The user edited an earlier message (their natural typo fix): revert
        what the original produced, then interpret the corrected text fresh."""
        message_id = self._message_key(msg)
        batch = self._store.batch_for_message(message_id)
        if batch:
            self._revert(batch)
        try:
            out = self._interpret_and_apply(
                msg.text.strip(),
                message_id,
                reply_to=msg.reply_to,
                restore_on_outage=batch or None,
            )
        except Exception:
            if batch:
                self._restore_batch(batch)
            raise
        return ("took the edit. " + out) if out else "took the edit."

    def _answer_query(self, q: QueryIntent) -> str:
        today = self._clock.today().isoformat()
        if q.kind == "plan_status":
            return self._answer_plan_status()
        if q.kind == "outlook":
            return self._answer_outlook(
                q.constraint or "what will fit this week?", q.date
            )
        if q.kind == "done":  # already-finished items (closed, so no positions)
            items = self._store.done_since(q.date or today)
            if not items:
                return "done: nothing yet"
            return "done:\n" + "\n".join(f'"{i.task}"' for i in items)
        open_items = self._store.open_items()
        ordered = ordered_open(open_items, today)
        pos = {i.id: n for n, i in enumerate(ordered, start=1)}
        if q.kind == "plan":
            short = (q.constraint or "").strip().lower()
            if (
                self._store.active_plan(today) is not None
                and re.fullmatch(
                    r"(?:what(?:'s| is) next|what should i do next|"
                    r"what am i doing(?: now)?|current plan)[?!.]?",
                    short,
                )
            ):
                return self._answer_plan_status()
            return self._answer_plan(
                q.constraint or "plan my day", open_items, q.date or today
            )
        if q.kind == "all":
            items, title = ordered, "all open:"
        elif q.kind == "overdue":
            items = [
                i
                for i in ordered
                if (i.deadline_date and i.deadline_date < today)
                or (i.due_date and i.due_date < today)
            ]
            title = "overdue:"
        elif q.kind == "week":
            end = (self._clock.today() + timedelta(days=6)).isoformat()
            items = [
                i
                for i in ordered
                if (i.due_date and today <= i.due_date <= end)
                or (i.deadline_date and today <= i.deadline_date <= end)
            ]
            title = "this week:"
        elif q.kind == "search":
            term = (q.term or "").lower()
            items = self._semantic_search(term, ordered)
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

    def _answer_plan_status(self) -> str:
        today = self._clock.today().isoformat()
        run = self._store.active_plan(today) or self._store.active_plan()
        if run is None:
            proposal = self._store.latest_proposed_plan()
            if proposal is not None:
                return (
                    f"the {proposal.day} plan is still a proposal. "
                    'say "use this plan" to adopt it explicitly.'
                )
            return 'no adopted plan. ask "plan my day" to make a proposal.'
        sessions = self._store.plan_sessions(run.id)
        visible = [
            session
            for session in sessions
            if session.status not in {"canceled"}
        ]
        if not visible:
            return f"the {run.day} plan has no remaining sessions."
        now = self._clock.now().isoformat()
        by_id: dict[str, Item] = {}
        for session in visible:
            item = self._store.get_item(session.item_id)
            if item is not None:
                by_id[item.id] = item
        self._save_focus_items(
            [by_id[s.item_id] for s in visible if s.item_id in by_id],
            context="plan",
            limit=10,
        )
        lines = [f"adopted plan for {run.day}:"]
        numbers: dict[str, int] = {}
        for session in visible:
            if session.item_id not in numbers:
                numbers[session.item_id] = len(numbers) + 1
                prefix = f"{numbers[session.item_id]}:"
            else:
                prefix = "  ↳"
            state = {
                "done": " [done]",
                "started": " [started]",
            }.get(session.status, "")
            current = " [now]" if session.start <= now < session.end else ""
            lines.append(
                f"{prefix} {session.start[11:16]}–{session.end[11:16]} "
                f"{session.label}{state}{current}"
            )
        remaining = [
            session
            for session in visible
            if session.status in {"planned", "started"} and session.end > now
        ]
        if remaining:
            next_session = min(
                remaining,
                key=lambda session: (
                    0
                    if session.status == "started" or session.start <= now < session.end
                    else 1,
                    session.start,
                ),
            )
            lines.append(
                f'next: "{next_session.label}" at {next_session.start[11:16]}.'
            )
        else:
            lines.append("no remaining session today.")
        return "\n".join(lines)

    def _answer_outlook(
        self, constraint: str, requested_end: str | None = None
    ) -> str:
        """Render a read-only seven-day capacity simulation."""
        now = self._clock.now()
        horizon_days = 7
        if requested_end:
            try:
                requested = date.fromisoformat(requested_end)
                distance = (requested - now.date()).days
                if 0 <= distance < 7:
                    horizon_days = distance + 1
            except ValueError:
                pass
        days = [
            now.date() + timedelta(days=offset)
            for offset in range(horizon_days)
        ]
        snapshots = {
            day.isoformat(): self._calendar_snapshot(day) for day in days
        }
        adopted = []
        for day in days:
            run = self._store.active_plan(day.isoformat())
            if run is not None:
                adopted.extend(self._store.plan_sessions(run.id))
        open_items = self._store.open_items()
        preferences = self._planning_preferences(constraint)
        forecast = build_week_forecast(
            open_items,
            snapshots,
            now,
            preferences,
            horizon_days=horizon_days,
            adopted_sessions=adopted,
        )
        lines = [
            f"week outlook {forecast.start_day} to {forecast.end_day}: "
            f"{forecast.used_minutes}m allocated, {forecast.free_minutes}m open"
        ]
        for day in forecast.days:
            parsed = date.fromisoformat(day.day)
            label = f"{parsed:%a} {parsed.month}/{parsed.day}"
            if parsed.weekday() not in preferences.work_days:
                lines.append(f"{label}: not a planning day")
            else:
                lines.append(
                    f"{label}: {day.used_minutes}m allocated, "
                    f"{day.free_minutes}m open"
                )
        warnings = [
            f"{day.day}: {warning}"
            for day in forecast.days
            for warning in day.warnings
            if warning not in {
                "not a configured planning day",
                "no working time remains inside the requested window",
            }
        ]
        if warnings:
            lines.append("conflicts and warnings:")
            lines.extend(f"- {warning}" for warning in dict.fromkeys(warnings))
        if forecast.risks:
            lines.append("at risk:")
            lines.extend(
                f'- {risk.label}: {risk.reason} ({risk.remaining_minutes}m left)'
                for risk in forecast.risks[:7]
            )
        else:
            lines.append("no known deadline or scheduled-date risk in this window.")
        if forecast.unplaced:
            lines.append("outside the seven-day fit:")
            lines.extend(
                f"- {item.label}: {item.remaining_minutes}m"
                for item in forecast.unplaced[:5]
            )
        if forecast.assumed_item_ids:
            assumed = set(forecast.assumed_item_ids)
            labels = [item.task for item in open_items if item.id in assumed]
            lines.append(
                f"assumption: {len(labels)} task(s) use the visible "
                f"{preferences.default_duration_minutes}m default"
            )
        if (
            preferences.budget_scope == "horizon"
            and preferences.budget_minutes is not None
        ):
            lines.append(
                f"what-if budget: {preferences.budget_minutes}m total across "
                "this outlook"
            )
        elif preferences.budget_minutes is not None:
            lines.append(
                f"what-if budget: {preferences.budget_minutes}m per planning day"
            )
        if self._uses_legacy_work_days():
            lines.append(
                "assumption: this upgraded profile keeps the prior all-days "
                'behavior. say "plan work weekdays" or use /setup to choose.'
            )
        authorized = sum(
            snapshot.status == "authorized" for snapshot in snapshots.values()
        )
        lines.append(
            f"calendar: {authorized}/{horizon_days} day(s) checked with EventKit; "
            "other days use the working profile."
        )
        lines.append(
            "nothing changed. this is a read-only load test, not an adopted "
            "weekly schedule."
        )
        return "\n".join(lines)

    def _answer_start(self, item_id: str) -> str:
        item = self._store.get_item(item_id)
        if item is None or item.status != STATUS_OPEN:
            return "that planned item is no longer open; ask me to replan."
        self._save_focus_items([item], context="current", limit=1)
        session = self._store.start_plan_session(
            item_id, self._clock.now().isoformat()
        )
        effort = (
            item.duration_minutes
            or self._minutes_setting(
                DEFAULT_DURATION_KEY,
                self._default_duration_minutes,
                5,
                480,
            )
        )
        estimate = " estimate" if item.duration_minutes is None else ""
        planned = (
            f" planned {session.start[11:16]}-{session.end[11:16]}."
            if session is not None
            else ""
        )
        return (
            f'next: "{item.task}" ({effort}m{estimate}). '
            f"i have not marked it done;{planned} tell me when you finish or "
            "need a replan."
        )

    @staticmethod
    def _item_context(items: list[Item]) -> str:
        return json.dumps(
            [
                {
                    "id": i.id,
                    "task": i.task,
                    "due_date": i.due_date,
                    "due_time": i.due_time,
                    "deadline_date": i.deadline_date,
                    "duration_minutes": i.duration_minutes,
                    "duration_confidence": i.duration_confidence,
                    "schedule_kind": i.schedule_kind,
                    "splittable": i.splittable,
                    "earliest_start": i.earliest_start,
                    "preferred_window": i.preferred_window,
                    "depends_on": i.depends_on,
                    "priority": i.priority,
                    "tag": i.tag,
                    "note": i.note,
                    "raw": i.raw_text,
                    "waiting": bool(i.waiting_since),
                }
                for i in items
            ],
            ensure_ascii=False,
        )

    def _semantic_search(self, term: str, ordered: list[Item]) -> list[Item]:
        """Use the model for meaning-based recall; validate ids and fall back locally."""
        literal = [
            i
            for i in ordered
            if term
            and term
            in " ".join(
                filter(None, (i.task, i.raw_text, i.note, i.tag))
            ).lower()
        ]
        if not term or not ordered:
            return literal
        try:
            out = self._llm.complete_json(
                SEARCH_PROMPT.format(term=term, items=self._item_context(ordered)),
                SEARCH_SCHEMA,
            )
        except Exception:
            return literal
        ids = out.get("matches") if isinstance(out, dict) else None
        if not isinstance(ids, list):
            return literal
        wanted = {str(item_id).lower() for item_id in ids}
        matches = [i for i in ordered if i.id.lower() in wanted]
        return matches or literal

    def _minutes_setting(
        self, key: str, default: int, minimum: int, maximum: int
    ) -> int:
        try:
            value = int(self._store.get_meta(key) or default)
        except (TypeError, ValueError):
            return default
        return value if minimum <= value <= maximum else default

    def _calendar_snapshot(self, target: date) -> CalendarSnapshot:
        now = self._clock.now()
        day_start = now.replace(
            year=target.year,
            month=target.month,
            day=target.day,
            hour=0,
            minute=0,
            second=0,
            microsecond=0,
        )
        if self._calendar is None:
            return CalendarSnapshot(
                "unavailable", detail="calendar adapter not configured"
            )
        try:
            return self._calendar.snapshot(day_start, day_start + timedelta(days=1))
        except Exception as exc:  # Calendar failure never breaks task planning.
            log.warning("calendar snapshot unavailable: %s", exc)
            return CalendarSnapshot("unavailable", detail=str(exc))

    def _planning_preferences(self, constraint: str):
        work_range = self._store.get_meta(WORK_HOURS_KEY) or (
            f"{self._work_start}-{self._work_end}"
        )
        try:
            work_start, work_end = work_range.split("-", 1)
        except ValueError:
            work_start, work_end = self._work_start, self._work_end
        work_days = self._effective_work_days()
        stored_breaks = self._store.get_meta(BREAKS_KEY)
        break_range = (
            stored_breaks
            if stored_breaks
            else ",".join(f"{start}-{end}" for start, end in self._breaks)
        )
        if stored_breaks == "none":
            break_range = ""
        breaks = tuple(
            (start, end)
            for window in break_range.split(",")
            if window and "-" in window
            for start, end in [window.split("-", 1)]
        )
        return parse_plan_preferences(
            constraint,
            work_start=work_start,
            work_end=work_end,
            work_days=work_days,
            breaks=breaks,
            default_duration_minutes=self._minutes_setting(
                DEFAULT_DURATION_KEY,
                self._default_duration_minutes,
                5,
                480,
            ),
            transition_buffer_minutes=self._minutes_setting(
                TRANSITION_BUFFER_KEY,
                self._transition_buffer_minutes,
                0,
                120,
            ),
        )

    def _answer_plan(
        self, constraint: str, open_items: list[Item], target_iso: str
    ) -> str:
        """Build a read-only timeline; the model can explain but cannot schedule."""
        now = self._clock.now()
        target = date.fromisoformat(target_iso)
        snapshot = self._calendar_snapshot(target)
        preferences = self._planning_preferences(constraint)
        previous = None
        active = self._store.active_plan(target_iso)
        if active is not None:
            previous = {
                "day": active.day,
                "blocks": [
                    {
                        "item_id": session.item_id,
                        "start": session.start,
                        "end": session.end,
                    }
                    for session in self._store.plan_sessions(active.id)
                    if session.status in {"planned", "started"}
                ],
            }
        else:
            try:
                previous = json.loads(
                    self._store.get_meta(LAST_PLAN_KEY) or "null"
                )
            except (TypeError, json.JSONDecodeError):
                pass
        feasible = build_day_plan(
            open_items,
            snapshot,
            now,
            preferences,
            previous=previous,
            target_day=target,
        )
        changes = diff_day_plans(previous, feasible)
        self._store.set_meta(LAST_PLAN_KEY, json.dumps(feasible.to_dict()))
        run_id = self._store.next_plan_id()
        run = PlanRun(
            id=run_id,
            day=target_iso,
            status="proposed",
            constraint=constraint,
            generated_at=now.isoformat(),
        )
        sessions = [
            PlanSession(
                id=f"{run_id}:s{number}",
                run_id=run_id,
                item_id=block.item_id,
                label=block.label,
                start=block.start.isoformat(),
                end=block.end.isoformat(),
                segment=block.segment,
            )
            for number, block in enumerate(feasible.blocks, start=1)
        ]
        self._store.save_plan_run(run, sessions)

        by_id = {item.id: item for item in open_items}
        self._save_focus_items(
            [by_id[block.item_id] for block in feasible.blocks if block.item_id in by_id],
            context="plan",
            limit=10,
        )
        timeline = [
            {
                "id": block.item_id,
                "task": block.label,
                "start": block.start.strftime("%H:%M"),
                "end": block.end.strftime("%H:%M"),
                "fixed": block.fixed,
                "deadline": by_id.get(block.item_id).deadline_date
                if by_id.get(block.item_id)
                else None,
                "priority": by_id.get(block.item_id).priority
                if by_id.get(block.item_id)
                else "normal",
            }
            for block in feasible.blocks
        ]
        if not timeline:
            headline = "nothing safely fits in the remaining window"
            out: dict = {}
        else:
            try:
                out = self._llm.complete_json(
                    PLAN_PROMPT.format(
                        today=target_iso,
                        constraint=constraint,
                        items=json.dumps(timeline, ensure_ascii=False),
                    ),
                    PLAN_SCHEMA,
                    temperature=0.2,
                )
            except Exception:
                out = {}
            headline = (
                str(out.get("headline", "")).strip()
                if isinstance(out, dict)
                else ""
            ) or "a feasible pass through the day"

        reasons: dict[str, str] = {}
        raw_picks = out.get("picks", []) if isinstance(out, dict) else []
        scheduled_ids = {block.item_id for block in feasible.blocks}
        if isinstance(raw_picks, list):
            for pick in raw_picks:
                if not isinstance(pick, dict):
                    continue
                item_id = str(pick.get("id", "")).lower()
                reason = str(pick.get("reason", "")).strip()
                if item_id in scheduled_ids and reason:
                    reasons[item_id] = reason

        title = "plan" if target_iso == self._clock.today().isoformat() else f"plan for {target_iso}"
        lines = [f"{title}: {headline}"]
        if snapshot.status == "authorized":
            lines.append(f"calendar checked: {len(snapshot.busy)} busy block(s)")
        elif snapshot.status == "not_determined":
            lines.append("calendar not connected yet; this uses working hours only. run `python app.py calendar authorize` once on the Mac.")
        elif snapshot.status in {"denied", "restricted", "write_only"}:
            lines.append("calendar unavailable by macOS permission; this uses working hours only.")
        elif snapshot.status == "disabled":
            lines.append("calendar checking is disabled; this uses working hours only.")
        else:
            lines.append("calendar bridge unavailable; this uses working hours only.")

        displayed_numbers: dict[str, int] = {}
        for block in feasible.blocks:
            item = by_id.get(block.item_id)
            badges = marks(item) if item else ""
            estimate = (
                f" ({preferences.default_duration_minutes}m estimate)"
                if block.inferred_duration
                else ""
            )
            segment = f" (part {block.segment})" if block.segment > 1 else ""
            reason = reasons.get(block.item_id)
            if block.item_id not in displayed_numbers:
                displayed_numbers[block.item_id] = len(displayed_numbers) + 1
                prefix = f"{displayed_numbers[block.item_id]}:"
                suffix = f": {reason}" if reason else ""
            else:
                prefix = "  ↳"
                suffix = ""
            lines.append(
                f"{prefix} {block.start:%H:%M}–{block.end:%H:%M} "
                f"{block.label}{badges}{estimate}{segment}{suffix}"
            )
        if feasible.warnings:
            lines.append("watchouts:")
            lines.extend(f"- {warning}" for warning in dict.fromkeys(feasible.warnings))
        if feasible.deferred:
            lines.append("not placed:")
            for deferred in feasible.deferred[:5]:
                lines.append(
                    f'- {deferred.label}: {deferred.reason} ({deferred.remaining_minutes}m)'
                )
            if len(feasible.deferred) > 5:
                lines.append(f"- plus {len(feasible.deferred) - 5} more")
        if changes:
            lines.append("changed since the last plan:")
            lines.extend(f"- {change}" for change in changes)
        lines.append(
            f"{feasible.free_minutes}m remains open. nothing moved; tell me what "
            'changed and i will replan, or say "use this plan" to adopt it.'
        )
        return "\n".join(lines)

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
            if it.deadline_date:
                line += f" (deadline {it.deadline_date})"
            if it.duration_minutes:
                hours, minutes = divmod(it.duration_minutes, 60)
                effort = (
                    f"{hours}h {minutes}m" if hours and minutes
                    else f"{hours}h" if hours
                    else f"{minutes}m"
                )
                line += f" ({effort})"
            if it.schedule_kind == "fixed":
                line += " (fixed)"
            if it.splittable:
                line += " (splittable)"
            if it.preferred_window:
                line += f" (prefer {it.preferred_window})"
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
            elif kind == "keep":
                parts.append(f'keeping: "{item.task}". i will check again later.')
            elif kind == "schedule":
                details = []
                if item.deadline_date:
                    details.append(f"deadline {item.deadline_date}")
                if item.duration_minutes:
                    details.append(f"{item.duration_minutes} minutes")
                if item.schedule_kind == "fixed":
                    details.append("fixed")
                if item.splittable:
                    details.append("splittable")
                if item.earliest_start:
                    details.append(f"starts after {item.earliest_start}")
                if item.preferred_window:
                    details.append(f"prefer {item.preferred_window}")
                if item.depends_on:
                    details.append("depends on " + ", ".join(item.depends_on))
                if item.reminder_offsets:
                    details.append(
                        "reminders " + ", ".join(
                            f"{offset}m before" for offset in item.reminder_offsets
                        )
                    )
                parts.append(
                    f'updated schedule for "{item.task}": '
                    + (", ".join(details) if details else "constraints cleared")
                )
            elif kind == "recur":
                if item.recurrence or item.repeat:
                    parts.append(
                        f'updated series for "{item.task}": '
                        f"{recurrence.describe(item.recurrence or item.repeat)}"
                    )
                else:
                    parts.append(f'stopped repeating "{item.task}" after this one')
            elif kind == "constraint_error":
                parts.append(
                    f'i did not change "{item.task}": its dates or dependencies conflict.'
                )
        parts.extend(questions)
        parts.extend(answers)
        return "\n".join(parts) if parts else "ok"

    def _today(self) -> str:
        ordered = select_digest_items(
            self._store.open_items(), self._clock.today().isoformat()
        )
        if not ordered:
            return "nothing on deck"
        return "\n".join(
            f"{n}: {i.task}{marks(i)}" for n, i in enumerate(ordered, start=1)
        )

    def _list(self) -> str:
        ordered = ordered_open(
            self._store.open_items(), self._clock.today().isoformat()
        )
        if not ordered:
            return "no open tasks"
        return "all open:\n" + "\n".join(
            f"{n}: {i.task}{marks(i)}" for n, i in enumerate(ordered, start=1)
        )

    def _settings(self) -> str:
        wake = self._store.get_meta(WAKE_KEY) or self._wake_time
        eod = self._store.get_meta(EOD_KEY)
        eod = self._eod_time if eod is None else eod
        work_hours = self._store.get_meta(WORK_HOURS_KEY) or (
            f"{self._work_start}-{self._work_end}"
        )
        work_days = self._work_days_value()
        if self._uses_legacy_work_days():
            work_days += " (legacy all-days default; set this in chat or /setup)"
        breaks = self._store.get_meta(BREAKS_KEY)
        if not breaks:
            breaks = ",".join(f"{start}-{end}" for start, end in self._breaks)
        default_duration = self._minutes_setting(
            DEFAULT_DURATION_KEY, self._default_duration_minutes, 5, 480
        )
        transition_buffer = self._minutes_setting(
            TRANSITION_BUFFER_KEY, self._transition_buffer_minutes, 0, 120
        )
        setup_stage = self._store.get_meta(ONBOARDING_STAGE_KEY)
        if setup_stage in ONBOARDING_STEPS:
            setup = f"in progress ({setup_stage.replace('_', ' ')})"
        elif self._store.get_meta(ONBOARDING_DONE_KEY):
            setup = "complete"
        else:
            setup = "not run (/setup)"
        active = self._store.active_plan(self._clock.today().isoformat())
        plan_state = (
            f"active ({active.day}, {len(self._store.plan_sessions(active.id))} sessions)"
            if active is not None
            else "none"
        )
        activation = (
            "adopted"
            if self._store.get_meta(FIRST_PLAN_ADOPTED_KEY)
            else 'not yet (ask "plan my day")'
        )
        return (
            f"settings:\ntimezone: {self._timezone}\n"
            f"morning digest: {wake}\n"
            f"evening recap: {eod if eod != '' else 'disabled'}\n"
            f"planning hours: {work_hours}\n"
            f"planning days: {work_days}\n"
            f"protected breaks: {'none' if breaks == 'none' else breaks}\n"
            f"default estimate: {default_duration}m\n"
            f"transition buffer: {transition_buffer}m\n"
            f"calendar: {self._calendar_status()}\n"
            f"setup: {setup}\n"
            f"first plan: {activation}\n"
            f"adopted plan: {plan_state}"
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
        release_notice = (
            self._store.get_meta(RELEASE_NOTICE_KEY) != __version__
            and self._store.get_meta(INSTALL_VERSION_KEY) != __version__
        )
        if release_notice:
            text += (
                f"\n\nnew in hob {__version__}: ask \"am i overloaded this "
                'week?" for a read-only capacity outlook. check planning days '
                'in /settings, then say "plan work weekdays" or use /setup if '
                "the assumption is wrong. this note appears once."
            )
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
        try:
            sent_id = await self._send(
                int(chat), text, dedupe_key=f"digest:{today}"
            )
        except TypeError:
            sent_id = await self._send(int(chat), text)
        if release_notice:
            self._store.set_meta(RELEASE_NOTICE_KEY, __version__)
        self._store.save_digest(digest)
        nudge = digest_nudge_item(ordered, today, waiting)
        if nudge is not None and isinstance(sent_id, int):
            self._store.record_sent_ref(sent_id, nudge.id)
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
        try:
            run = self._store.adopted_plan(today)
            sessions = self._store.plan_sessions(run.id) if run is not None else []
        except Exception as exc:
            log.warning("adopted plan unavailable for evening recap: %s", exc)
            run, sessions = None, []
        if run is None:
            if not on_deck:
                return True  # nothing was on deck; nothing to recap, day is done
            lines = "\n".join(
                f"{n}: {i.task}" for n, i in enumerate(on_deck, start=1)
            )
            text = (
                "evening. what got done today? tell me and i'll check them off.\n"
                + lines
            )
        else:
            done_labels = list(dict.fromkeys(
                session.label for session in sessions if session.status == "done"
            ))
            open_sessions = [
                session
                for session in sessions
                if session.status in {"planned", "started"}
                and (item := self._store.get_item(session.item_id)) is not None
                and item.status == STATUS_OPEN
            ]
            missing_sessions = [
                session
                for session in sessions
                if session.status in {"planned", "started"}
                and self._store.get_item(session.item_id) is None
            ]
            open_ids = {session.item_id for session in open_sessions}
            lines = ["evening plan check:"]
            if done_labels:
                lines.append("explicitly done:")
                lines.extend(f"- {label}" for label in done_labels)
            if open_sessions:
                lines.append("still open from the adopted plan:")
                seen: set[str] = set()
                for session in open_sessions:
                    if session.item_id in seen:
                        continue
                    seen.add(session.item_id)
                    windows = [
                        f"{part.start[11:16]}-{part.end[11:16]}"
                        for part in open_sessions
                        if part.item_id == session.item_id
                    ]
                    lines.append(f"- {session.label} ({', '.join(windows)})")
            if missing_sessions:
                lines.append("plan references no longer in the task store:")
                lines.extend(
                    f"- {label}"
                    for label in dict.fromkeys(
                        session.label for session in missing_sessions
                    )
                )
            extra = [item for item in on_deck if item.id not in open_ids]
            if extra:
                lines.append("also still on deck:")
                lines.extend(f"- {item.task}" for item in extra)
            if open_sessions or extra or missing_sessions:
                lines.append(
                    "what actually got done? tell me; elapsed sessions are not "
                    "marked complete on their own."
                )
            else:
                lines.append("everything in the adopted plan is explicitly done.")
            text = "\n".join(lines)
        try:
            await self._send(int(chat), text, dedupe_key=f"eod:{today}")
        except TypeError:
            await self._send(int(chat), text)
        return True


class ReminderService:
    """Pings the user a lead time before a timed item's due moment, so "call at
    3pm" is a heads-up (say, 2:50) rather than only a digest line and not only a
    ping at 3:00 sharp. send is async(chat_id, text)."""

    def __init__(
        self,
        store: Store,
        clock: Clock,
        send,
        lead_minutes: int = 0,
        plan_send=None,
    ) -> None:
        self._store = store
        self._clock = clock
        self._send = send
        self._plan_send = plan_send
        self._lead = timedelta(minutes=max(0, lead_minutes))
        self._grace = timedelta(hours=6)

    async def check(self) -> None:
        chat = self._store.get_meta(CHAT_ID_KEY)
        if chat is None:
            return
        self._store.expire_plans(
            self._clock.today().isoformat(), self._clock.now().isoformat()
        )
        # Fire when now reaches (due - lead): compare due moments to now + lead.
        # A snoozed item instead fires at its snooze_until (compared to now).
        now = self._clock.now().strftime("%Y-%m-%dT%H:%M")
        threshold = (self._clock.now() + self._lead).strftime("%Y-%m-%dT%H:%M")
        earliest = (self._clock.now() - self._grace).strftime("%Y-%m-%dT%H:%M")
        missed_cutoff = (self._clock.now() - timedelta(minutes=15)).strftime(
            "%Y-%m-%dT%H:%M"
        )
        for item in self._store.due_reminders(threshold, now, earliest):
            text = f'reminder: "{item.task}" at {item.due_time}'
            due_at = f"{item.due_date}T{item.due_time}"
            due_wall = wall_datetime(
                date.fromisoformat(item.due_date),
                item.due_time,
                self._clock.now().tzinfo,
            )
            wall_status = wall_time_status(due_wall)
            if not item.snooze_until and due_at < missed_cutoff:
                text = f'missed reminder: "{item.task}" was due at {item.due_time}'
            if not item.snooze_until and wall_status == "nonexistent":
                text = (
                    f'missed reminder: "{item.task}" was set for '
                    f"{item.due_time}, which the clock skipped for daylight saving"
                )
            elif not item.snooze_until and wall_status == "ambiguous":
                text += " (this time occurs twice today; using the first occurrence)"
            if item.snooze_until:
                text = f'reminder (snoozed): "{item.task}" at {item.due_time}'
            if item.note:
                text += f" ({item.note})"
            try:
                sent_id = await self._send(
                    int(chat),
                    text,
                    item.id,
                    dedupe_key=(
                        f"reminder:{item.id}:"
                        f"{item.snooze_until or due_at}:{item.updated_at}"
                    ),
                )
            except TypeError:
                # Small fake/custom adapters may still implement send(chat, text).
                sent_id = await self._send(int(chat), text)
            self._store.mark_reminded(item.id)
            # Remember which item this ping was about, so a Telegram reply to it
            # ("done", "snooze 20") anchors to the item with no guessing.
            if isinstance(sent_id, int):
                self._store.record_sent_ref(sent_id, item.id)

        # An explicitly adopted plan authorizes one start nudge per session.
        # Keep the catch-up window short so waking the Mac does not dump stale
        # time-block notifications into the chat.
        current_iso = self._clock.now().isoformat(timespec="seconds")
        session_earliest = (
            self._clock.now() - timedelta(minutes=15)
        ).isoformat(timespec="seconds")
        for session in self._store.due_plan_sessions(
            session_earliest, current_iso
        ):
            text = (
                f'plan: "{session.label}" starts now '
                f"({session.start[11:16]}–{session.end[11:16]}). "
                "reply done, or tell me what changed and i will replan."
            )
            if self._plan_send is not None:
                sent_id = await self._plan_send(
                    int(chat),
                    text,
                    dedupe_key=f"plan-session:{session.id}:{session.start}",
                )
            else:
                sent_id = await self._send(int(chat), text)
            self._store.mark_plan_session_notified(session.id, current_iso)
            if isinstance(sent_id, int):
                self._store.record_sent_ref(sent_id, session.item_id)

        # Tasks with explicit offsets own their reminder cadence instead of using
        # the global lead. If sleep caused several offsets to pass, send only the
        # latest relevant one and mark the older missed offsets so wake-up is calm.
        current = self._clock.now()
        for item in self._store.open_items():
            if (
                not item.reminder_offsets
                or item.waiting_since
                or not item.due_date
                or not item.due_time
            ):
                continue
            if item.snooze_until:
                snooze_at = datetime.fromisoformat(item.snooze_until).replace(
                    tzinfo=current.tzinfo
                )
                if snooze_at > current:
                    continue
                chosen = -1
                due_offsets: list[int] = []
                text = f'reminder (snoozed): "{item.task}" at {item.due_time}'
            else:
                due_at = wall_datetime(
                    date.fromisoformat(item.due_date),
                    item.due_time,
                    current.tzinfo,
                )
                wall_status = wall_time_status(due_at)
                if due_at < current - self._grace:
                    continue
                due_offsets = [
                    offset
                    for offset in item.reminder_offsets
                    if offset not in item.reminded_offsets
                    and due_at - timedelta(minutes=offset) <= current
                ]
                if not due_offsets:
                    continue
                chosen = min(due_offsets)
                text = f'reminder: "{item.task}" at {item.due_time}'
                if wall_status == "nonexistent":
                    text = (
                        f'missed reminder: "{item.task}" was set for '
                        f"{item.due_time}, which the clock skipped for daylight saving"
                    )
                elif wall_status == "ambiguous":
                    text += (
                        " (this time occurs twice today; using the first occurrence)"
                    )
            if item.note:
                text += f" ({item.note})"
            try:
                sent_id = await self._send(
                    int(chat),
                    text,
                    item.id,
                    dedupe_key=(
                        f"reminder:{item.id}:{item.due_date}T{item.due_time}:"
                        f"offset:{chosen}:{item.updated_at}"
                    ),
                )
            except TypeError:
                sent_id = await self._send(int(chat), text)
            if chosen == -1:
                item.snooze_until = None
                self._store.update_item(item)
            else:
                for offset in due_offsets:
                    self._store.mark_reminded(item.id, offset)
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
    service = MessageService(
        store,
        clock,
        llm,
        cfg.timezone,
        cfg.wake_time,
        cfg.allowed_telegram_user_id,
        cfg.eod_time,
        retry_model_outages=True,
        calendar=EventKitCalendar(cfg.calendar_bridge or None, cfg.calendar_enabled),
        work_start=cfg.work_start,
        work_end=cfg.work_end,
        work_days=cfg.work_days,
        breaks=cfg.breaks,
        default_duration_minutes=cfg.default_duration_minutes,
        transition_buffer_minutes=cfg.transition_buffer_minutes,
    )
    telegram = TelegramAdapter(
        store, service.handle, token=cfg.telegram_token,
        reaction_handler=service.handle_reaction,
        callback_handler=service.handle_callback,
    )
    digest = DigestService(store, clock, telegram.send, pin=telegram.pin)
    reminder = ReminderService(
        store,
        clock,
        telegram.send_reminder,
        cfg.reminder_lead,
        plan_send=telegram.send,
    )
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
        print(
            f"  OK   config: tz={cfg.timezone} wake={cfg.wake_time} "
            f"estimate={cfg.default_duration_minutes}m "
            f"buffer={cfg.transition_buffer_minutes}m db={cfg.db_path}"
        )
    except ConfigError as exc:
        print(f"  FAIL config: {exc}")
        return 2

    ok = True
    if cfg.telegram_enabled:
        print(f"  OK   Telegram token loaded from {cfg.telegram_token_source}")
    else:
        print("  WARN Telegram token not found: create a bot with @BotFather and "
              "run `python app.py token set`")
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
    calendar = EventKitCalendar(cfg.calendar_bridge or None, cfg.calendar_enabled)
    snapshot = calendar.status()
    if snapshot.status == "authorized":
        print("  OK   calendar: read access available")
    elif snapshot.status == "disabled":
        print("  INFO calendar: disabled")
    elif snapshot.status == "not_determined":
        print("  WARN calendar: run `python app.py calendar authorize`")
    else:
        print(f"  WARN calendar: {snapshot.status}")
    print("all good" if ok else "problems found (see above)")
    return 0 if ok else 1


def _status(cfg: Config) -> int:
    """Local operational snapshot; never prints secrets or message content."""
    print(f"hob {__version__} status")
    ok = True
    try:
        with SqliteStore(cfg.db_path) as store:
            healthy, detail = store.integrity_check()
            queue = store.queue_metrics()
            print(
                f"  {'OK  ' if healthy else 'FAIL'} database: {cfg.db_path} "
                f"(schema {store.schema_version}, {detail})"
            )
            print(f"  INFO open tasks: {len(store.open_items())}")
            queue_ok = not queue["pending_in"] and not queue["pending_out"]
            print(
                f"  {'OK  ' if queue_ok else 'WARN'} queues: "
                f"inbound={queue['pending_in']} outbound={queue['pending_out']} "
                f"failed_in={queue['failed_in']} failed_out={queue['failed_out']} "
                f"quarantined_in={queue['quarantined_in']} "
                f"quarantined_out={queue['quarantined_out']}"
            )
            if queue["failed_in"] or queue["failed_out"]:
                print("  WARN queue recovery: run `python app.py queue status`")
                ok = False
            owner = store.get_meta(OWNER_USER_KEY)
            offset = store.get_meta("tg_offset") or "0"
            digest_date = store.get_meta("last_digest_date") or "never"
            eod_date = store.get_meta("last_eod_date") or "never"
            print(
                f"  INFO Telegram: token={cfg.telegram_token_source} "
                f"owner={'paired' if owner or cfg.allowed_telegram_user_id else 'unpaired'} "
                f"offset={offset}"
            )
            print(f"  INFO last morning digest: {digest_date}; evening recap: {eod_date}")
            work_hours = store.get_meta(WORK_HOURS_KEY) or (
                f"{cfg.work_start}-{cfg.work_end}"
            )
            stored_work_days = store.get_meta(WORK_DAYS_KEY)
            if stored_work_days:
                work_days = stored_work_days
            elif store.get_meta(ONBOARDING_DONE_KEY) or (
                store.get_meta(OWNER_USER_KEY)
                and store.get_meta(INSTALL_VERSION_KEY) != __version__
            ):
                work_days = "mon,tue,wed,thu,fri,sat,sun (legacy default)"
            else:
                work_days = ",".join(
                    DAY_CODES[index] for index in cfg.work_days
                )
            default_duration = store.get_meta(DEFAULT_DURATION_KEY) or str(
                cfg.default_duration_minutes
            )
            transition_buffer = store.get_meta(TRANSITION_BUFFER_KEY) or str(
                cfg.transition_buffer_minutes
            )
            print(
                f"  INFO planning: hours={work_hours} "
                f"days={work_days} estimate={default_duration}m "
                f"buffer={transition_buffer}m"
            )
            active_plan = store.active_plan()
            proposal = store.latest_proposed_plan()
            active_label = (
                f"{active_plan.day}/{len(store.plan_sessions(active_plan.id))} sessions"
                if active_plan is not None
                else "none"
            )
            proposal_label = proposal.day if proposal is not None else "none"
            print(
                f"  INFO execution: active={active_label} proposal={proposal_label}"
            )
            metrics = store.execution_metrics()

            def counts(values: dict) -> str:
                return ",".join(
                    f"{key}:{values[key]}" for key in sorted(values)
                ) or "none"

            print(
                "  INFO adoption: "
                f"first_plan={'yes' if store.get_meta(FIRST_PLAN_ADOPTED_KEY) else 'no'} "
                f"adopted_runs={metrics['adopted_runs']} "
                f"latest={metrics['latest_adopted_at'] or 'never'} "
                f"runs={counts(metrics['runs'])}"
            )
            print(
                "  INFO sessions: "
                f"states={counts(metrics['sessions'])} "
                f"notified={metrics['notified_sessions']} "
                f"nudge_delivery={counts(metrics['nudge_delivery'])}"
            )
            ok = ok and healthy
    except Exception as exc:  # noqa: BLE001
        print(f"  FAIL database: {exc}")
        ok = False

    llm = OllamaLlm(cfg.model, cfg.ollama_host)
    try:
        ready = _model_ready(llm, cfg.model)
        print(
            f"  {'OK  ' if ready else 'FAIL'} model: {cfg.model} at {cfg.ollama_host}"
        )
        ok = ok and ready
    except Exception:  # noqa: BLE001
        print(f"  FAIL model: Ollama unavailable at {cfg.ollama_host}")
        ok = False
    calendar = EventKitCalendar(cfg.calendar_bridge or None, cfg.calendar_enabled)
    snapshot = calendar.status()
    label = "OK  " if snapshot.status == "authorized" else "INFO"
    print(
        f"  {label} calendar: {snapshot.status}"
    )
    return 0 if ok else 1


def _calendar_command(cfg: Config, argv: list[str]) -> int:
    action = argv[1] if len(argv) > 1 else "status"
    calendar = EventKitCalendar(cfg.calendar_bridge or None, cfg.calendar_enabled)
    if action == "status":
        snapshot = calendar.status()
        print(f"hob: calendar {snapshot.status}")
        if snapshot.detail:
            print(f"hob: {snapshot.detail}")
        return 0 if snapshot.status in {"authorized", "disabled", "not_determined"} else 1
    if action == "authorize":
        snapshot = calendar.request_access()
        if snapshot.status == "authorized":
            print("hob: calendar connected read-only; event titles stay inside EventKit")
            return 0
        print(f"hob: calendar access {snapshot.status}", file=sys.stderr)
        if snapshot.detail:
            print(f"hob: {snapshot.detail}", file=sys.stderr)
        return 1
    print("usage: python app.py calendar [status|authorize]", file=sys.stderr)
    return 2


def _token_command(argv: list[str]) -> int:
    action = argv[1] if len(argv) > 1 else "status"
    try:
        if action == "set":
            token = getpass.getpass("Telegram bot token: ").strip()
            set_telegram_token(token)
            print("hob: Telegram token saved in macOS Keychain")
            return 0
        if action == "delete":
            removed = delete_telegram_token()
            print(
                "hob: Keychain token deleted"
                if removed
                else "hob: no Keychain token found"
            )
            return 0
        if action == "status":
            print(
                "hob: Telegram token is stored in macOS Keychain"
                if get_telegram_token()
                else "hob: no Telegram token in macOS Keychain"
            )
            return 0
    except KeychainError as exc:
        print(f"hob: Keychain error: {exc}", file=sys.stderr)
        return 1
    print("usage: python app.py token [status|set|delete]", file=sys.stderr)
    return 2


def _export_or_backup(cfg: Config, argv: list[str]) -> int:
    ambiguity = _database_choice_error(cfg)
    if ambiguity:
        print(f"hob: {argv[0]} refused: {ambiguity}", file=sys.stderr)
        return 2
    command = argv[0]
    default = (
        f"hob-export-{datetime.now().date().isoformat()}.json"
        if command == "export"
        else f"hob-backup-{datetime.now().date().isoformat()}.db"
    )
    destination = Path(argv[1] if len(argv) > 1 else default).expanduser()
    if destination.resolve() == Path(cfg.db_path).expanduser().resolve():
        print(
            "hob: destination must not overwrite the live database", file=sys.stderr
        )
        return 2
    destination.parent.mkdir(parents=True, exist_ok=True)
    with SqliteStore(cfg.db_path) as store:
        if command == "export":
            destination.write_text(
                json.dumps(store.export_data(), indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
        else:
            store.backup(str(destination))
    print(f"hob: wrote {command} from {cfg.db_path} to {destination}")
    return 0


def _database_choice_error(cfg: Config) -> str | None:
    """Refuse recovery operations when legacy compatibility is ambiguous."""
    if os.environ.get("HOB_DB_PATH", "").strip():
        return None
    selected = Path(cfg.db_path).expanduser().resolve()
    legacy = (Path.cwd() / "hob.db").resolve()
    app_data = (
        Path.home() / "Library" / "Application Support" / "Hob" / "hob.db"
    ).resolve()
    if selected == legacy and app_data.exists() and app_data != selected:
        return (
            f"both {legacy} and {app_data} exist; set HOB_DB_PATH explicitly "
            "to choose one"
        )
    return None


def _queue_command(cfg: Config, argv: list[str]) -> int:
    """Inspect and explicitly recover durable delivery without exposing content."""
    usage = (
        "usage: python app.py queue [status|history|"
        "retry DIRECTION REF|quarantine DIRECTION REF]"
    )
    action = argv[1] if len(argv) > 1 else "status"
    ambiguity = _database_choice_error(cfg)
    if ambiguity:
        print(f"hob: queue refused: {ambiguity}", file=sys.stderr)
        return 2

    if action in {"status", "history"}:
        if len(argv) != 2 and not (action == "status" and len(argv) == 1):
            print(usage, file=sys.stderr)
            return 2
        try:
            with SqliteStore(cfg.db_path) as store:
                if action == "history":
                    history = store.queue_recovery_history()
                    print("hob queue recovery history (content is never shown)")
                    if not history:
                        print("  no recovery actions")
                    for event in history:
                        print(
                            f"  {event.at} {event.action} {event.direction} "
                            f"{event.ref} from={event.prior_status} "
                            f"attempts={event.prior_attempts}"
                        )
                    return 0
                metrics = store.queue_metrics()
                print("hob queue status (content and errors are never shown)")
                print(
                    "  inbound: "
                    f"pending={metrics['pending_in']} "
                    f"failed={metrics['failed_in']} "
                    f"quarantined={metrics['quarantined_in']}"
                )
                print(
                    "  outbound: "
                    f"pending={metrics['pending_out']} "
                    f"failed={metrics['failed_out']} "
                    f"quarantined={metrics['quarantined_out']}"
                )
                problems = store.queue_problem_entries()
                for entry in problems:
                    print(
                        f"  {entry.direction} {entry.ref}: kind={entry.kind} "
                        f"status={entry.status} attempts={entry.attempts} "
                        f"created={entry.created_at}"
                    )
                failed = metrics["failed_in"] + metrics["failed_out"]
                if failed:
                    print(
                        "  stop the Hob daemon, then run one of:"
                    )
                    print(
                        "    python app.py queue retry DIRECTION REF"
                    )
                    print(
                        "    python app.py queue quarantine DIRECTION REF"
                    )
                return 1 if failed else 0
        except (OSError, sqlite3.DatabaseError) as exc:
            print(f"hob: queue inspection failed: {exc}", file=sys.stderr)
            return 1

    if action not in {"retry", "quarantine"} or len(argv) != 4:
        print(usage, file=sys.stderr)
        return 2
    direction, ref = argv[2], argv[3]
    if direction not in {"inbox", "outbox"}:
        print("hob: queue direction must be inbox or outbox", file=sys.stderr)
        return 2
    at = datetime.now(timezone.utc).isoformat()
    try:
        with database_lease(cfg.db_path):
            with SqliteStore(cfg.db_path) as store:
                recovered = store.recover_queue_entry(direction, ref, action, at)
    except (DatabaseBusyError, OSError, ValueError, sqlite3.DatabaseError) as exc:
        print(f"hob: queue {action} failed: {exc}", file=sys.stderr)
        return 1
    if not recovered:
        print(
            f"hob: {direction} {ref} is not a failed or quarantined entry",
            file=sys.stderr,
        )
        return 1
    if action == "retry":
        print(f"hob: {direction} {ref} reset for retry; restart the daemon")
        if direction == "outbox":
            print(
                "hob: outbound retry can duplicate a message if Telegram accepted "
                "the earlier send without acknowledging it"
            )
    elif direction == "inbox":
        print(
            f"hob: inbox {ref} quarantined; it was not applied, is retained for "
            "retry, and later updates may proceed"
        )
    else:
        print(
            f"hob: outbox {ref} quarantined; Hob's state remains applied, the "
            "unsent message is retained for retry, and later deliveries may proceed"
        )
    return 0


def _restore_or_import(cfg: Config, argv: list[str]) -> int:
    command = argv[0]
    if len(argv) != 2:
        print(f"usage: python app.py {command} SOURCE", file=sys.stderr)
        return 2
    ambiguity = _database_choice_error(cfg)
    if ambiguity:
        print(f"hob: {command} refused: {ambiguity}", file=sys.stderr)
        return 2
    source = str(Path(argv[1]).expanduser())
    try:
        with database_lease(cfg.db_path):
            safety = (
                restore_database(source, cfg.db_path)
                if command == "restore"
                else import_export(source, cfg.db_path)
            )
    except (DatabaseBusyError, OSError, ValueError, sqlite3.DatabaseError) as exc:
        print(f"hob: {command} failed: {exc}", file=sys.stderr)
        return 1
    print(f"hob: {command} verified and installed at {cfg.db_path}")
    if safety:
        print(f"hob: previous data saved at {safety}")
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    logging.basicConfig(
        level=logging.INFO, format=LOG_FORMAT
    )
    # python-telegram-bot's httpx logs every getUpdates at INFO with the bot
    # token in the URL. Quiet it so the token never lands in the log file.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    if argv and argv[0] == "token":
        return _token_command(argv)
    if argv and argv[0] == "doctor":
        return _doctor()
    try:
        cfg = Config.from_env()
    except ConfigError as exc:
        print(f"hob: config error: {exc}", file=sys.stderr)
        return 2
    _redact_logging(cfg.telegram_token)

    if argv and argv[0] in ("export", "backup"):
        return _export_or_backup(cfg, argv)
    if argv and argv[0] in ("restore", "import"):
        return _restore_or_import(cfg, argv)
    if argv and argv[0] == "calendar":
        return _calendar_command(cfg, argv)
    if argv and argv[0] == "queue":
        return _queue_command(cfg, argv)
    if argv and argv[0] == "status":
        return _status(cfg)

    log = logging.getLogger("hob")
    log.info(
        "starting: model=%s tz=%s wake=%s db=%s",
        cfg.model,
        cfg.timezone,
        cfg.wake_time,
        cfg.db_path,
    )

    try:
        with database_lease(cfg.db_path):
            with SqliteStore(cfg.db_path) as store:
                if not cfg.telegram_enabled:
                    print(
                        "hob: Telegram token not configured, nothing to run. "
                        "Create a bot with @BotFather, run `python app.py token set`, "
                        "and check setup with "
                        "`python app.py doctor`. See README.",
                        file=sys.stderr,
                    )
                    return 0
                try:
                    asyncio.run(_run_daemon(cfg, store))
                except KeyboardInterrupt:
                    log.info("interrupted, shutting down")
    except DatabaseBusyError as exc:
        print(f"hob: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
