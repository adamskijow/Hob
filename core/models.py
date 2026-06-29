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

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "Item":
        return cls(**data)


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


# Actions: the model's proposal, parsed from forced JSON. The core validates and
# reconciles these before anything touches the store. Capture and Unknown are
# used from Phase 5; the rest come online in Phase 7.
@dataclass
class Capture:
    task: str  # clean label
    raw: str  # echo of the phrasing; the core resolves the date from this
    time: str | None = None  # HH:MM
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
    raw: str = ""  # date phrasing the core re-resolves the new date from
    confidence: float = 1.0


@dataclass
class Query:
    kind: str  # today | date | all
    date: str | None = None  # ISO, for kind=date


@dataclass
class Bulk:
    """Act on many items at once. The model picks op and scope; the planner
    expands it deterministically over the matching open items."""

    op: str  # complete | drop
    scope: str  # today | all | date
    date: str | None = None  # ISO, for scope=date; re-resolved by the core
    confidence: float = 1.0


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
