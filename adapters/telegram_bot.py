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
import json
import logging
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Awaitable, Callable

from core.errors import RetryableMessageError
from core.models import InboxEntry
from core.ports import Store

log = logging.getLogger("hob.telegram")

TELEGRAM_TEXT_LIMIT = 4096

# python-telegram-bot's StatusUpdate filter is authoritative for real Update
# objects. This list is a compatibility fallback for injected test doubles and
# API-compatible message objects that do not inherit telegram.Update.
_SERVICE_MESSAGE_FIELDS = (
    "chat_background_set",
    "chat_owner_changed",
    "chat_owner_left",
    "chat_shared",
    "checklist_tasks_added",
    "checklist_tasks_done",
    "connected_website",
    "delete_chat_photo",
    "direct_message_price_changed",
    "forum_topic_closed",
    "forum_topic_created",
    "forum_topic_edited",
    "forum_topic_reopened",
    "general_forum_topic_hidden",
    "general_forum_topic_unhidden",
    "gift",
    "gift_upgrade_sent",
    "giveaway_completed",
    "giveaway_created",
    "group_chat_created",
    "channel_chat_created",
    "left_chat_member",
    "managed_bot_created",
    "message_auto_delete_timer_changed",
    "migrate_from_chat_id",
    "migrate_to_chat_id",
    "new_chat_members",
    "new_chat_photo",
    "new_chat_title",
    "paid_message_price_changed",
    "pinned_message",
    "poll_option_added",
    "poll_option_deleted",
    "proximity_alert_triggered",
    "refunded_payment",
    "suggested_post_approval_failed",
    "suggested_post_approved",
    "suggested_post_declined",
    "suggested_post_paid",
    "suggested_post_refunded",
    "supergroup_chat_created",
    "unique_gift",
    "users_shared",
    "video_chat_ended",
    "video_chat_participants_invited",
    "video_chat_scheduled",
    "video_chat_started",
    "web_app_data",
    "write_access_allowed",
)

# Presentation: the core keeps its terse lowercase voice; this dresses it up for
# display only (stored data, including item ids, and the tested strings are
# untouched).
_ID = re.compile(r"\ba\d+\b")  # item id like "a6"; uppercased for legibility
_CAP_AFTER = re.compile(r"([.?!:]\s+)([a-z])")  # after . ? ! : and a space
_CAP_QUOTE = re.compile(r'(")([a-z])')  # first letter inside a quoted task label
_CAP_START = re.compile(r"^(\s*)([a-z])")
_LONE_I = re.compile(r"\bi\b")  # the pronoun


def present(text: str) -> str:
    """Dress Hob's output for display: uppercase item ids (A6), capitalize the
    start of each line and sentence, text after a colon, the first letter inside
    a quoted task label, and the pronoun 'i'. Presentation only; the stored ids
    and data stay lowercase."""
    out = []
    for line in text.split("\n"):
        line = _ID.sub(lambda m: m.group(0).upper(), line)
        line = _CAP_AFTER.sub(lambda m: m.group(1) + m.group(2).upper(), line)
        line = _CAP_QUOTE.sub(lambda m: m.group(1) + m.group(2).upper(), line)
        line = _CAP_START.sub(lambda m: m.group(1) + m.group(2).upper(), line)
        line = _LONE_I.sub("I", line)
        out.append(line)
    return "\n".join(out)

# meta key holding the next update offset to request.
OFFSET_KEY = "tg_offset"


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()

# Handler: given an inbound message, optionally returns a reply string.
Handler = Callable[["InboundMessage"], "str | None | Awaitable[str | None]"]


@dataclass
class InboundMessage:
    text: str
    chat_id: int
    message_id: int
    update_id: int
    user_id: int | None = None  # Telegram user identity; chat ids are not an auth boundary
    chat_type: str | None = None  # private/group/supergroup/channel
    reply_to: int | None = None  # message id this one replies to, if any
    edited: bool = False  # True when the user edited an earlier message
    forwarded_from: str | None = None  # original sender of a forwarded message


def _forward_name(message: object) -> str | None:
    """Who a forwarded message originally came from, best effort across the
    origin shapes Telegram uses (user, hidden user, chat, channel)."""
    origin = getattr(message, "forward_origin", None)
    if origin is None:
        return None
    user = getattr(origin, "sender_user", None)
    if user is not None:
        return getattr(user, "first_name", None) or "someone"
    hidden = getattr(origin, "sender_user_name", None)
    if hidden:
        return hidden
    chat = getattr(origin, "chat", None) or getattr(origin, "sender_chat", None)
    if chat is not None:
        return getattr(chat, "title", None) or "a chat"
    return "someone"


def _is_service_update(update: object, message: object) -> bool:
    """Return whether Telegram generated this message as a status event.

    Status events such as Hob pinning its morning digest are not owner input and
    must advance the durable offset without producing a chat reply.
    """
    try:
        from telegram import Update
        from telegram.ext import filters
    except ImportError:  # pragma: no cover - runtime dependency is required
        Update = None
        filters = None
    if (
        filters is not None
        and Update is not None
        and isinstance(update, Update)
        and filters.StatusUpdate.ALL.check_update(update)
    ):
        return True
    return any(bool(getattr(message, field, None)) for field in _SERVICE_MESSAGE_FIELDS)


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
        reaction_handler=None,  # callable(message_id, [emoji]) -> reply str
        callback_handler=None,  # callable(callback_id, data, user_id, chat_id) -> reply
    ) -> None:
        if bot is None and token is None:
            raise ValueError("TelegramAdapter needs either a bot or a token")
        self._store = store
        self._handler = handler
        self._reaction_handler = reaction_handler
        self._callback_handler = callback_handler
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

    async def _dispatch(self, msg: InboundMessage, inbox_key: str) -> None:
        """Process a normalized message and commit its reply to the outbox."""
        send_action = getattr(self._bot, "send_chat_action", None)
        if send_action is not None:
            try:
                await send_action(chat_id=msg.chat_id, action="typing")
            except Exception:
                log.debug("could not send typing indicator", exc_info=True)
        reply = self._handler(msg)
        if inspect.isawaitable(reply):
            reply = await reply
        if reply:
            raw_confirm = self._store.get_meta("pending_confirm")
            markup = self._confirm_markup_data(raw_confirm) if raw_confirm else None
            self._store.enqueue_outbound(
                f"{inbox_key}:reply",
                msg.chat_id,
                "reply",
                reply,
                _utc_now(),
                markup=markup,
            )

    @staticmethod
    def _confirm_markup_data(raw_confirm: str) -> dict:
        token = ""
        try:
            data = json.loads(raw_confirm)
            token = str(data.get("id", "")) if isinstance(data, dict) else ""
        except (TypeError, ValueError):
            pass
        return {"type": "confirm", "token": token}

    @staticmethod
    def _confirm_markup(raw_confirm: str):
        import telegram

        token = TelegramAdapter._confirm_markup_data(raw_confirm)["token"]
        suffix = f":{token}" if token else ""

        return telegram.InlineKeyboardMarkup(
            [[
                telegram.InlineKeyboardButton(
                    "Yes", callback_data=f"hob:confirm:yes{suffix}"
                ),
                telegram.InlineKeyboardButton(
                    "Cancel", callback_data=f"hob:confirm:no{suffix}"
                ),
            ]]
        )

    @staticmethod
    def _stored_markup(data: dict | None):
        if not data:
            return None
        if data.get("type") == "confirm":
            return TelegramAdapter._confirm_markup(
                json.dumps({"id": data.get("token", "")})
            )
        if data.get("type") == "item" and data.get("item_id"):
            return TelegramAdapter._item_markup(str(data["item_id"]))
        return None

    @staticmethod
    def _item_markup(item_id: str):
        import telegram

        return telegram.InlineKeyboardMarkup(
            [[
                telegram.InlineKeyboardButton(
                    "Done", callback_data=f"hob:item:{item_id}:complete"
                ),
                telegram.InlineKeyboardButton(
                    "Snooze 10", callback_data=f"hob:item:{item_id}:snooze"
                ),
                telegram.InlineKeyboardButton(
                    "Drop", callback_data=f"hob:item:{item_id}:drop"
                ),
            ]]
        )

    @staticmethod
    def _chunks(text: str, limit: int = TELEGRAM_TEXT_LIMIT) -> list[str]:
        """Split long replies on line boundaries, then hard-wrap pathological lines."""
        if len(text) <= limit:
            return [text]
        chunks: list[str] = []
        current = ""
        for line in text.splitlines(keepends=True):
            while len(line) > limit:
                if current:
                    chunks.append(current.rstrip("\n"))
                    current = ""
                chunks.append(line[:limit])
                line = line[limit:]
            if current and len(current) + len(line) > limit:
                chunks.append(current.rstrip("\n"))
                current = ""
            current += line
        if current:
            chunks.append(current.rstrip("\n"))
        return [c for c in chunks if c]

    async def _send_text(self, chat_id: int, text: str, reply_markup=None) -> int | None:
        first_id = None
        for index, chunk in enumerate(self._chunks(text)):
            kwargs = {"reply_markup": reply_markup} if index == 0 and reply_markup else {}
            sent = await self._bot.send_message(chat_id=chat_id, text=chunk, **kwargs)
            if first_id is None:
                first_id = getattr(sent, "message_id", None)
        return first_id

    async def _ingest_update(self, update: object) -> None:
        """Persist a minimal update before advancing Telegram's polling offset."""
        message = getattr(update, "message", None)
        edited = False
        if message is None:
            # An edit to an earlier message: same shape, re-handled as an edit.
            message = getattr(update, "edited_message", None)
            edited = message is not None
        text = getattr(message, "text", None) if message is not None else None
        if text is None and message is not None:
            text = getattr(message, "caption", None)
        kind = "noop"
        payload: dict = {}
        if message is not None and _is_service_update(update, message):
            # Pin/unpin and other Telegram status events are not owner input.
            # Keep the durable no-op so the polling offset advances exactly as
            # it does for every other normalized update.
            pass
        elif message is not None and text is not None:
            replied = getattr(message, "reply_to_message", None)
            kind = "message"
            payload = {
                "text": text,
                "chat_id": message.chat.id,
                "message_id": message.message_id,
                "update_id": update.update_id,
                "user_id": getattr(getattr(message, "from_user", None), "id", None),
                "chat_type": getattr(message.chat, "type", None),
                "reply_to": getattr(replied, "message_id", None),
                "edited": edited,
                "forwarded_from": _forward_name(message),
            }
        elif message is not None:
            kind = "unsupported"
            payload = {
                "chat_id": message.chat.id,
                "chat_type": getattr(message.chat, "type", None),
                "user_id": getattr(getattr(message, "from_user", None), "id", None),
            }
        else:
            reaction = getattr(update, "message_reaction", None)
            if reaction is not None:
                old = {
                    getattr(value, "emoji", None)
                    for value in getattr(reaction, "old_reaction", [])
                }
                added = [
                    emoji
                    for emoji in (
                        getattr(value, "emoji", None)
                        for value in getattr(reaction, "new_reaction", [])
                    )
                    if emoji and emoji not in old
                ]
                if added:
                    kind = "reaction"
                    payload = {
                        "message_id": reaction.message_id,
                        "emojis": added,
                        "user_id": getattr(getattr(reaction, "user", None), "id", None),
                        "chat_id": reaction.chat.id,
                    }
            callback = getattr(update, "callback_query", None)
            if callback is not None:
                answer = getattr(callback, "answer", None)
                if answer is not None:
                    try:
                        await answer()
                    except Exception:
                        log.debug("could not acknowledge callback", exc_info=True)
                callback_message = getattr(callback, "message", None)
                chat = getattr(callback_message, "chat", None)
                kind = "callback"
                payload = {
                    "callback_id": str(getattr(callback, "id", "")),
                    "data": str(getattr(callback, "data", "")),
                    "user_id": getattr(getattr(callback, "from_user", None), "id", None),
                    "chat_id": getattr(chat, "id", None),
                }

        key = f"telegram:{update.update_id}"
        with self._store.transaction():
            self._store.enqueue_inbound(
                key, update.update_id, kind, payload, _utc_now()
            )
            # Once the normalized update is durable, Telegram may safely forget it.
            self._save_offset(update.update_id + 1)

    async def _process_entry(self, entry: InboxEntry) -> None:
        payload = entry.payload
        reply = None
        chat_id = payload.get("chat_id")
        if entry.kind == "message":
            await self._dispatch(InboundMessage(**payload), entry.key)
            return
        if entry.kind == "unsupported":
            reply = (
                "hob only works in a private chat with its owner."
                if payload.get("chat_type") not in {None, "private"}
                else "i can read text and media captions, but not this message "
                "type yet. send the task as text."
            )
        elif entry.kind == "reaction" and self._reaction_handler is not None:
            reply = self._reaction_handler(
                int(payload["message_id"]),
                list(payload.get("emojis", [])),
                payload.get("user_id"),
            )
        elif entry.kind == "callback" and self._callback_handler is not None:
            reply = self._callback_handler(
                str(payload.get("callback_id", "")),
                str(payload.get("data", "")),
                payload.get("user_id"),
                chat_id,
            )
        if inspect.isawaitable(reply):
            reply = await reply
        if reply and chat_id is not None:
            self._store.enqueue_outbound(
                f"{entry.key}:reply",
                int(chat_id),
                entry.kind,
                reply,
                _utc_now(),
            )

    async def process_pending(self) -> int:
        """Process durable updates in order; temporary failures remain queued."""
        completed = 0
        for entry in self._store.pending_inbound():
            try:
                with self._store.transaction():
                    await self._process_entry(entry)
                    self._store.mark_inbound_done(entry.key, _utc_now())
            except RetryableMessageError as exc:
                self._store.mark_inbound_attempt(entry.key, str(exc))
                log.warning("telegram: deferred %s: %s", entry.key, exc)
                break
            except Exception as exc:
                self._store.mark_inbound_attempt(entry.key, str(exc))
                log.exception("telegram: failed to process %s; will retry", entry.key)
                break
            completed += 1
        return completed

    async def flush_outbox(self) -> int:
        """Deliver committed replies in order; leave failures for the next loop."""
        delivered = 0
        for entry in self._store.pending_outbound():
            try:
                sent_id = await self._send_text(
                    entry.chat_id,
                    present(entry.text),
                    reply_markup=self._stored_markup(entry.markup),
                )
            except Exception as exc:
                self._store.mark_outbound_attempt(entry.id, str(exc))
                log.exception("telegram: outbox delivery %s failed; will retry", entry.id)
                break
            with self._store.transaction():
                self._store.mark_outbound_sent(entry.id, _utc_now(), sent_id)
                if entry.item_id and isinstance(sent_id, int):
                    self._store.record_sent_ref(sent_id, entry.item_id)
            delivered += 1
        return delivered

    async def poll_once(self) -> int:
        """One getUpdates round; handle every update. Returns count handled."""
        offset = self._load_offset()
        updates = await self._bot.get_updates(
            offset=offset,
            timeout=self._poll_timeout,
            allowed_updates=[
                "message", "edited_message", "message_reaction", "callback_query"
            ],
        )
        for update in updates:
            await self._ingest_update(update)
        await self.process_pending()
        await self.flush_outbox()
        return len(updates)

    async def run(self) -> None:
        self._ensure_bot()
        log.info("telegram: polling from offset %d", self._load_offset())
        while not self._stop.is_set():
            try:
                await self.process_pending()
                await self.flush_outbox()
                await self.poll_once()
            except asyncio.CancelledError:
                raise
            except Exception:  # network blip, malformed update, etc.
                log.exception("telegram: poll error, backing off")
                await asyncio.sleep(self._error_backoff)

    async def _queue_and_send(
        self,
        chat_id: int,
        text: str,
        *,
        dedupe_key: str | None = None,
        kind: str = "proactive",
        item_id: str | None = None,
        markup: dict | None = None,
    ) -> int | None:
        key = dedupe_key or f"adhoc:{uuid.uuid4()}"
        entry = self._store.enqueue_outbound(
            key, chat_id, kind, text, _utc_now(), item_id=item_id, markup=markup
        )
        await self.flush_outbox()
        current = self._store.outbound_for_key(key)
        if current is None or current.status != "sent":
            raise RuntimeError(f"Telegram delivery queued but not yet sent: {entry.id}")
        return current.telegram_message_id

    async def send(
        self, chat_id: int, text: str, *, dedupe_key: str | None = None
    ) -> int | None:
        """Send a message; returns its Telegram message id so the caller can
        associate a later reply with what this message was about."""
        self._ensure_bot()
        return await self._queue_and_send(chat_id, text, dedupe_key=dedupe_key)

    async def send_reminder(
        self,
        chat_id: int,
        text: str,
        item_id: str,
        *,
        dedupe_key: str | None = None,
    ) -> int | None:
        """Send a reminder with fast, deterministic task-action buttons."""
        self._ensure_bot()
        return await self._queue_and_send(
            chat_id,
            text,
            dedupe_key=dedupe_key,
            kind="reminder",
            item_id=item_id,
            markup={"type": "item", "item_id": item_id},
        )

    async def set_profile_photo(self, photo_path: str) -> bool:
        """Set the bot's own avatar (Bot API set_my_profile_photo). Returns
        whether it succeeded; a failure is non-fatal to the caller."""
        import telegram

        try:
            bot = self._ensure_bot()
            # Pass a file object so ptb wires the multipart attach:// upload; a
            # pre-built InputFile or a Path does not survive that path.
            with open(photo_path, "rb") as f:
                await bot.set_my_profile_photo(telegram.InputProfilePhotoStatic(photo=f))
            return True
        except Exception:
            log.exception("could not set bot profile photo")
            return False

    async def pin(self, chat_id: int, message_id: int, unpin_message_id: int | None) -> None:
        """Pin today's digest (quietly) and unpin yesterday's. Pin failures are
        cosmetic: log and move on, never break the digest."""
        bot = self._ensure_bot()
        try:
            if unpin_message_id is not None:
                await bot.unpin_chat_message(chat_id=chat_id, message_id=unpin_message_id)
        except Exception:
            log.info("unpin failed (already unpinned?); continuing")
        try:
            await bot.pin_chat_message(
                chat_id=chat_id, message_id=message_id, disable_notification=True
            )
        except Exception:
            log.exception("pin failed; digest sent unpinned")
