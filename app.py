# SPDX-License-Identifier: MIT
"""Composition root: wire adapters into the core and run the daemon.

Phase 5: free text is routed through the interpreter, reconciled (dates resolved
deterministically, ambiguity asked about), and applied as captures.
MessageService is the edge orchestrator, unit-testable with an in-memory store,
a fake clock, and a fake LLM.
"""
from __future__ import annotations

import asyncio
import logging
import signal
import sys

from config import Config, ConfigError
from core.interpreter import interpret
from core.models import (
    SOURCE_CAPTURE,
    STATUS_OPEN,
    InterpreterContext,
    Item,
)
from core.planner import Mutation, Plan, reconcile
from core.ports import Clock, Llm, Store
from adapters.clock import SystemClock
from adapters.llm_ollama import OllamaLlm
from adapters.scheduler import DigestScheduler
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage, TelegramAdapter

HELP = "send a task to capture it. /today lists what is open."


class MessageService:
    """Runs every inbound message through the interpreter, reconciles the result,
    applies mutations, and produces a reply. The transport (Telegram) and the
    core stay on opposite sides of this seam.
    """

    def __init__(self, store: Store, clock: Clock, llm: Llm, timezone: str) -> None:
        self._store = store
        self._clock = clock
        self._llm = llm
        self._timezone = timezone

    def handle(self, msg: InboundMessage) -> str:
        text = msg.text.strip()
        low = text.lower()
        if low in ("/start", "/help"):
            return HELP
        if low == "/today":
            return self._today()
        return self._interpret_and_apply(text)

    def _context(self, text: str) -> InterpreterContext:
        active = [
            {"id": i.id, "label": i.task, "due_date": i.due_date}
            for i in self._store.open_items()
        ]
        last = self._store.last_digest()
        last_items = (
            [{"id": d.id, "label": d.label} for d in last.items] if last else []
        )
        return InterpreterContext(
            message=text,
            today=self._clock.today().isoformat(),
            now=self._clock.now().isoformat(),
            timezone=self._timezone,
            active_items=active,
            last_digest=last_items,
        )

    def _interpret_and_apply(self, text: str) -> str:
        ctx = self._context(text)
        actions = interpret(self._llm, ctx)
        plan = reconcile(actions, ctx)
        applied = self._apply(plan.mutations)
        return self._reply(applied, plan.questions)

    def _apply(self, mutations: list[Mutation]) -> list[Item]:
        applied: list[Item] = []
        for m in mutations:
            if m.kind == "capture":
                now = self._clock.now().isoformat()
                item = Item(
                    id=self._store.next_item_id(),
                    raw_text=m.raw,
                    task=m.task,
                    due_date=m.due_date,
                    due_time=m.due_time,
                    status=STATUS_OPEN,
                    source=SOURCE_CAPTURE,
                    created_at=now,
                    updated_at=now,
                )
                self._store.add_item(item)
                applied.append(item)
        return applied

    def _reply(self, applied: list[Item], questions: list[str]) -> str:
        parts: list[str] = []
        if len(applied) == 1:
            item = applied[0]
            line = "got it"
            if item.due_date:
                line += f" for {item.due_date}"
            parts.append(line)
        elif len(applied) > 1:
            parts.append(f"got it ({len(applied)} items)")
        parts.extend(questions)
        return "\n".join(parts) if parts else "ok"

    def _today(self) -> str:
        items = self._store.open_items()
        if not items:
            return "nothing on deck"
        return "\n".join(f"{i.id}: {i.task}" for i in items)


async def _run_daemon(cfg: Config, store: SqliteStore) -> None:
    clock = SystemClock(cfg.timezone)
    llm = OllamaLlm(cfg.model, cfg.ollama_host)
    service = MessageService(store, clock, llm, cfg.timezone)
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
