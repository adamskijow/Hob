# SPDX-License-Identifier: MIT
"""Ollama LLM adapter. Implements core.ports.Llm.

Calls a local JSON-capable instruct model via Ollama's structured-output mode
(the action-list schema is passed as the response format). Returns parsed JSON;
the core validates and reconciles it. Filled in Phase 5.
"""
from __future__ import annotations
