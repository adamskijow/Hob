# SPDX-License-Identifier: MIT
"""SQLite Store adapter. Implements core.ports.Store.

Standard-library sqlite3, no ORM. Four flat tables: items, action_log, digests,
meta. Item ids are short and monotonic (a1, a2, ...) via a counter in meta so the
interpreter can reference them. Undone batches are tracked in meta, leaving
action_log strictly insert-only.
"""
from __future__ import annotations

import json
import sqlite3
import threading

from core.models import (
    STATUS_DONE,
    STATUS_OPEN,
    ActionLogEntry,
    Digest,
    DigestItem,
    Item,
)

SCHEMA_VERSION = 5

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
    "updated_at, reminded, repeat, priority, tag"
)


class SqliteStore:
    def __init__(self, path: str) -> None:
        self._path = path
        self._lock = threading.Lock()
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
        self._conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        self._conn.commit()

    # counters --------------------------------------------------------------
    def _next_seq(self, key: str) -> int:
        with self._lock:
            row = self._conn.execute(
                "SELECT value FROM meta WHERE key = ?", (key,)
            ).fetchone()
            n = (int(row["value"]) if row else 0) + 1
            self._set_meta_locked(key, str(n))
            self._conn.commit()
            return n

    # items -----------------------------------------------------------------
    def next_item_id(self) -> str:
        return f"a{self._next_seq('item_seq')}"

    def add_item(self, item: Item) -> None:
        with self._lock:
            self._conn.execute(
                f"INSERT INTO items ({_ITEM_COLS}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
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
                ),
            )
            self._conn.commit()

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
                "repeat=?, priority=?, tag=? WHERE id=?",
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
                    item.id,
                ),
            )
            self._conn.commit()

    def delete_item(self, item_id: str) -> None:
        with self._lock:
            self._conn.execute("DELETE FROM items WHERE id = ?", (item_id,))
            self._conn.commit()

    def open_items(self) -> list[Item]:
        rows = self._conn.execute(
            f"SELECT {_ITEM_COLS} FROM items WHERE status = ? "
            "ORDER BY created_at, id",
            (STATUS_OPEN,),
        ).fetchall()
        return [self._row_to_item(r) for r in rows]

    def due_reminders(self, now_iso: str) -> list[Item]:
        """Open, timed items whose due moment has arrived and not yet reminded.
        now_iso is 'YYYY-MM-DDTHH:MM'; due is compared as the same ISO string."""
        rows = self._conn.execute(
            f"SELECT {_ITEM_COLS} FROM items WHERE status = ? "
            "AND due_date IS NOT NULL AND due_time IS NOT NULL "
            "AND (due_date || 'T' || due_time) <= ? AND reminded = 0 "
            "ORDER BY due_date, due_time",
            (STATUS_OPEN, now_iso),
        ).fetchall()
        return [self._row_to_item(r) for r in rows]

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
            self._conn.commit()

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
            self._conn.commit()

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
            self._conn.commit()

    def has_actions_for_message(self, inbound_message_id: str) -> bool:
        row = self._conn.execute(
            "SELECT 1 FROM action_log WHERE inbound_message_id = ? LIMIT 1",
            (inbound_message_id,),
        ).fetchone()
        return row is not None

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
            self._conn.commit()
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
            self._conn.commit()

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
