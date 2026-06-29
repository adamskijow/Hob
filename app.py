# SPDX-License-Identifier: MIT
"""Composition root: wire adapters into the core and run the daemon.

Phase 2: open the store, and if a Telegram token is configured, run the
long-poll loop echoing a fixed reply. Without a token it validates config and
exits (handy on a dev box with no secrets).
"""
from __future__ import annotations

import asyncio
import logging
import signal
import sys

from config import Config, ConfigError
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage, TelegramAdapter


def echo_handler(msg: InboundMessage) -> str:
    return "got it"


async def _run_bot(cfg: Config, store: SqliteStore) -> None:
    adapter = TelegramAdapter(store, echo_handler, token=cfg.telegram_token)

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, getattr(signal, "SIGTERM", None)):
        if sig is None:
            continue
        try:
            loop.add_signal_handler(sig, adapter.stop)
        except NotImplementedError:
            # Windows dev box: add_signal_handler is unsupported; rely on
            # KeyboardInterrupt instead. The macOS target uses the handler.
            pass

    await adapter.run()


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
            asyncio.run(_run_bot(cfg, store))
        except KeyboardInterrupt:
            log.info("interrupted, shutting down")
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
