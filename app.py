# SPDX-License-Identifier: MIT
"""Composition root: wire adapters into the core and run the daemon.

Phase 3: run the telegram echo loop and the morning-digest scheduler together.
The scheduler's fire callback is a placeholder until Phase 6 builds the digest.
"""
from __future__ import annotations

import asyncio
import logging
import signal
import sys

from config import Config, ConfigError
from adapters.clock import SystemClock
from adapters.scheduler import DigestScheduler
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage, TelegramAdapter


def echo_handler(msg: InboundMessage) -> str:
    return "got it"


async def _run_daemon(cfg: Config, store: SqliteStore) -> None:
    clock = SystemClock(cfg.timezone)
    telegram = TelegramAdapter(store, echo_handler, token=cfg.telegram_token)

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
