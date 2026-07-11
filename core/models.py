# SPDX-License-Identifier: MIT
"""Core data types. Pure dataclasses, no I/O.

Stored as flat rows (see adapters/store_sqlite.py). Status and source are plain
strings to keep snapshots trivially JSON-serializable for the action log.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field

# Item status values.
STATUS_OPEN = "open"
STATUS_DONE = "done"
STATUS_DROPPED = "dropped"

# Item source values.
SOURCE_CAPTURE = "capture"
SOURCE_ROLLOVER = "rollover"


@dataclass
class RecurrenceRule:
    """Structured recurrence persisted independently of model wording."""

    frequency: str  # day | week | month | year
    interval: int = 1
    weekdays: list[str] = field(default_factory=list)
    month_day: int | None = None
    month: int | None = None
    anchor: str = "fixed"  # fixed schedule | completion-relative
    anchor_date: str | None = None  # preserves cadence when one occurrence moves
    end_date: str | None = None
    count: int | None = None
    completed: int = 0
    exceptions: list[str] = field(default_factory=list)


@dataclass
class Item:
    id: str
    raw_text: str
    task: str
    due_date: str | None  # ISO YYYY-MM-DD
    due_time: str | None  # HH:MM
    status: str  # STATUS_*
    source: str  # SOURCE_*
    created_at: str  # ISO datetime
    updated_at: str  # ISO datetime
    reminded: bool = False  # an intraday reminder for its due time was sent
    repeat: str | None = None  # recurrence rule (core.recurrence); None = one-off
    priority: str = "normal"  # high | normal | low; floats up/down the digest
    tag: str | None = None  # project / list this task belongs to, e.g. "wedding"
    snooze_until: str | None = None  # ISO datetime; the reminder re-fires then
    note: str | None = None  # a detail stuck to the task ("gate code 4412")
    waiting_since: str | None = None  # ISO date; parked on someone else since
    deadline_date: str | None = None  # hard deadline, separate from the do date
    duration_minutes: int | None = None
    duration_confidence: float | None = None
    schedule_kind: str = "flexible"  # flexible | fixed
    splittable: bool = False
    earliest_start: str | None = None  # ISO date or datetime
    preferred_window: str | None = None
    parent_id: str | None = None
    depends_on: list[str] = field(default_factory=list)
    reminder_offsets: list[int] = field(default_factory=list)
    reminded_offsets: list[int] = field(default_factory=list)
    recurrence: RecurrenceRule | None = None

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "Item":
        values = dict(data)
        structured = values.get("recurrence")
        if isinstance(structured, dict):
            values["recurrence"] = RecurrenceRule(**structured)
        return cls(**values)


@dataclass
class DigestItem:
    id: str
    label: str

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class Digest:
    sent_at: str  # ISO datetime
    items: list[DigestItem] = field(default_factory=list)
    id: int | None = None


@dataclass
class ActionLogEntry:
    batch_id: str
    ts: str
    action_type: str  # capture | complete | drop | reschedule
    item_id: str
    before_json: str | None = None  # item snapshot before, null for capture
    after_json: str | None = None  # item snapshot after, null for hard delete
    inbound_message_id: str | None = None
    id: int | None = None


@dataclass
class InboxEntry:
    """A normalized Telegram update waiting for durable processing."""

    key: str
    update_id: int
    kind: str
    payload: dict
    status: str = "pending"
    attempts: int = 0
    last_error: str | None = None
    created_at: str = ""
    completed_at: str | None = None


@dataclass
class OutboxEntry:
    """A Telegram delivery committed alongside the state that produced it."""

    id: int
    dedupe_key: str
    chat_id: int
    kind: str
    text: str
    item_id: str | None = None
    markup: dict | None = None
    status: str = "pending"
    attempts: int = 0
    last_error: str | None = None
    created_at: str = ""
    sent_at: str | None = None
    telegram_message_id: int | None = None


# Actions: the model's proposal, parsed from forced JSON. The core validates and
# reconciles these before anything touches the store. Capture and Unknown are
# used from Phase 5; the rest come online in Phase 7.
@dataclass
class When:
    """A typed date intent. The model classifies a phrase into one of these; the
    core (core.dates.resolve_intent) does the calendar math. The model never
    computes a date itself, so it cannot get the arithmetic wrong."""

    kind: str  # none|today|tomorrow|yesterday|weekday|offset|weekend|week|
    #            month|month_day|ordinal_day|absolute|ambiguous
    which: str | None = None  # this | next (weekday, weekend, week, month)
    day: str | None = None  # mon..sun (weekday)
    n: int | None = None  # count (offset)
    unit: str | None = None  # day | week | month (offset)
    anchor: str | None = None  # start | end (month)
    part: str | None = None  # early | mid | late (week)
    month: int | None = None  # 1..12 (month_day)
    day_num: int | None = None  # day of month (month_day, ordinal_day)
    date: str | None = None  # ISO YYYY-MM-DD (absolute, explicit date only)


@dataclass
class Capture:
    task: str  # clean label
    raw: str  # echo of the user's phrasing, stored for the record
    when: When | None = None  # typed date intent; the core resolves the date
    time: str | None = None  # HH:MM
    relate: str | None = None  # id of an existing item to inherit a date from
    repeat: str | None = None  # recurrence rule, e.g. "daily" or "weekly:mon"
    priority: str = "normal"  # high | normal | low
    tag: str | None = None  # project / list to file this task under
    waiting: bool = False  # blocked on someone else from the start
    note: str | None = None  # extra detail worth keeping with the task
    deadline: When | None = None
    duration_minutes: int | None = None
    duration_confidence: float | None = None
    schedule_kind: str = "flexible"
    splittable: bool = False
    earliest: When | None = None
    earliest_time: str | None = None
    preferred_window: str | None = None
    parent: str | None = None
    depends_on: list[str] = field(default_factory=list)
    reminder_offsets: list[int] = field(default_factory=list)
    repeat_anchor: str = "fixed"
    repeat_end: When | None = None
    repeat_count: int | None = None
    confidence: float = 1.0


@dataclass
class Schedule:
    """Update deterministic scheduling constraints on an existing item."""

    target: str
    deadline: When | None = None
    duration_minutes: int | None = None
    duration_confidence: float | None = None
    schedule_kind: str | None = None
    splittable: bool | None = None
    earliest: When | None = None
    earliest_time: str | None = None
    preferred_window: str | None = None
    depends_on: list[str] = field(default_factory=list)
    reminder_offsets: list[int] = field(default_factory=list)
    clear: list[str] = field(default_factory=list)
    confidence: float = 1.0


@dataclass
class Recur:
    """Change a recurring series separately from its current occurrence."""

    target: str
    op: str  # skip | stop | anchor | end
    anchor: str | None = None
    end: When | None = None
    count: int | None = None
    confidence: float = 1.0


@dataclass
class Note:
    """Attach a detail to an existing item ("gate code is 4412")."""

    target: str
    text: str
    confidence: float = 1.0


@dataclass
class Wait:
    """Park an existing item as blocked on someone else."""

    target: str
    confidence: float = 1.0


@dataclass
class Resume:
    """Unpark a waiting item; the block cleared."""

    target: str
    confidence: float = 1.0


@dataclass
class Setting:
    """Change a preference in plain language ("send the digest at 7")."""

    key: str  # wake_time
    raw: str  # the value words; the core parses and validates them


@dataclass
class Prioritize:
    """Change the priority of an item already on the list."""

    target: str  # item id / position from the active list
    level: str  # high | normal | low
    confidence: float = 1.0


@dataclass
class Complete:
    target: str  # item id from the active list
    confidence: float = 1.0


@dataclass
class Drop:
    target: str
    reason: str | None = None
    confidence: float = 1.0


@dataclass
class Reschedule:
    target: str
    when: When | None = None  # typed date intent for the new date
    time: str | None = None  # new clock time ("make it 4pm" -> 16:00)
    raw: str = ""  # echo of the phrasing, for the record
    confidence: float = 1.0


@dataclass
class Amend:
    target: str  # existing item id
    task: str  # the full new label for that item
    confidence: float = 1.0


@dataclass
class Query:
    kind: str  # today | date | all | overdue | week | search | done | tag | plan
    when: When | None = None  # typed date intent, for kind=date
    date: str | None = None  # ISO, resolved by the core for kind=date
    term: str | None = None  # free-text search keywords, for kind=search
    tag: str | None = None  # project / list name, for kind=tag
    constraint: str | None = None  # time/energy/context for a planning request


@dataclass
class Bulk:
    """Act on many items at once. The model picks op and scope; the planner
    expands it deterministically over the matching open items."""

    op: str  # complete | drop | reschedule
    scope: str  # today | all | date
    when: When | None = None  # destination (op=reschedule) or scope day (scope=date)
    exclude: list[str] = field(default_factory=list)  # "everything BUT these"
    confidence: float = 1.0


@dataclass
class Snooze:
    """Put off an item's reminder ping without moving the task itself."""

    target: str  # item id / position from the active list
    minutes: int = 10
    confidence: float = 1.0


@dataclass
class Chitchat:
    """A social pleasantry with no task and no question (a greeting, thanks, an
    acknowledgment). The model supplies a short, warm reply."""

    reply: str | None = None


@dataclass
class Undo:
    """The user asked to undo the last change ("scratch that", "undo that")."""


@dataclass
class Unknown:
    note: str | None = None


@dataclass
class InterpreterContext:
    """Everything the interpreter is given for one inbound message."""

    message: str
    today: str  # ISO date
    now: str  # ISO datetime
    timezone: str
    active_items: list[dict]  # [{id, label, due_date}], the open items on deck
    last_digest: list[dict]  # [{id, label}], exactly as last presented
    # Clarifications from the previous turn, persisted so a short reply resolves
    # against the question it answers. [{kind, question, task?/target?/label?}].
    pending: list[dict] = field(default_factory=list)
    # Conversational focus: items touched in the last few minutes, most recent
    # first ([{id, label}]), so a bare follow-up ("make it 4pm") resolves.
    focus: list[dict] = field(default_factory=list)
    # The item a replied-to Hob message (e.g. a reminder) was about ({id, label});
    # bare words in the reply ("done", "snooze 20") refer to it.
    replied: dict | None = None
    # Who forwarded this message to hob (a Telegram forward), else None. A
    # forwarded message's text is content to capture, not a command to hob.
    forwarded_from: str | None = None
