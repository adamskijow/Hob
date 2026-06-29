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


class DigestScheduler:
    def __init__(
        self,
        clock: Clock,
        store: Store,
        fire,
        wake_time: str,
        poll_interval: float = 60.0,
    ) -> None:
        self._clock = clock
        self._store = store
        self._fire = fire  # callable, sync or async, no args
        self._wake_time = wake_time
        self._poll_interval = poll_interval
        self._stop = asyncio.Event()

    def stop(self) -> None:
        self._stop.set()

    async def tick(self) -> bool:
        """Check once; fire and mark today if the digest is owed.

        A failed fire (e.g. a transient send error) is logged and left unmarked,
        so the next tick retries rather than skipping the day or crashing.
        """
        last = self._store.get_meta(LAST_DIGEST_KEY)
        if not digest_owed(self._clock.now(), self._wake_time, last):
            return False
        try:
            result = self._fire()
            if inspect.isawaitable(result):
                await result
        except Exception:
            log.exception("digest fire failed; will retry on next tick")
            return False
        self._store.set_meta(LAST_DIGEST_KEY, self._clock.today().isoformat())
        return True

    async def run(self) -> None:
        log.info("scheduler: wake_time=%s poll=%ss", self._wake_time, self._poll_interval)
        while not self._stop.is_set():
            await self.tick()
            try:
                # Sleep, but wake immediately on stop. Re-checking every poll
                # interval is what makes catch-up-on-wake work: after the Mac
                # resumes, the next tick re-evaluates and fires if owed.
                await asyncio.wait_for(self._stop.wait(), timeout=self._poll_interval)
            except asyncio.TimeoutError:
                pass
