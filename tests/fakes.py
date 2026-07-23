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
    """Returns canned JSON and records calls.

    First-pass responses advance once per user/model interaction. Candidate
    audit passes repeat the immediately preceding response unless a test gives
    explicit ``review_responses``. This keeps multi-turn service fixtures about
    user turns while still letting interpreter tests exercise corrections.
    """

    def __init__(
        self,
        responses: list[dict] | dict,
        review_responses: list[dict] | dict | None = None,
    ) -> None:
        self._responses = responses if isinstance(responses, list) else [responses]
        if review_responses is None:
            self._review_responses = []
        elif isinstance(review_responses, list):
            self._review_responses = review_responses
        else:
            self._review_responses = [review_responses]
        self._response_index = 0
        self._review_index = 0
        self._last_response: dict | None = None
        self.calls: list[tuple] = []

    def complete_json(self, prompt: str, schema: dict, temperature: float = 0.0) -> dict:
        self.calls.append((prompt, schema, temperature))
        if prompt.startswith(
            "Independently decide whether the user is testing"
        ):
            if self._review_responses:
                response = self._review_responses[min(
                    self._review_index, len(self._review_responses) - 1
                )]
                self._review_index += 1
                return response
            return {
                "outcome": "durable",
                "target": None,
                "budget_minutes": None,
                "budget_delta_minutes": None,
                "budget_scope": None,
                "energy": None,
                "earliest_time": None,
                "latest_time": None,
                "duration_minutes": None,
                "work_start": None,
                "work_end": None,
                "splittable": None,
                "confidence": 1.0,
            }
        if prompt.startswith("Independently audit a first-pass") or prompt.startswith(
            "Independently audit a proposed scheduling-metadata edit"
        ) or prompt.startswith(
            "Independently classify the communicative goal"
        ):
            if self._review_responses:
                response = self._review_responses[min(
                    self._review_index, len(self._review_responses) - 1
                )]
                self._review_index += 1
                return response
            if self._last_response is not None:
                return self._last_response
        if len(self._responses) == 1:
            response = self._responses[0]
        else:
            response = self._responses[self._response_index]
            self._response_index += 1
        self._last_response = response
        return response
