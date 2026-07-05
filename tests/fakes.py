# SPDX-License-Identifier: MIT
"""Shared test doubles. The in-memory SqliteStore serves as the fake store; the
core needs only a fake clock and a fake LLM here.
"""
from __future__ import annotations

from datetime import date, datetime


class FakeClock:
    """Settable clock. now() must be timezone-aware in tests."""

    def __init__(self, now: datetime) -> None:
        self._now = now

    def now(self) -> datetime:
        return self._now

    def today(self) -> date:
        return self._now.date()

    def set(self, now: datetime) -> None:
        self._now = now


class FakeLlm:
    """Returns canned JSON, ignoring the prompt. Records calls for assertions."""

    def __init__(self, responses: list[dict] | dict) -> None:
        self._responses = responses if isinstance(responses, list) else [responses]
        self.calls: list[tuple] = []

    def complete_json(self, prompt: str, schema: dict, temperature: float = 0.0) -> dict:
        self.calls.append((prompt, schema, temperature))
        if len(self._responses) == 1:
            return self._responses[0]
        return self._responses[len(self.calls) - 1]
