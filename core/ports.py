# SPDX-License-Identifier: MIT
"""Protocols injected into the pure core. Interfaces only, no I/O.

The core depends only on these protocols and the standard library. Real
implementations live in adapters/; tests inject fakes. Method sets grow as the
phases land; protocols are structural, so adapters need only match what is used.
"""
from __future__ import annotations

from datetime import date, datetime
from typing import ContextManager, Protocol, runtime_checkable

from core.models import ActionLogEntry, Digest, InboxEntry, Item, OutboxEntry


@runtime_checkable
class Clock(Protocol):
    """Time source. The core never reads the wall clock directly."""

    def now(self) -> datetime:  # timezone-aware, in the configured timezone
        ...

    def today(self) -> date:
        ...


@runtime_checkable
class Llm(Protocol):
    """Local model. Returns parsed structured JSON; the core validates it.

    temperature defaults to 0 for deterministic classification; the edge raises
    it only for creative text like a chitchat reply."""

    def complete_json(self, prompt: str, schema: dict, temperature: float = 0.0) -> dict:
        ...


@runtime_checkable
class Store(Protocol):
    """Persistence. Flat rows; short string ids on items."""

    # items
    def next_item_id(self) -> str:
        ...

    def add_item(self, item: Item) -> None:
        ...

    def get_item(self, item_id: str) -> Item | None:
        ...

    def update_item(self, item: Item) -> None:
        ...

    def delete_item(self, item_id: str) -> None:
        ...

    def open_items(self) -> list[Item]:
        ...

    # action log (append-only, powers /undo)
    def next_batch_id(self) -> str:
        ...

    def append_actions(self, entries: list[ActionLogEntry]) -> None:
        ...

    def last_batch(self) -> list[ActionLogEntry]:
        ...

    def mark_batch_undone(self, batch_id: str) -> None:
        ...

    def mark_batch_redone(self, batch_id: str) -> None:
        ...

    def has_actions_for_message(self, inbound_message_id: str) -> bool:
        ...

    def batch_for_message(self, inbound_message_id: str) -> list[ActionLogEntry]:
        ...

    # digests (so references resolve against what was actually shown)
    def save_digest(self, digest: Digest) -> None:
        ...

    def last_digest(self) -> Digest | None:
        ...

    # meta (key/value)
    def get_meta(self, key: str) -> str | None:
        ...

    def set_meta(self, key: str, value: str) -> None:
        ...

    # one inbound turn is committed or rolled back as a unit
    def transaction(self) -> ContextManager[None]:
        ...

    # durable Telegram delivery pipeline
    def enqueue_inbound(
        self, key: str, update_id: int, kind: str, payload: dict, created_at: str
    ) -> None:
        ...

    def pending_inbound(self, limit: int = 100) -> list[InboxEntry]:
        ...

    def mark_inbound_attempt(self, key: str, error: str | None = None) -> None:
        ...

    def mark_inbound_done(self, key: str, completed_at: str) -> None:
        ...

    def enqueue_outbound(
        self,
        dedupe_key: str,
        chat_id: int,
        kind: str,
        text: str,
        created_at: str,
        item_id: str | None = None,
        markup: dict | None = None,
    ) -> OutboxEntry:
        ...

    def pending_outbound(self, limit: int = 100) -> list[OutboxEntry]:
        ...

    def outbound_for_key(self, dedupe_key: str) -> OutboxEntry | None:
        ...

    def mark_outbound_attempt(self, entry_id: int, error: str | None = None) -> None:
        ...

    def mark_outbound_sent(
        self, entry_id: int, sent_at: str, telegram_message_id: int | None
    ) -> None:
        ...
