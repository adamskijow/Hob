# SPDX-License-Identifier: MIT
"""Thin smoke tests for the telegram adapter loop logic (no network).

A fake bot stands in for telegram.Bot; the real SqliteStore (in-memory) backs
offset persistence. Async coroutines are driven with asyncio.run so no
pytest-asyncio dependency is needed.
"""
import asyncio
from datetime import datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo

from app import MessageService
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import OFFSET_KEY, TelegramAdapter, present
from tests.fakes import FakeClock, FakeLlm


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
        self.actions = []

    async def get_updates(self, offset, timeout=0, allowed_updates=None):
        self.offsets_requested.append(offset)
        return self.batches.pop(0) if self.batches else []

    async def send_message(self, chat_id, text):
        self.sent.append((chat_id, text))

    async def send_chat_action(self, chat_id, action):
        self.actions.append((chat_id, action))


def echo_handler(msg):
    return "got it"


def test_echo_and_offset_advance():
    store = SqliteStore(":memory:")
    bot = FakeBot([[update(10, "hello"), update(11, "world")]])
    adapter = TelegramAdapter(store, echo_handler, bot=bot)

    handled = asyncio.run(adapter.poll_once())

    assert handled == 2
    assert bot.sent == [(42, "Got it"), (42, "Got it")]  # presented for display
    assert bot.actions == [(42, "typing"), (42, "typing")]
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


def test_non_text_update_gets_accessible_fallback_and_advances():
    store = SqliteStore(":memory:")
    # update with no text (e.g. a photo); message present but text None
    no_text = SimpleNamespace(
        update_id=5,
        message=SimpleNamespace(text=None, message_id=5, chat=SimpleNamespace(id=1)),
    )
    bot = FakeBot([[no_text]])
    adapter = TelegramAdapter(store, echo_handler, bot=bot)

    asyncio.run(adapter.poll_once())

    assert bot.sent == [(
        1,
        "I can read text and media captions, but not this message type yet. "
        "Send the task as text.",
    )]
    assert store.get_meta(OFFSET_KEY) == "6"  # but offset still advanced


def test_media_caption_uses_the_normal_message_path():
    store = SqliteStore(":memory:")
    captioned = SimpleNamespace(
        update_id=6,
        message=SimpleNamespace(
            text=None,
            caption="buy milk tomorrow",
            message_id=6,
            chat=SimpleNamespace(id=1, type="private"),
            from_user=SimpleNamespace(id=7),
        ),
    )
    bot = FakeBot([[captioned]])
    seen = []
    adapter = TelegramAdapter(
        store,
        lambda message: seen.append(message) or "got it",
        bot=bot,
    )

    asyncio.run(adapter.poll_once())

    assert seen[0].text == "buy milk tomorrow"
    assert seen[0].user_id == 7 and seen[0].chat_type == "private"
    assert bot.sent == [(1, "Got it")]


def test_handler_returning_none_sends_nothing():
    store = SqliteStore(":memory:")
    bot = FakeBot([[update(1, "x")]])
    adapter = TelegramAdapter(store, lambda msg: None, bot=bot)

    asyncio.run(adapter.poll_once())

    assert bot.sent == []
    assert store.get_meta(OFFSET_KEY) == "2"


def test_present_capitalizes_for_display():
    assert present("got it for 2026-06-30") == "Got it for 2026-06-30"
    assert present("today: nothing") == "Today: Nothing"
    # item id uppercased (display only); task after the colon capitalized
    assert present("on 2026-06-30:\na6: eat pizza, dance around") == (
        "On 2026-06-30:\nA6: Eat pizza, dance around"
    )
    assert present("open: a1, a2") == "Open: A1, A2"
    # quoted task labels get their first letter capitalized
    assert present('done: "review audit"') == 'Done: "Review audit"'
    assert present('moved "review sr audit" to 2026-07-03') == (
        'Moved "Review sr audit" to 2026-07-03'
    )
    # sentence starts and the pronoun "i"
    assert present("i did not catch a task there. can you rephrase?") == (
        "I did not catch a task there. Can you rephrase?"
    )
    assert present('to when should i move "x"?') == 'To when should I move "X"?'
    # slash commands after a sentence end are left alone
    assert present("send a task. /today lists what is open.") == (
        "Send a task. /today lists what is open."
    )


def test_long_messages_split_without_losing_text():
    text = "a" * 5000
    chunks = TelegramAdapter._chunks(text)
    assert len(chunks) == 2
    assert all(len(chunk) <= 4096 for chunk in chunks)
    assert "".join(chunks) == text


def test_chunks_prefer_line_boundaries():
    lines = ["x" * 1000 for _ in range(5)]
    text = "\n".join(lines)
    chunks = TelegramAdapter._chunks(text, limit=2500)
    assert len(chunks) == 3
    assert all(len(chunk) <= 2500 for chunk in chunks)


class FailOnceBot(FakeBot):
    def __init__(self, batches):
        super().__init__(batches)
        self.failures = 1

    async def send_message(self, chat_id, text, **kwargs):
        if self.failures:
            self.failures -= 1
            raise OSError("offline")
        self.sent.append((chat_id, text))
        return SimpleNamespace(message_id=77)


def _capture_service(store, llm, *, retry=True):
    return MessageService(
        store,
        FakeClock(datetime(2026, 7, 10, 9, 0, tzinfo=ZoneInfo("America/New_York"))),
        llm,
        "America/New_York",
        retry_model_outages=retry,
    )


def test_model_outage_keeps_inbound_message_until_automatic_retry():
    class Down:
        def complete_json(self, prompt, schema, temperature=0.0):
            raise OSError("model down")

    store = SqliteStore(":memory:")
    service = _capture_service(store, Down())
    bot = FakeBot([[update(20, "buy milk")], []])
    adapter = TelegramAdapter(store, service.handle, bot=bot)

    asyncio.run(adapter.poll_once())
    assert store.get_meta(OFFSET_KEY) == "21"
    assert store.queue_counts() == (1, 0, 1)
    assert store.open_items() == []
    assert bot.sent == []

    service._llm = FakeLlm(
        {"actions": [{"type": "capture", "task": "buy milk", "raw": "buy milk"}]}
    )
    asyncio.run(adapter.poll_once())
    assert store.queue_counts() == (0, 0, 0)
    assert [item.task for item in store.open_items()] == ["buy milk"]
    assert bot.sent == [(42, 'Got it: "Buy milk"')]


def test_outbox_retries_reply_without_reapplying_state():
    store = SqliteStore(":memory:")
    service = _capture_service(
        store,
        FakeLlm({"actions": [{"type": "capture", "task": "call vet", "raw": "call vet"}]}),
    )
    bot = FailOnceBot([[update(30, "call vet")], []])
    adapter = TelegramAdapter(store, service.handle, bot=bot)

    asyncio.run(adapter.poll_once())
    assert len(store.open_items()) == 1
    assert store.queue_counts() == (0, 1, 0)
    assert bot.sent == []

    asyncio.run(adapter.poll_once())
    assert len(store.open_items()) == 1
    assert store.queue_counts() == (0, 0, 0)
    assert bot.sent == [(42, 'Got it: "Call vet"')]
