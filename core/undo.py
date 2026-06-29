# SPDX-License-Identifier: MIT
"""Undo: action-log replay / revert. Pure, operates on snapshots.

Reverts the most recent batch by replaying action_log before/after snapshots in
reverse. The trust anchor that makes fuzzy-language edits safe. Filled in Phase 8.
"""
from __future__ import annotations
