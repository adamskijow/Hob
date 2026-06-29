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


class OllamaLlm:
    def __init__(self, model: str, host: str, timeout: float = 120.0) -> None:
        self._model = model
        # A bounded timeout means a hung model raises rather than blocking
        # forever; the core then degrades to Unknown and asks.
        self._client = ollama.Client(host=host, timeout=timeout)

    def complete_json(self, prompt: str, schema: dict) -> dict:
        try:
            response = self._client.chat(
                model=self._model,
                messages=[{"role": "user", "content": prompt}],
                format=schema,  # structured output: response conforms to the schema
                options={"temperature": 0},  # deterministic
            )
        except Exception:
            # Surface the outage in the log; the core still degrades gracefully.
            # Without this an ollama outage is invisible and looks like the model
            # being confused.
            log.exception("ollama call failed (model=%s)", self._model)
            raise
        return json.loads(response["message"]["content"])
