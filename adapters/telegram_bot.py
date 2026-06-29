# SPDX-License-Identifier: MIT
"""Telegram adapter: python-telegram-bot wiring (async, long-polling).

Inbound messages flow into the core; outbound replies flow back out. Resumes
from the saved update offset after a restart so old messages are not
reprocessed. Filled in Phase 2.
"""
from __future__ import annotations
