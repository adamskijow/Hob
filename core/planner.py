# SPDX-License-Identifier: MIT
"""Planner: reconciled Actions plus current items -> concrete mutations.

Pure, no I/O. Produces the before/after item snapshots that the action log
records and that /undo replays. Filled in Phase 5 (capture) and Phase 7.
"""
from __future__ import annotations
