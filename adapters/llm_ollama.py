# SPDX-License-Identifier: MIT
"""Ollama LLM adapter. Implements core.ports.Llm.

Calls a local JSON-capable instruct model via Ollama's structured-output mode:
the action-list schema is passed as the response format, so the model returns
well-formed JSON. We do not hand-parse free text. The core validates and
reconciles the result; this adapter only transports it.
"""
from __future__ import annotations

import json
import logging

import ollama

log = logging.getLogger("hob.llm")


def _parse_keep_alive(value: str):
    """ollama wants a number (seconds; -1 = forever) or a duration string
    ("30m"). A bare int string must go as an int, not "-1", which ollama would
    try to read as a duration."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return value


class OllamaLlm:
    def __init__(
        self, model: str, host: str, timeout: float = 120.0, keep_alive: str = "-1"
    ) -> None:
        self._model = model
        # Keep the model resident by default so a quiet stretch does not cost a
        # cold reload on the next message (free on a roomy machine).
        self._keep_alive = _parse_keep_alive(keep_alive)
        # A bounded timeout means a hung model raises rather than blocking
        # forever; the core then degrades to Unknown and asks.
        self._client = ollama.Client(host=host, timeout=timeout)

    def installed_models(self) -> list[str]:
        """Names of locally pulled models. Raises if ollama is unreachable; used
        by the preflight to tell 'ollama down' from 'model not pulled'."""
        resp = self._client.list()
        models = resp.get("models", []) if isinstance(resp, dict) else getattr(resp, "models", [])
        names = []
        for m in models:
            name = m.get("model") if isinstance(m, dict) else getattr(m, "model", None)
            if name:
                names.append(name)
        return names

    def complete_json(self, prompt: str, schema: dict, temperature: float = 0.0) -> dict:
        try:
            response = self._client.chat(
                model=self._model,
                messages=[{"role": "user", "content": prompt}],
                format=schema,  # structured output: response conforms to the schema
                options={"temperature": temperature},  # 0 = deterministic
                keep_alive=self._keep_alive,
            )
        except Exception:
            # Surface the outage in the log; the core still degrades gracefully.
            # Without this an ollama outage is invisible and looks like the model
            # being confused.
            log.exception("ollama call failed (model=%s)", self._model)
            raise
        return json.loads(response["message"]["content"])
