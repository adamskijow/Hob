# SPDX-License-Identifier: MIT
"""Deterministic date resolution + ambiguity detection.

The model never does date math. For any captured or rescheduled date, the core
re-resolves the raw phrasing here, seeded with today's date and the timezone. If
resolution fails or is ambiguous, the core asks the user instead of guessing.

Filled in Phase 5. Wraps dateparser; injected today/timezone keep it testable.
"""
from __future__ import annotations
