# SPDX-License-Identifier: MIT
"""Digest: the pure decision of whether today's digest is owed.

No I/O. The "owed" decision is the heart of catch-up-on-wake: an in-process
timer does not fire while the Mac is asleep, so the scheduler re-evaluates this
predicate on startup and on every tick, firing once the time is past wake time
and today's digest has not yet gone out. The builder lands in Phase 6.
"""
from __future__ import annotations

from datetime import datetime, time


def digest_owed(
    now: datetime, wake_time: str, last_digest_date: str | None
) -> bool:
    """True if today's digest should fire now.

    Owed when the local time is at or past wake_time and today's digest has not
    already been sent. last_digest_date is the ISO date of the last sent digest
    (None if never). now is timezone-aware in the configured timezone.
    """
    hh, mm = wake_time.split(":")
    if now.time() < time(int(hh), int(mm)):
        return False
    return last_digest_date != now.date().isoformat()
