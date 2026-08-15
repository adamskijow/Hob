# SPDX-License-Identifier: MIT
"""Small helpers for Hob files that can contain private task or delivery data."""
from __future__ import annotations

import os
from pathlib import Path


def prepare_private_file(path: str | Path) -> Path:
    """Create/protect a file as owner-only before another library opens it."""
    target = Path(path).expanduser()
    parent_was_missing = not target.parent.exists()
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if parent_was_missing:
        target.parent.chmod(0o700)
    descriptor = os.open(target, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)
    return target


def protect_default_app_directory(path: str | Path) -> None:
    """Tighten Hob's owned default data directory without touching custom dirs."""
    parent = Path(path).expanduser().parent
    default = Path.home() / "Library" / "Application Support" / "Hob"
    if parent == default:
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        parent.chmod(0o700)


def protect_private_file(path: str | Path) -> None:
    """Make an existing private-data file owner-readable and owner-writable."""
    target = Path(path).expanduser()
    try:
        target.chmod(0o600)
    except FileNotFoundError:
        pass


def protect_sqlite_family(path: str | Path) -> None:
    """Protect a database and any live SQLite journal sidecars."""
    target = Path(path).expanduser()
    for candidate in (target, Path(f"{target}-wal"), Path(f"{target}-shm")):
        protect_private_file(candidate)


def write_private_text(path: str | Path, value: str) -> None:
    """Replace a text file while never creating it with ambient permissions."""
    target = prepare_private_file(path)
    descriptor = os.open(target, os.O_WRONLY | os.O_TRUNC)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            destination.write(value)
    except BaseException:
        # fdopen owns the descriptor after it succeeds. Close only if it did not.
        try:
            os.close(descriptor)
        except OSError:
            pass
        raise
