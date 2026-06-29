# SPDX-License-Identifier: MIT
"""Composition root: wire adapters into the core and run the daemon.

Every inbound message takes one path: interpret -> reconcile -> apply. Captures,
EOD reports, corrections, and queries all flow through it. MessageService and
DigestService are edge orchestrators, unit-testable with an in-memory store, a
fake clock, and a fake LLM; the daemon wiring lives in _run_daemon.
"""
from __future__ import annotations

import asyncio
import json
import logging
import signal
import sys
from dataclasses import asdict

from config import Config, ConfigError
from core.digest import render_digest, select_digest_items
from core.interpreter import MODEL_UNREACHABLE, interpret
from core.models import (
    SOURCE_CAPTURE,
    STATUS_DONE,
    STATUS_DROPPED,
    STATUS_OPEN,
    ActionLogEntry,
    Digest,
    DigestItem,
    InterpreterContext,
    Item,
    Unknown,
)
from core.planner import Mutation, QueryIntent, reconcile
from core.ports import Clock, Llm, Store
from core.undo import plan_undo
from adapters.clock import SystemClock
from adapters.llm_ollama import OllamaLlm
from adapters.scheduler import DigestScheduler
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage, TelegramAdapter

log = logging.getLogger("hob.message")

HELP = (
    "send a task to capture it. /today lists what is open. "
    "/undo reverts your last change."
)

# meta key for the single user's chat id, learned from inbound messages.
CHAT_ID_KEY = "chat_id"
# meta key holding the JSON of clarifications awaiting an answer (see core.planner
# Pending). One inbound message replaces it: resolved -> cleared, still unclear ->
# re-set.
PENDING_KEY = "pending"


def _dump(item: Item) -> str:
    return json.dumps(item.to_dict())


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
        # Learn where to send the unsolicited morning digest.
        self._store.set_meta(CHAT_ID_KEY, str(msg.chat_id))
        text = msg.text.strip()
        low = text.lower()
        if low in ("/start", "/help"):
            return HELP
        if low == "/today":
            return self._today()
        if low == "/undo":
            return self._undo()
        message_id = str(msg.message_id)
        # Idempotency backstop: if a crash redelivered this message after its
        # mutations were already applied, do not apply or reply again. Normal
        # restarts are covered by the persisted poll offset; this guards the
        # narrow window between applying and advancing it.
        if self._store.has_actions_for_message(message_id):
            return ""
        return self._interpret_and_apply(text, message_id)

    def _context(self, text: str) -> InterpreterContext:
        active = [
            {"id": i.id, "label": i.task, "due_date": i.due_date}
            for i in self._store.open_items()
        ]
        last = self._store.last_digest()
        last_items = (
            [{"id": d.id, "label": d.label} for d in last.items] if last else []
        )
        raw_pending = self._store.get_meta(PENDING_KEY)
        return InterpreterContext(
            message=text,
            today=self._clock.today().isoformat(),
            now=self._clock.now().isoformat(),
            timezone=self._timezone,
            active_items=active,
            last_digest=last_items,
            pending=json.loads(raw_pending) if raw_pending else [],
        )

    def _interpret_and_apply(self, text: str, message_id: str) -> str:
        ctx = self._context(text)
        actions = interpret(self._llm, ctx)
        # A model outage degrades to a single Unknown with this note. Don't treat
        # it as a confusing message: say so, change nothing, and leave any pending
        # clarification intact so a retry still resolves it.
        if (
            len(actions) == 1
            and isinstance(actions[0], Unknown)
            and actions[0].note == MODEL_UNREACHABLE
        ):
            log.warning("model unreachable; not applying message %s", message_id)
            return "i can't reach the model right now. give it a few seconds and resend."
        plan = reconcile(actions, ctx)
        applied = self._apply(plan.mutations, message_id)
        answers = [self._answer_query(q) for q in plan.queries]
        # Persist this turn's clarifications for the next message; "" clears any
        # that were just resolved or superseded.
        self._store.set_meta(
            PENDING_KEY,
            json.dumps([asdict(p) for p in plan.pending]) if plan.pending else "",
        )
        return self._reply(applied, plan.questions, answers)

    def _apply(
        self, mutations: list[Mutation], message_id: str
    ) -> list[tuple[str, Item]]:
        if not mutations:
            return []
        # One inbound message is one batch; the actions undo together.
        batch_id = self._store.next_batch_id()
        ts = self._clock.now().isoformat()
        applied: list[tuple[str, Item]] = []
        entries: list[ActionLogEntry] = []
        for m in mutations:
            if m.kind == "capture":
                item = Item(
                    id=self._store.next_item_id(),
                    raw_text=m.raw,
                    task=m.task,
                    due_date=m.due_date,
                    due_time=m.due_time,
                    status=STATUS_OPEN,
                    source=SOURCE_CAPTURE,
                    created_at=ts,
                    updated_at=ts,
                )
                self._store.add_item(item)
                entries.append(
                    ActionLogEntry(
                        batch_id=batch_id,
                        ts=ts,
                        action_type="capture",
                        item_id=item.id,
                        before_json=None,
                        after_json=_dump(item),
                        inbound_message_id=message_id,
                    )
                )
                applied.append(("capture", item))
                continue
            item = self._store.get_item(m.target)
            if item is None:
                continue  # vanished between reconcile and apply; skip defensively
            before = _dump(item)
            if m.kind == "complete":
                item.status = STATUS_DONE
            elif m.kind == "drop":
                item.status = STATUS_DROPPED
            elif m.kind == "reschedule":
                item.due_date = m.due_date
            item.updated_at = ts
            self._store.update_item(item)
            entries.append(
                ActionLogEntry(
                    batch_id=batch_id,
                    ts=ts,
                    action_type=m.kind,
                    item_id=item.id,
                    before_json=before,
                    after_json=_dump(item),
                    inbound_message_id=message_id,
                )
            )
            applied.append((m.kind, item))
        self._store.append_actions(entries)
        return applied

    def _undo(self) -> str:
        batch = self._store.last_batch()
        if not batch:
            return "nothing to undo"
        for op in plan_undo(batch):
            if op.kind == "delete":
                self._store.delete_item(op.item_id)
            else:
                self._store.update_item(op.item)
        self._store.mark_batch_undone(batch[0].batch_id)
        return f"undid {len(batch)} change(s)"

    def _answer_query(self, q: QueryIntent) -> str:
        today = self._clock.today().isoformat()
        if q.kind == "all":
            items, title = self._store.open_items(), "all open:"
        elif q.kind == "date":
            items = [i for i in self._store.open_items() if i.due_date == q.date]
            title = f"on {q.date}:"
        else:
            items = select_digest_items(self._store.open_items(), today)
            title = "today:"
        if not items:
            return f"{title} nothing"
        return title + "\n" + "\n".join(f"{i.id}: {i.task}" for i in items)

    def _reply(
        self, applied: list[tuple[str, Item]], questions: list[str], answers: list[str]
    ) -> str:
        parts: list[str] = []
        captures = [it for kind, it in applied if kind == "capture"]
        if len(captures) == 1:
            line = "got it"
            if captures[0].due_date:
                line += f" for {captures[0].due_date}"
            parts.append(line)
        elif len(captures) > 1:
            parts.append(f"got it ({len(captures)} items)")
        for kind, item in applied:
            if kind == "complete":
                parts.append(f"done: {item.task}")
            elif kind == "drop":
                parts.append(f"dropped: {item.task}")
            elif kind == "reschedule":
                parts.append(f"moved {item.task} to {item.due_date}")
        parts.extend(questions)
        parts.extend(answers)
        return "\n".join(parts) if parts else "ok"

    def _today(self) -> str:
        items = self._store.open_items()
        if not items:
            return "nothing on deck"
        return "\n".join(f"{i.id}: {i.task}" for i in items)


class DigestService:
    """Builds the morning digest, sends it, and records what was presented so
    later references resolve. send is an async callable(chat_id, text).
    """

    def __init__(self, store: Store, clock: Clock, send) -> None:
        self._store = store
        self._clock = clock
        self._send = send

    async def fire(self) -> None:
        today = self._clock.today().isoformat()
        ordered = select_digest_items(self._store.open_items(), today)
        text = render_digest(ordered, today)
        digest = Digest(
            sent_at=self._clock.now().isoformat(),
            items=[DigestItem(id=i.id, label=i.task) for i in ordered],
        )
        chat = self._store.get_meta(CHAT_ID_KEY)
        if chat is None:
            logging.getLogger("hob.digest").info("no chat id yet; digest not sent")
            return
        # Send first; only record the digest once it is actually delivered, so a
        # send failure retries cleanly without leaving orphan digest rows.
        await self._send(int(chat), text)
        self._store.save_digest(digest)


async def _run_daemon(cfg: Config, store: SqliteStore) -> None:
    clock = SystemClock(cfg.timezone)
    llm = OllamaLlm(cfg.model, cfg.ollama_host, keep_alive=cfg.keep_alive)
    service = MessageService(store, clock, llm, cfg.timezone)
    telegram = TelegramAdapter(store, service.handle, token=cfg.telegram_token)
    digest = DigestService(store, clock, telegram.send)
    scheduler = DigestScheduler(clock, store, digest.fire, cfg.wake_time)

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
    # python-telegram-bot's httpx logs every getUpdates at INFO with the bot
    # token in the URL. Quiet it so the token never lands in the log file.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
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
