# SPDX-License-Identifier: MIT
"""Undo: action-log replay / revert. Pure, operates on snapshots.

Given the entries of the most recent batch, compute the operations that walk it
back: a capture (no before snapshot) is undone by deleting the item; any other
change is undone by restoring its before snapshot. Reversed order so a batch
that touched the same item more than once unwinds correctly.

The edge applies the ops to the store and marks the batch undone; this module
decides only what to do, so it is testable with plain snapshots.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

from core.models import ActionLogEntry, Item


@dataclass
class UndoOp:
    kind: str  # "delete" | "restore"
    item_id: str | None = None  # for delete
    item: Item | None = None  # for restore


def plan_undo(batch: list[ActionLogEntry]) -> list[UndoOp]:
    ops: list[UndoOp] = []
    for entry in reversed(batch):
        if entry.before_json is None:
            # captured (created from nothing); undo by removing it
            ops.append(UndoOp(kind="delete", item_id=entry.item_id))
        else:
            before = Item.from_dict(json.loads(entry.before_json))
            ops.append(UndoOp(kind="restore", item=before))
    return ops
