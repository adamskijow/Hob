# SPDX-License-Identifier: MIT
"""Digest builder: open items plus today -> ordered digest model + rollover.

Pure, no I/O. Today's items plus anything undone that rolls forward from prior
days, in a stable order. Filled in Phase 6.
"""
from __future__ import annotations
