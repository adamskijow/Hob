# SPDX-License-Identifier: MIT
import json
from datetime import datetime
from pathlib import Path

from adapters.store_sqlite import SqliteStore
from adapters.telegram_bot import InboundMessage
from app import MessageService
from core.models import Item
from tests.fakes import FakeClock, FakeLlm


ROOT = Path(__file__).parents[1]
FIXTURE = ROOT / "fixtures" / "portable" / "task-runtime-v1.json"


def test_portable_task_runtime_fixtures_match_python_reference():
    document = json.loads(FIXTURE.read_text(encoding="utf-8"))
    assert document["version"] == 1

    for case in document["cases"]:
        store = SqliteStore(":memory:")
        for task in case["initialTasks"]:
            store.add_item(_item(task))
        store.set_meta("item_seq", str(_max_sequence(case["initialTasks"])))
        clock = FakeClock(datetime.fromisoformat(case["now"]))
        llm = FakeLlm([{"actions": turn["actions"]} for turn in case["turns"]])
        service = MessageService(store, clock, llm, case["timezone"])
        task_ids = {
            task["id"]
            for task in case["initialTasks"]
        } | {
            task["id"]
            for turn in case["turns"]
            for task in turn["expected"]["tasks"]
        }

        for index, turn in enumerate(case["turns"], start=1):
            reply = service.handle(
                InboundMessage(
                    text=turn["message"],
                    chat_id=1,
                    message_id=index,
                    update_id=index,
                )
            )
            expected = turn["expected"]
            assert (
                expected["pythonReplyContains"].lower() in reply.lower()
            ), case["name"]
            actual = [store.get_item(task_id) for task_id in sorted(task_ids)]
            assert _canonical([item for item in actual if item]) == expected[
                "tasks"
            ], case["name"]


def test_portable_fixture_has_no_model_output_or_customer_data():
    document = json.loads(FIXTURE.read_text(encoding="utf-8"))
    assert 1 <= len(document["cases"]) <= 100
    for case in document["cases"]:
        assert case["timezone"] == "America/New_York"
        assert len(case["turns"]) <= 10
        for turn in case["turns"]:
            assert len(turn["message"].encode()) <= 20_000
            assert len(turn["actions"]) <= 32


def _item(data: dict) -> Item:
    return Item(
        id=data["id"],
        raw_text=data["rawText"],
        task=data["task"],
        due_date=data["dueDate"],
        due_time=data["dueTime"],
        status=data["status"],
        source="capture",
        created_at=data["createdAt"],
        updated_at=data["updatedAt"],
    )


def _max_sequence(tasks: list[dict]) -> int:
    return max(
        (int(task["id"][1:]) for task in tasks if task["id"].startswith("a")),
        default=0,
    )


def _canonical(items: list[Item]) -> list[dict]:
    return [
        {
            "id": item.id,
            "rawText": item.raw_text,
            "task": item.task,
            "dueDate": item.due_date,
            "dueTime": item.due_time,
            "status": item.status,
            "createdAt": item.created_at,
            "updatedAt": item.updated_at,
        }
        for item in sorted(items, key=lambda item: item.id)
    ]
