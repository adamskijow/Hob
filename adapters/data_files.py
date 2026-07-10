# SPDX-License-Identifier: MIT
"""Verified, recoverable replacement of Hob's SQLite data file."""
from __future__ import annotations

import json
import os
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

import fcntl

from adapters.store_sqlite import SCHEMA_VERSION, SqliteStore

_REQUIRED_TABLES = {"items", "action_log", "digests", "meta"}


class DatabaseBusyError(RuntimeError):
    pass


@contextmanager
def database_lease(path: str) -> Iterator[None]:
    """Prevent two daemons or a live-data restore from owning one database."""
    database = Path(path).expanduser().resolve()
    database.parent.mkdir(parents=True, exist_ok=True)
    lock_path = Path(str(database) + ".lock")
    handle = lock_path.open("a+")
    try:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise DatabaseBusyError(
                f"database is in use: {database}; stop the Hob daemon first"
            ) from exc
        yield
    finally:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()


def _stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def validate_database(path: str) -> int:
    source = Path(path).expanduser()
    if not source.is_file():
        raise ValueError(f"database does not exist: {source}")
    conn = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    try:
        result = conn.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            raise ValueError(f"database integrity check failed: {result}")
        version = int(conn.execute("PRAGMA user_version").fetchone()[0])
        if version < 1 or version > SCHEMA_VERSION:
            raise ValueError(
                f"unsupported database schema {version}; this Hob supports 1-{SCHEMA_VERSION}"
            )
        tables = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ).fetchall()
        }
        missing = sorted(_REQUIRED_TABLES - tables)
        if missing:
            raise ValueError(f"database is missing required tables: {', '.join(missing)}")
        return version
    finally:
        conn.close()


def _safety_backup(destination: Path) -> Path | None:
    if not destination.exists() or destination.stat().st_size == 0:
        return None
    backup = destination.with_name(f"{destination.name}.before-restore-{_stamp()}.bak")
    with SqliteStore(str(destination)) as current:
        current.backup(str(backup))
    return backup


def restore_database(source: str, destination: str) -> Path | None:
    """Verify source, safety-backup current data, then atomically replace it."""
    source_path = Path(source).expanduser().resolve()
    destination_path = Path(destination).expanduser().resolve()
    if source_path == destination_path:
        raise ValueError("restore source and destination must be different files")
    validate_database(str(source_path))
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    safety = _safety_backup(destination_path)
    temporary = destination_path.with_name(
        f".{destination_path.name}.restore-{uuid.uuid4().hex}.tmp"
    )
    source_conn = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
    target_conn = sqlite3.connect(temporary)
    try:
        source_conn.backup(target_conn)
        target_conn.commit()
        result = target_conn.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            raise ValueError(f"restored copy failed verification: {result}")
    finally:
        source_conn.close()
        target_conn.close()
    try:
        for suffix in ("-wal", "-shm"):
            Path(str(destination_path) + suffix).unlink(missing_ok=True)
        os.replace(temporary, destination_path)
        with SqliteStore(str(destination_path)) as restored:
            ok, detail = restored.integrity_check()
            if not ok:
                raise ValueError(f"restored database failed verification: {detail}")
    finally:
        temporary.unlink(missing_ok=True)
    return safety


def import_export(source: str, destination: str) -> Path | None:
    """Validate a portable JSON export in isolation, then install it atomically."""
    source_path = Path(source).expanduser()
    try:
        data = json.loads(source_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"could not read export {source_path}: {exc}") from exc
    destination_path = Path(destination).expanduser().resolve()
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination_path.with_name(
        f".{destination_path.name}.import-{uuid.uuid4().hex}.tmp"
    )
    try:
        with SqliteStore(str(temporary)) as candidate:
            candidate.import_data(data)
            ok, detail = candidate.integrity_check()
            if not ok:
                raise ValueError(f"imported database failed verification: {detail}")
        return restore_database(str(temporary), str(destination_path))
    finally:
        temporary.unlink(missing_ok=True)
