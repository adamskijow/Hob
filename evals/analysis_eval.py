# SPDX-License-Identifier: MIT
"""Real-model end-to-end gate for grounded explanation and what-if planning.

    HOB_MODEL=qwen2.5:14b-instruct uv run python -m evals.analysis_eval
"""
from __future__ import annotations

from datetime import date, datetime
import os
from zoneinfo import ZoneInfo

from adapters.llm_ollama import OllamaLlm
from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage
from app import MessageService
from core.models import Item


class TracingLlm:
    def __init__(self, inner) -> None:
        self._inner = inner

    def complete_json(self, prompt, schema, temperature=0.0):
        result = self._inner.complete_json(prompt, schema, temperature)
        print(f"\n[model pass] {prompt.splitlines()[0]}\n{result}")
        return result


class FixedClock:
    def __init__(self, now: datetime) -> None:
        self._now = now

    def now(self) -> datetime:
        return self._now

    def today(self) -> date:
        return self._now.date()


def _message(text: str, message_id: int) -> InboundMessage:
    return InboundMessage(
        text=text,
        chat_id=1,
        message_id=message_id,
        update_id=message_id,
    )


def main() -> int:
    model = os.environ.get("HOB_MODEL", "qwen2.5:14b-instruct")
    host = os.environ.get("HOB_OLLAMA_HOST", "http://localhost:11434")
    store = SqliteStore(":memory:")
    for item_id, label, created in (
        ("a1", "write the brief", "2026-06-29T08:00:00-04:00"),
        ("a2", "call the pool guy", "2026-06-29T08:01:00-04:00"),
    ):
        store.add_item(
            Item(
                id=item_id,
                raw_text=label,
                task=label,
                due_date=None,
                due_time=None,
                status="open",
                source="capture",
                created_at=created,
                updated_at=created,
                duration_minutes=60,
            )
        )
    llm = OllamaLlm(model, host)
    if os.environ.get("HOB_EVAL_TRACE"):
        llm = TracingLlm(llm)
    service = MessageService(
        store,
        FixedClock(
            datetime(
                2026,
                6,
                29,
                9,
                0,
                tzinfo=ZoneInfo("America/New_York"),
            )
        ),
        llm,
        "America/New_York",
        work_start="09:00",
        work_end="10:00",
        breaks=(),
    )
    before = [item.to_dict() for item in store.open_items()]
    plan = service.handle(_message("plan my day", 1))
    explanation = service.handle(
        _message(
            "why didn't the pool call fit and what would need to change?",
            2,
        )
    )
    hypothetical = service.handle(
        _message(
            "what if the pool call only took 30 minutes and I could work until 10:30?",
            3,
        )
    )

    checks = [
        ("plan exposes the deferred task", "call the pool guy" in plan and "not placed" in plan),
        (
            "explanation is grounded and mutation-free",
            '"call the pool guy" was not placed' in explanation
            and "nothing changed" in explanation,
        ),
        (
            "what-if produces a temporary proposal",
            "what-if plan" in hypothetical
            and "10:00–10:30 call the pool guy" in hypothetical
            and "temporary assumptions only" in hypothetical,
        ),
        (
            "durable task state is unchanged",
            [item.to_dict() for item in store.open_items()] == before
            and store.get_item("a2").duration_minutes == 60,
        ),
    ]
    print(f"analysis eval | model={model}")
    for description, passed in checks:
        print(f"  [{'PASS' if passed else 'FAIL'}] {description}")
    if not all(passed for _, passed in checks):
        print("\n--- plan ---\n" + plan)
        print("\n--- explanation ---\n" + explanation)
        print("\n--- hypothetical ---\n" + hypothetical)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
