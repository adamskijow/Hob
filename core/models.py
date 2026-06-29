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
