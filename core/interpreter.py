# SPDX-License-Identifier: MIT
"""Interpreter: builds the model prompt, parses and validates JSON into Actions.

Filled in Phase 5 (capture) and Phase 7 (full action set). The model call is
injected via core.ports.Llm; this module performs no I/O.
"""
from __future__ import annotations
