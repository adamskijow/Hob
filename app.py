# SPDX-License-Identifier: MIT
"""Composition root: wire adapters into the core and run the daemon.

Phase 0: load and validate config, print a startup banner, exit cleanly. Later
phases turn this into the long-lived daemon (store, telegram, scheduler).
"""
from __future__ import annotations

import sys

from config import Config, ConfigError


def main(argv: list[str] | None = None) -> int:
    try:
        cfg = Config.from_env()
    except ConfigError as exc:
        print(f"hob: config error: {exc}", file=sys.stderr)
        return 2

    print("hob: starting")
    print(
        f"hob: model={cfg.model} tz={cfg.timezone} "
        f"wake={cfg.wake_time} db={cfg.db_path}"
    )
    if not cfg.telegram_enabled:
        print("hob: HOB_TELEGRAM_TOKEN not set; telegram adapter disabled")
    print("hob: phase 0 scaffold ok; nothing to run yet, exiting")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
