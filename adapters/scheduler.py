# SPDX-License-Identifier: MIT
"""Scheduler adapter: in-process morning-digest timer + catch-up-on-wake.

An in-process timer does not fire while the Mac is asleep, so this does not rely
on the timer alone. Each tick re-evaluates core.digest.digest_owed against the
injected clock and the last_digest_date in the store. If owed, it calls the
injected fire callback and marks today, so the digest fires exactly once per day
even if the Mac was asleep at wake time.

The fire callback is what actually delivers the digest (Phase 6); in Phase 3 it
just logs. The timing decision lives in the pure core; this is only the loop.
"""
from __future__ import annotations

import asyncio
import inspect
import logging

from core.digest import digest_owed
from core.ports import Clock, Store

log = logging.getLogger("hob.scheduler")

# meta key holding the ISO date of the last sent digest.
LAST_DIGEST_KEY = "last_digest_date"
# meta key holding a user-set wake time (HH:MM); overrides the configured default
# so an in-chat "send the digest at 8" takes effect without a restart. Must match
# app.WAKE_KEY.
WAKE_TIME_KEY = "wake_time"


class DigestScheduler:
    def __init__(
        self,
        clock: Clock,
        store: Store,
        fire,
        wake_time: str,
        poll_interval: float = 60.0,
        remind=None,
    ) -> None:
        self._clock = clock
        self._store = store
        self._fire = fire  # callable, sync or async, no args
        self._default_wake = wake_time  # config fallback; meta override wins
        self._poll_interval = poll_interval
        self._remind = remind  # optional callable, checked every tick
        self._stop = asyncio.Event()

    def _wake_time(self) -> str:
        """The live wake time: the user's in-chat setting if any, else the
        configured default. Read each tick so a change takes effect at once."""
        return self._store.get_meta(WAKE_TIME_KEY) or self._default_wake

    def stop(self) -> None:
        self._stop.set()

    async def _check_reminders(self) -> None:
        """Fire due intraday reminders. Isolated so a failure does not affect the
        digest tick."""
        if self._remind is None:
            return
        try:
            result = self._remind()
            if inspect.isawaitable(result):
                await result
        except Exception:
            log.exception("reminder check failed; will retry next tick")

    async def tick(self) -> bool:
        """Check once; fire and mark today if the digest is owed.

        A failed fire (e.g. a transient send error) is logged and left unmarked,
        so the next tick retries rather than skipping the day or crashing.
        """
        last = self._store.get_meta(LAST_DIGEST_KEY)
        if not digest_owed(self._clock.now(), self._wake_time(), last):
            return False
        try:
            result = self._fire()
            if inspect.isawaitable(result):
                result = await result
        except Exception:
            log.exception("digest fire failed; will retry on next tick")
            return False
        if result is False:
            # fire chose not to send (e.g. no chat id yet); leave the day
            # unmarked so a later tick retries once it can actually send.
            return False
        self._store.set_meta(LAST_DIGEST_KEY, self._clock.today().isoformat())
        return True

    async def run(self) -> None:
        log.info("scheduler: wake_time=%s poll=%ss", self._wake_time(), self._poll_interval)
        while not self._stop.is_set():
            await self._check_reminders()
            await self.tick()
            try:
                # Sleep, but wake immediately on stop. Re-checking every poll
                # interval is what makes catch-up-on-wake work: after the Mac
                # resumes, the next tick re-evaluates and fires if owed.
                await asyncio.wait_for(self._stop.wait(), timeout=self._poll_interval)
            except asyncio.TimeoutError:
                pass
