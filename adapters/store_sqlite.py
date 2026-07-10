# SPDX-License-Identifier: MIT
"""SQLite Store adapter. Implements core.ports.Store.

Standard-library sqlite3, no ORM. User state and Telegram delivery state share
one database so an inbound turn, its undo log, and its reply can commit together.
Item ids are short and monotonic (a1, a2, ...) via a counter in meta.
"""
from __future__ import annotations

import json
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

from core.models import (
    STATUS_DONE,
    STATUS_OPEN,
    ActionLogEntry,
    Digest,
    DigestItem,
    InboxEntry,
    Item,
    OutboxEntry,
)

SCHEMA_VERSION = 8

_DDL = """
CREATE TABLE IF NOT EXISTS items (
    id          TEXT PRIMARY KEY,
    raw_text    TEXT NOT NULL,
    task        TEXT NOT NULL,
    due_date    TEXT,
    due_time    TEXT,
    status      TEXT NOT NULL,
    source      TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS action_log (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id            TEXT NOT NULL,
    ts                  TEXT NOT NULL,
    action_type         TEXT NOT NULL,
    item_id             TEXT NOT NULL,
    before_json         TEXT,
    after_json          TEXT,
    inbound_message_id  TEXT
);
CREATE INDEX IF NOT EXISTS idx_action_log_batch ON action_log(batch_id);

CREATE TABLE IF NOT EXISTS digests (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    sent_at     TEXT NOT NULL,
    items_json  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS meta (
    key     TEXT PRIMARY KEY,
    value   TEXT NOT NULL
);
"""

_ITEM_COLS = (
    "id, raw_text, task, due_date, due_time, status, source, created_at, "
    "updated_at, reminded, repeat, priority, tag, snooze_until, note, "
    "waiting_since"
)

_DELIVERY_DDL = """
CREATE TABLE IF NOT EXISTS inbox (
    key           TEXT PRIMARY KEY,
    update_id     INTEGER NOT NULL,
    kind          TEXT NOT NULL,
    payload_json  TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'pending',
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    created_at    TEXT NOT NULL,
    completed_at  TEXT
);
CREATE INDEX IF NOT EXISTS idx_inbox_pending
    ON inbox(status, update_id);

CREATE TABLE IF NOT EXISTS outbox (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    dedupe_key           TEXT NOT NULL UNIQUE,
    chat_id              INTEGER NOT NULL,
    kind                 TEXT NOT NULL,
    text                 TEXT NOT NULL,
    item_id              TEXT,
    markup_json          TEXT,
    status               TEXT NOT NULL DEFAULT 'pending',
    attempts             INTEGER NOT NULL DEFAULT 0,
    last_error           TEXT,
    created_at           TEXT NOT NULL,
    sent_at              TEXT,
    telegram_message_id  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_outbox_pending
    ON outbox(status, id);
"""


class SqliteStore:
    def __init__(self, path: str) -> None:
        self._path = path
        self._lock = threading.RLock()
        self._transaction_depth = 0
        if path != ":memory:":
            Path(path).expanduser().parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        if path != ":memory:":
            # WAL survives a crash mid-write and keeps reads non-blocking.
            self._conn.execute("PRAGMA journal_mode = WAL")
        self._migrate()

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> "SqliteStore":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _migrate(self) -> None:
        version = self._conn.execute("PRAGMA user_version").fetchone()[0]
        if 0 < version < SCHEMA_VERSION and self._path != ":memory:":
            self._backup_before_migration(version)
        if version < 1:
            self._conn.executescript(_DDL)
            version = 1
        if version < 2:
            # intraday reminders: track whether a due-time ping has been sent.
            self._conn.execute(
                "ALTER TABLE items ADD COLUMN reminded INTEGER NOT NULL DEFAULT 0"
            )
        if version < 3:
            # recurring tasks: the repeat rule (NULL = one-off).
            self._conn.execute("ALTER TABLE items ADD COLUMN repeat TEXT")
        if version < 4:
            # priorities: high floats up the digest, low sinks.
            self._conn.execute(
                "ALTER TABLE items ADD COLUMN priority TEXT NOT NULL DEFAULT 'normal'"
            )
        if version < 5:
            # tags: the project / list a task belongs to (NULL = none).
            self._conn.execute("ALTER TABLE items ADD COLUMN tag TEXT")
        if version < 6:
            # snooze: put off a reminder ping without moving the task itself;
            # sent_refs: which item an outbound message (a reminder) was about,
            # so a Telegram reply to it can be anchored deterministically.
            self._conn.execute("ALTER TABLE items ADD COLUMN snooze_until TEXT")
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS sent_refs ("
                "tg_message_id INTEGER PRIMARY KEY, item_id TEXT NOT NULL)"
            )
        if version < 7:
            # notes: a detail stuck to a task; waiting_since: parked on someone
            # else since this date (resurfaces after a few days).
            self._conn.execute("ALTER TABLE items ADD COLUMN note TEXT")
            self._conn.execute("ALTER TABLE items ADD COLUMN waiting_since TEXT")
        if version < 8:
            # A committed inbox prevents Telegram offset advancement from losing
            # a message; an outbox prevents applied state from losing its reply.
            self._conn.executescript(_DELIVERY_DDL)
        self._conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        self._conn.commit()

    def _backup_before_migration(self, old_version: int) -> str:
        """Make a consistent, one-time safety copy before changing a live schema."""
        source = Path(self._path).expanduser()
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        destination = source.with_name(
            f"{source.name}.pre-v{old_version}-to-v{SCHEMA_VERSION}-{stamp}.bak"
        )
        target = sqlite3.connect(destination)
        try:
            self._conn.backup(target)
        finally:
            target.close()
        return str(destination)

    @contextmanager
    def transaction(self) -> Iterator[None]:
        """Commit nested store calls as one unit; roll all of them back on error."""
        with self._lock:
            outermost = self._transaction_depth == 0
            if outermost:
                self._conn.execute("BEGIN IMMEDIATE")
            self._transaction_depth += 1
            try:
                yield
            except BaseException:
                self._transaction_depth -= 1
                if outermost:
                    self._conn.rollback()
                raise
            else:
                self._transaction_depth -= 1
                if outermost:
                    self._conn.commit()

    def _commit(self) -> None:
        if self._transaction_depth == 0:
            self._conn.commit()

    # counters --------------------------------------------------------------
    def _next_seq(self, key: str) -> int:
        with self._lock:
            row = self._conn.execute(
                "SELECT value FROM meta WHERE key = ?", (key,)
            ).fetchone()
            n = (int(row["value"]) if row else 0) + 1
            self._set_meta_locked(key, str(n))
            self._commit()
            return n

    # items -----------------------------------------------------------------
    def next_item_id(self) -> str:
        return f"a{self._next_seq('item_seq')}"

    def add_item(self, item: Item) -> None:
        with self._lock:
            self._conn.execute(
                f"INSERT INTO items ({_ITEM_COLS}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    item.id,
                    item.raw_text,
                    item.task,
                    item.due_date,
                    item.due_time,
                    item.status,
                    item.source,
                    item.created_at,
                    item.updated_at,
                    int(item.reminded),
                    item.repeat,
                    item.priority,
                    item.tag,
                    item.snooze_until,
                    item.note,
                    item.waiting_since,
                ),
            )
            self._commit()

    def get_item(self, item_id: str) -> Item | None:
        row = self._conn.execute(
            f"SELECT {_ITEM_COLS} FROM items WHERE id = ?", (item_id,)
        ).fetchone()
        return self._row_to_item(row) if row else None

    def update_item(self, item: Item) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE items SET raw_text=?, task=?, due_date=?, due_time=?, "
                "status=?, source=?, created_at=?, updated_at=?, reminded=?, "
                "repeat=?, priority=?, tag=?, snooze_until=?, note=?, "
                "waiting_since=? WHERE id=?",
                (
                    item.raw_text,
                    item.task,
                    item.due_date,
                    item.due_time,
                    item.status,
                    item.source,
                    item.created_at,
                    item.updated_at,
                    int(item.reminded),
                    item.repeat,
                    item.priority,
                    item.tag,
                    item.snooze_until,
                    item.note,
                    item.waiting_since,
                    item.id,
                ),
            )
            self._commit()

    def delete_item(self, item_id: str) -> None:
        with self._lock:
            self._conn.execute("DELETE FROM items WHERE id = ?", (item_id,))
            self._commit()

    def open_items(self) -> list[Item]:
        rows = self._conn.execute(
            f"SELECT {_ITEM_COLS} FROM items WHERE status = ? "
            "ORDER BY created_at, id",
            (STATUS_OPEN,),
        ).fetchall()
        return [self._row_to_item(r) for r in rows]

    def due_reminders(
        self,
        threshold_iso: str,
        now_iso: str | None = None,
        earliest_iso: str | None = None,
    ) -> list[Item]:
        """Open, timed items owed a ping and not yet reminded. threshold_iso is
        now + the reminder lead ('YYYY-MM-DDTHH:MM'); a snoozed item ignores its
        due moment and instead fires once now_iso reaches its snooze_until."""
        now_iso = now_iso or threshold_iso
        earliest_iso = earliest_iso or "0000-00-00T00:00"
        rows = self._conn.execute(
            f"SELECT {_ITEM_COLS} FROM items WHERE status = ? "
            "AND due_date IS NOT NULL AND due_time IS NOT NULL AND reminded = 0 "
            "AND waiting_since IS NULL "  # parked on someone else: no pings
            "AND ((snooze_until IS NULL AND (due_date || 'T' || due_time) BETWEEN ? AND ?) "
            "     OR (snooze_until IS NOT NULL AND snooze_until BETWEEN ? AND ?)) "
            "ORDER BY due_date, due_time",
            (STATUS_OPEN, earliest_iso, threshold_iso, earliest_iso, now_iso),
        ).fetchall()
        return [self._row_to_item(r) for r in rows]

    def record_sent_ref(self, tg_message_id: int, item_id: str) -> None:
        """Remember which item an outbound message (a reminder) was about, so a
        Telegram reply to it can be anchored to that item."""
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO sent_refs (tg_message_id, item_id) VALUES (?, ?)",
                (tg_message_id, item_id),
            )
            self._commit()

    def ref_for(self, tg_message_id: int) -> str | None:
        row = self._conn.execute(
            "SELECT item_id FROM sent_refs WHERE tg_message_id = ?",
            (tg_message_id,),
        ).fetchone()
        return row["item_id"] if row else None

    def done_since(self, start_iso: str) -> list[Item]:
        """Completed items finished on or after start_iso (a date or datetime),
        newest first. updated_at holds the completion time."""
        rows = self._conn.execute(
            f"SELECT {_ITEM_COLS} FROM items WHERE status = ? AND updated_at >= ? "
            "ORDER BY updated_at DESC",
            (STATUS_DONE, start_iso),
        ).fetchall()
        return [self._row_to_item(r) for r in rows]

    def mark_reminded(self, item_id: str) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE items SET reminded = 1 WHERE id = ?", (item_id,)
            )
            self._commit()

    # action log ------------------------------------------------------------
    def next_batch_id(self) -> str:
        return f"b{self._next_seq('batch_seq')}"

    def append_actions(self, entries: list[ActionLogEntry]) -> None:
        if not entries:
            return
        with self._lock:
            self._conn.executemany(
                "INSERT INTO action_log "
                "(batch_id, ts, action_type, item_id, before_json, after_json, "
                "inbound_message_id) VALUES (?,?,?,?,?,?,?)",
                [
                    (
                        e.batch_id,
                        e.ts,
                        e.action_type,
                        e.item_id,
                        e.before_json,
                        e.after_json,
                        e.inbound_message_id,
                    )
                    for e in entries
                ],
            )
            self._commit()

    def last_batch(self) -> list[ActionLogEntry]:
        undone = self._undone_batches()
        rows = self._conn.execute(
            "SELECT batch_id, MAX(id) AS mx FROM action_log "
            "GROUP BY batch_id ORDER BY mx DESC"
        ).fetchall()
        for row in rows:
            if row["batch_id"] not in undone:
                return self._batch(row["batch_id"])
        return []

    def mark_batch_undone(self, batch_id: str) -> None:
        with self._lock:
            undone = self._undone_batches()
            undone.add(batch_id)
            self._set_meta_locked("undone_batches", json.dumps(sorted(undone)))
            self._commit()

    def mark_batch_redone(self, batch_id: str) -> None:
        """Remove a batch from the undone set after an edit rollback is restored."""
        with self._lock:
            undone = self._undone_batches()
            undone.discard(batch_id)
            self._set_meta_locked("undone_batches", json.dumps(sorted(undone)))
            self._commit()

    def has_actions_for_message(self, inbound_message_id: str) -> bool:
        """Whether this message's mutations are applied and still standing.
        Undone batches do not count: an edited message's old batch is undone
        first, and the edit must then be allowed to re-apply."""
        undone = self._undone_batches()
        rows = self._conn.execute(
            "SELECT DISTINCT batch_id FROM action_log WHERE inbound_message_id = ?",
            (inbound_message_id,),
        ).fetchall()
        return any(r["batch_id"] not in undone for r in rows)

    def batch_for_message(self, inbound_message_id: str) -> list[ActionLogEntry]:
        """The latest still-standing batch this inbound message produced, for
        edited-message re-interpretation. Empty if none or all undone."""
        undone = self._undone_batches()
        rows = self._conn.execute(
            "SELECT batch_id, MAX(id) AS mx FROM action_log "
            "WHERE inbound_message_id = ? GROUP BY batch_id ORDER BY mx DESC",
            (inbound_message_id,),
        ).fetchall()
        for row in rows:
            if row["batch_id"] not in undone:
                return self._batch(row["batch_id"])
        return []

    def _batch(self, batch_id: str) -> list[ActionLogEntry]:
        rows = self._conn.execute(
            "SELECT * FROM action_log WHERE batch_id = ? ORDER BY id", (batch_id,)
        ).fetchall()
        return [self._row_to_action(r) for r in rows]

    def _undone_batches(self) -> set[str]:
        row = self._conn.execute(
            "SELECT value FROM meta WHERE key = 'undone_batches'"
        ).fetchone()
        return set(json.loads(row["value"])) if row else set()

    # digests ---------------------------------------------------------------
    def save_digest(self, digest: Digest) -> None:
        with self._lock:
            items_json = json.dumps([di.to_dict() for di in digest.items])
            cur = self._conn.execute(
                "INSERT INTO digests (sent_at, items_json) VALUES (?, ?)",
                (digest.sent_at, items_json),
            )
            self._commit()
            digest.id = cur.lastrowid

    def last_digest(self) -> Digest | None:
        row = self._conn.execute(
            "SELECT id, sent_at, items_json FROM digests ORDER BY id DESC LIMIT 1"
        ).fetchone()
        if not row:
            return None
        items = [DigestItem(**d) for d in json.loads(row["items_json"])]
        return Digest(id=row["id"], sent_at=row["sent_at"], items=items)

    # meta ------------------------------------------------------------------
    def get_meta(self, key: str) -> str | None:
        row = self._conn.execute(
            "SELECT value FROM meta WHERE key = ?", (key,)
        ).fetchone()
        return row["value"] if row else None

    def set_meta(self, key: str, value: str) -> None:
        with self._lock:
            self._set_meta_locked(key, value)
            self._commit()

    # durable delivery ------------------------------------------------------
    def enqueue_inbound(
        self, key: str, update_id: int, kind: str, payload: dict, created_at: str
    ) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT OR IGNORE INTO inbox "
                "(key, update_id, kind, payload_json, created_at) VALUES (?,?,?,?,?)",
                (key, update_id, kind, json.dumps(payload), created_at),
            )
            self._commit()

    def pending_inbound(self, limit: int = 100) -> list[InboxEntry]:
        rows = self._conn.execute(
            "SELECT * FROM inbox WHERE status = 'pending' "
            "ORDER BY update_id, key LIMIT ?",
            (limit,),
        ).fetchall()
        return [self._row_to_inbox(row) for row in rows]

    def mark_inbound_attempt(self, key: str, error: str | None = None) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE inbox SET attempts = attempts + 1, last_error = ? WHERE key = ?",
                (error, key),
            )
            self._commit()

    def mark_inbound_done(self, key: str, completed_at: str) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE inbox SET status = 'done', completed_at = ?, last_error = NULL "
                "WHERE key = ?",
                (completed_at, key),
            )
            self._commit()

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
        with self._lock:
            self._conn.execute(
                "INSERT OR IGNORE INTO outbox "
                "(dedupe_key, chat_id, kind, text, item_id, markup_json, created_at) "
                "VALUES (?,?,?,?,?,?,?)",
                (
                    dedupe_key,
                    chat_id,
                    kind,
                    text,
                    item_id,
                    json.dumps(markup) if markup else None,
                    created_at,
                ),
            )
            row = self._conn.execute(
                "SELECT * FROM outbox WHERE dedupe_key = ?", (dedupe_key,)
            ).fetchone()
            self._commit()
        return self._row_to_outbox(row)

    def pending_outbound(self, limit: int = 100) -> list[OutboxEntry]:
        rows = self._conn.execute(
            "SELECT * FROM outbox WHERE status = 'pending' ORDER BY id LIMIT ?",
            (limit,),
        ).fetchall()
        return [self._row_to_outbox(row) for row in rows]

    def outbound_for_key(self, dedupe_key: str) -> OutboxEntry | None:
        row = self._conn.execute(
            "SELECT * FROM outbox WHERE dedupe_key = ?", (dedupe_key,)
        ).fetchone()
        return self._row_to_outbox(row) if row else None

    def mark_outbound_attempt(self, entry_id: int, error: str | None = None) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE id = ?",
                (error, entry_id),
            )
            self._commit()

    def mark_outbound_sent(
        self, entry_id: int, sent_at: str, telegram_message_id: int | None
    ) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE outbox SET status = 'sent', sent_at = ?, "
                "telegram_message_id = ?, last_error = NULL WHERE id = ?",
                (sent_at, telegram_message_id, entry_id),
            )
            self._commit()

    def queue_counts(self) -> tuple[int, int, int]:
        pending_in = self._conn.execute(
            "SELECT COUNT(*) FROM inbox WHERE status = 'pending'"
        ).fetchone()[0]
        pending_out = self._conn.execute(
            "SELECT COUNT(*) FROM outbox WHERE status = 'pending'"
        ).fetchone()[0]
        failed = self._conn.execute(
            "SELECT COUNT(*) FROM inbox WHERE status = 'pending' AND last_error IS NOT NULL"
        ).fetchone()[0]
        return pending_in, pending_out, failed

    def integrity_check(self) -> tuple[bool, str]:
        rows = self._conn.execute("PRAGMA integrity_check").fetchall()
        detail = "; ".join(str(row[0]) for row in rows)
        return detail == "ok", detail

    @property
    def schema_version(self) -> int:
        return int(self._conn.execute("PRAGMA user_version").fetchone()[0])

    def export_data(self) -> dict:
        """Portable JSON-ready snapshot of user data and history."""
        item_rows = self._conn.execute(
            f"SELECT {_ITEM_COLS} FROM items ORDER BY created_at, id"
        ).fetchall()
        action_rows = self._conn.execute(
            "SELECT * FROM action_log ORDER BY id"
        ).fetchall()
        digest_rows = self._conn.execute(
            "SELECT id, sent_at, items_json FROM digests ORDER BY id"
        ).fetchall()
        meta_rows = self._conn.execute(
            "SELECT key, value FROM meta ORDER BY key"
        ).fetchall()
        return {
            "schema_version": SCHEMA_VERSION,
            "items": [self._row_to_item(row).to_dict() for row in item_rows],
            "action_log": [dict(row) for row in action_rows],
            "digests": [
                {
                    "id": row["id"],
                    "sent_at": row["sent_at"],
                    "items": json.loads(row["items_json"]),
                }
                for row in digest_rows
            ],
            "meta": {row["key"]: row["value"] for row in meta_rows},
        }

    def import_data(self, data: dict) -> None:
        """Replace an empty database with a validated portable export."""
        if not isinstance(data, dict):
            raise ValueError("export must be a JSON object")
        source_version = data.get("schema_version")
        if (
            not isinstance(source_version, int)
            or source_version < 1
            or source_version > SCHEMA_VERSION
        ):
            raise ValueError(
                f"unsupported export schema {source_version!r}; this Hob supports "
                f"up to {SCHEMA_VERSION}"
            )
        items = data.get("items")
        actions = data.get("action_log")
        digests = data.get("digests")
        meta = data.get("meta")
        if not isinstance(items, list) or not isinstance(actions, list):
            raise ValueError("export is missing items or action_log")
        if not isinstance(digests, list) or not isinstance(meta, dict):
            raise ValueError("export is missing digests or meta")

        parsed_items = [Item.from_dict(item) for item in items]
        parsed_actions = [
            ActionLogEntry(
                batch_id=str(entry["batch_id"]),
                ts=str(entry["ts"]),
                action_type=str(entry["action_type"]),
                item_id=str(entry["item_id"]),
                before_json=entry.get("before_json"),
                after_json=entry.get("after_json"),
                inbound_message_id=entry.get("inbound_message_id"),
            )
            for entry in actions
        ]
        parsed_digests = [
            Digest(
                sent_at=str(entry["sent_at"]),
                items=[DigestItem(**item) for item in entry.get("items", [])],
            )
            for entry in digests
        ]
        if any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in meta.items()
        ):
            raise ValueError("export meta keys and values must be strings")

        with self.transaction():
            for table in (
                "sent_refs",
                "outbox",
                "inbox",
                "digests",
                "action_log",
                "items",
                "meta",
            ):
                self._conn.execute(f"DELETE FROM {table}")
            for item in parsed_items:
                self.add_item(item)
            self.append_actions(parsed_actions)
            for digest in parsed_digests:
                self.save_digest(digest)
            for key, value in meta.items():
                self.set_meta(key, value)

    def backup(self, destination: str) -> None:
        """Create a consistent SQLite backup, including any live WAL changes."""
        target = sqlite3.connect(destination)
        try:
            with target:
                self._conn.backup(target)
        finally:
            target.close()
        check = sqlite3.connect(destination)
        try:
            result = check.execute("PRAGMA integrity_check").fetchone()[0]
        finally:
            check.close()
        if result != "ok":
            raise sqlite3.DatabaseError(f"backup verification failed: {result}")

    def _set_meta_locked(self, key: str, value: str) -> None:
        self._conn.execute(
            "INSERT INTO meta (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )

    # helpers ---------------------------------------------------------------
    @staticmethod
    def _row_to_item(row: sqlite3.Row) -> Item:
        return Item(
            id=row["id"],
            raw_text=row["raw_text"],
            task=row["task"],
            due_date=row["due_date"],
            due_time=row["due_time"],
            status=row["status"],
            source=row["source"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            reminded=bool(row["reminded"]),
            repeat=row["repeat"],
            priority=row["priority"],
            tag=row["tag"],
            snooze_until=row["snooze_until"],
            note=row["note"],
            waiting_since=row["waiting_since"],
        )

    @staticmethod
    def _row_to_action(row: sqlite3.Row) -> ActionLogEntry:
        return ActionLogEntry(
            id=row["id"],
            batch_id=row["batch_id"],
            ts=row["ts"],
            action_type=row["action_type"],
            item_id=row["item_id"],
            before_json=row["before_json"],
            after_json=row["after_json"],
            inbound_message_id=row["inbound_message_id"],
        )

    @staticmethod
    def _row_to_inbox(row: sqlite3.Row) -> InboxEntry:
        return InboxEntry(
            key=row["key"],
            update_id=row["update_id"],
            kind=row["kind"],
            payload=json.loads(row["payload_json"]),
            status=row["status"],
            attempts=row["attempts"],
            last_error=row["last_error"],
            created_at=row["created_at"],
            completed_at=row["completed_at"],
        )

    @staticmethod
    def _row_to_outbox(row: sqlite3.Row) -> OutboxEntry:
        return OutboxEntry(
            id=row["id"],
            dedupe_key=row["dedupe_key"],
            chat_id=row["chat_id"],
            kind=row["kind"],
            text=row["text"],
            item_id=row["item_id"],
            markup=json.loads(row["markup_json"]) if row["markup_json"] else None,
            status=row["status"],
            attempts=row["attempts"],
            last_error=row["last_error"],
            created_at=row["created_at"],
            sent_at=row["sent_at"],
            telegram_message_id=row["telegram_message_id"],
        )
