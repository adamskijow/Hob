# SPDX-License-Identifier: MIT
"""Telegram adapter: explicit long-poll loop over telegram.Bot.

Inbound messages flow to an injected handler; the handler's reply (if any) flows
back out. The update offset is persisted to the store after each handled update,
so a restart resumes cleanly and old, already-confirmed messages are not
reprocessed.

We drive getUpdates ourselves rather than using the Application framework so the
offset and its persistence are fully under our control. The loop core takes an
injected bot, so it is unit-testable with a fake bot and no network.
"""
from __future__ import annotations

import asyncio
import inspect
import logging
import re
from dataclasses import dataclass
from typing import Awaitable, Callable

from core.ports import Store

log = logging.getLogger("hob.telegram")

# Presentation: the core keeps its terse lowercase voice; this capitalizes it for
# display only (stored data and tested strings are untouched).
_CAP_AFTER = re.compile(r"([.?!:]\s+)([a-z])")  # after . ? ! : and a space
_CAP_START = re.compile(r"^(\s*)([a-z])")
_ID_LINE = re.compile(r"^[a-z]+\d+:")  # an item id like "a6:" stays lowercase
_LONE_I = re.compile(r"\bi\b")  # the pronoun


def present(text: str) -> str:
    """Capitalize Hob's output for display: the start of each line and sentence,
    text after a colon, and the pronoun 'i'. A leading item id (a6:) is left
    lowercase. Presentation only."""
    out = []
    for line in text.split("\n"):
        line = _CAP_AFTER.sub(lambda m: m.group(1) + m.group(2).upper(), line)
        if not _ID_LINE.match(line):
            line = _CAP_START.sub(lambda m: m.group(1) + m.group(2).upper(), line)
        line = _LONE_I.sub("I", line)
        out.append(line)
    return "\n".join(out)

# meta key holding the next update offset to request.
OFFSET_KEY = "tg_offset"

# Handler: given an inbound message, optionally returns a reply string.
Handler = Callable[["InboundMessage"], "str | None | Awaitable[str | None]"]


@dataclass
class InboundMessage:
    text: str
    chat_id: int
    message_id: int
    update_id: int


class TelegramAdapter:
    def __init__(
        self,
        store: Store,
        handler: Handler,
        *,
        token: str | None = None,
        bot: object | None = None,
        poll_timeout: int = 30,
        error_backoff: float = 3.0,
    ) -> None:
        if bot is None and token is None:
            raise ValueError("TelegramAdapter needs either a bot or a token")
        self._store = store
        self._handler = handler
        self._token = token
        self._bot = bot
        self._poll_timeout = poll_timeout
        self._error_backoff = error_backoff
        self._stop = asyncio.Event()

    def _ensure_bot(self) -> object:
        if self._bot is None:
            import telegram  # imported lazily so tests need no network

            self._bot = telegram.Bot(self._token)
        return self._bot

    def _load_offset(self) -> int:
        raw = self._store.get_meta(OFFSET_KEY)
        return int(raw) if raw else 0

    def _save_offset(self, offset: int) -> None:
        self._store.set_meta(OFFSET_KEY, str(offset))

    def stop(self) -> None:
        self._stop.set()

    async def _dispatch(self, msg: InboundMessage) -> None:
        reply = self._handler(msg)
        if inspect.isawaitable(reply):
            reply = await reply
        if reply:
            await self._bot.send_message(chat_id=msg.chat_id, text=present(reply))

    async def _handle_update(self, update: object) -> None:
        message = getattr(update, "message", None)
        text = getattr(message, "text", None) if message is not None else None
        if message is not None and text is not None:
            msg = InboundMessage(
                text=text,
                chat_id=message.chat.id,
                message_id=message.message_id,
                update_id=update.update_id,
            )
            await self._dispatch(msg)
        # Advance past this update only after it is fully handled, so a crash
        # mid-handling reprocesses just this one, never the whole backlog.
        self._save_offset(update.update_id + 1)

    async def poll_once(self) -> int:
        """One getUpdates round; handle every update. Returns count handled."""
        offset = self._load_offset()
        updates = await self._bot.get_updates(
            offset=offset,
            timeout=self._poll_timeout,
            allowed_updates=["message"],
        )
        for update in updates:
            await self._handle_update(update)
        return len(updates)

    async def run(self) -> None:
        self._ensure_bot()
        log.info("telegram: polling from offset %d", self._load_offset())
        while not self._stop.is_set():
            try:
                await self.poll_once()
            except asyncio.CancelledError:
                raise
            except Exception:  # network blip, malformed update, etc.
                log.exception("telegram: poll error, backing off")
                await asyncio.sleep(self._error_backoff)

    async def send(self, chat_id: int, text: str) -> None:
        await self._ensure_bot().send_message(chat_id=chat_id, text=present(text))
