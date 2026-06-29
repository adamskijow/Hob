# SPDX-License-Identifier: MIT
"""Composition root: wire adapters into the core and run the daemon.

Phase 4: inbound messages are captured as items (task = raw text, no model yet);
the bot replies "got it"; /today lists open items. MessageService is the edge
orchestrator: it touches the store and clock but holds no transport concerns, so
it is unit-testable with an in-memory store and a fake clock.
"""
from __future__ import annotations

import asyncio
import logging
import signal
import sys

from config import Config, ConfigError
from core.models import SOURCE_CAPTURE, STATUS_OPEN, Item
from core.ports import Clock, Store
from adapters.clock import SystemClock
from adapters.scheduler import DigestScheduler
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage, TelegramAdapter

HELP = "send a task to capture it. /today lists what is open."


class MessageService:
    """Turns an inbound message into a store mutation and a reply."""

    def __init__(self, store: Store, clock: Clock) -> None:
        self._store = store
        self._clock = clock

    def handle(self, msg: InboundMessage) -> str:
        text = msg.text.strip()
        low = text.lower()
        if low == "/start" or low == "/help":
            return HELP
        if low == "/today":
            return self._today()
        return self._capture(text)

    def _capture(self, text: str) -> str:
        now = self._clock.now().isoformat()
        item = Item(
            id=self._store.next_item_id(),
            raw_text=text,
            task=text,
            due_date=None,
            due_time=None,
            status=STATUS_OPEN,
            source=SOURCE_CAPTURE,
            created_at=now,
            updated_at=now,
        )
        self._store.add_item(item)
        return "got it"

    def _today(self) -> str:
        items = self._store.open_items()
        if not items:
            return "nothing on deck"
        return "\n".join(f"{i.id}: {i.task}" for i in items)


async def _run_daemon(cfg: Config, store: SqliteStore) -> None:
    clock = SystemClock(cfg.timezone)
    service = MessageService(store, clock)
    telegram = TelegramAdapter(store, service.handle, token=cfg.telegram_token)

    async def fire() -> None:
        # Phase 3 placeholder; Phase 6 builds and sends the real digest.
        logging.getLogger("hob.scheduler").info("would fire digest")

    scheduler = DigestScheduler(clock, store, fire, cfg.wake_time)

    def stop_all() -> None:
        telegram.stop()
        scheduler.stop()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, getattr(signal, "SIGTERM", None)):
        if sig is None:
            continue
        try:
            loop.add_signal_handler(sig, stop_all)
        except NotImplementedError:
            # Windows dev box: add_signal_handler is unsupported; rely on
            # KeyboardInterrupt instead. The macOS target uses the handler.
            pass

    await asyncio.gather(telegram.run(), scheduler.run())


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s"
    )
    try:
        cfg = Config.from_env()
    except ConfigError as exc:
        print(f"hob: config error: {exc}", file=sys.stderr)
        return 2

    log = logging.getLogger("hob")
    log.info(
        "starting: model=%s tz=%s wake=%s db=%s",
        cfg.model,
        cfg.timezone,
        cfg.wake_time,
        cfg.db_path,
    )

    store = SqliteStore(cfg.db_path)
    try:
        if not cfg.telegram_enabled:
            log.info("HOB_TELEGRAM_TOKEN not set; nothing to run, exiting")
            return 0
        try:
            asyncio.run(_run_daemon(cfg, store))
        except KeyboardInterrupt:
            log.info("interrupted, shutting down")
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
