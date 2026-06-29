# SPDX-License-Identifier: MIT
"""Thin smoke tests for the telegram adapter loop logic (no network).

A fake bot stands in for telegram.Bot; the real SqliteStore (in-memory) backs
offset persistence. Async coroutines are driven with asyncio.run so no
pytest-asyncio dependency is needed.
"""
import asyncio
from types import SimpleNamespace

from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import OFFSET_KEY, TelegramAdapter


def update(update_id, text, chat_id=42, message_id=None):
    message = SimpleNamespace(
        text=text,
        message_id=message_id if message_id is not None else update_id,
        chat=SimpleNamespace(id=chat_id),
    )
    return SimpleNamespace(update_id=update_id, message=message)


class FakeBot:
    def __init__(self, batches):
        self.batches = [list(b) for b in batches]
        self.sent = []
        self.offsets_requested = []

    async def get_updates(self, offset, timeout=0, allowed_updates=None):
        self.offsets_requested.append(offset)
        return self.batches.pop(0) if self.batches else []

    async def send_message(self, chat_id, text):
        self.sent.append((chat_id, text))


def echo_handler(msg):
    return "got it"


def test_echo_and_offset_advance():
    store = SqliteStore(":memory:")
    bot = FakeBot([[update(10, "hello"), update(11, "world")]])
    adapter = TelegramAdapter(store, echo_handler, bot=bot)

    handled = asyncio.run(adapter.poll_once())

    assert handled == 2
    assert bot.sent == [(42, "got it"), (42, "got it")]
    # offset advanced past the last update
    assert store.get_meta(OFFSET_KEY) == "12"
    # first poll requested offset 0 (nothing confirmed yet)
    assert bot.offsets_requested == [0]


def test_resume_from_saved_offset():
    store = SqliteStore(":memory:")
    store.set_meta(OFFSET_KEY, "12")  # as if a prior run confirmed through 11
    bot = FakeBot([[update(12, "new one")]])
    adapter = TelegramAdapter(store, echo_handler, bot=bot)

    asyncio.run(adapter.poll_once())

    # resumed at 12, did not re-request the old backlog
    assert bot.offsets_requested == [12]
    assert store.get_meta(OFFSET_KEY) == "13"


def test_non_text_update_advances_without_reply():
    store = SqliteStore(":memory:")
    # update with no text (e.g. a photo); message present but text None
    no_text = SimpleNamespace(
        update_id=5,
        message=SimpleNamespace(text=None, message_id=5, chat=SimpleNamespace(id=1)),
    )
    bot = FakeBot([[no_text]])
    adapter = TelegramAdapter(store, echo_handler, bot=bot)

    asyncio.run(adapter.poll_once())

    assert bot.sent == []  # nothing to echo
    assert store.get_meta(OFFSET_KEY) == "6"  # but offset still advanced


def test_handler_returning_none_sends_nothing():
    store = SqliteStore(":memory:")
    bot = FakeBot([[update(1, "x")]])
    adapter = TelegramAdapter(store, lambda msg: None, bot=bot)

    asyncio.run(adapter.poll_once())

    assert bot.sent == []
    assert store.get_meta(OFFSET_KEY) == "2"
