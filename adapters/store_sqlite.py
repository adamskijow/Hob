# SPDX-License-Identifier: MIT
"""SQLite Store adapter. Implements core.ports.Store.

Standard-library sqlite3, no ORM. Schema: items, action_log, digests, meta.
Filled in Phase 1.
"""
from __future__ import annotations
