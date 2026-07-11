# SPDX-License-Identifier: MIT
import json

import pytest

from adapters.data_files import (
    DatabaseBusyError,
    database_lease,
    import_export,
    restore_database,
)
from adapters.store_sqlite import SqliteStore
from core.models import PlanRun, PlanSession, RecurrenceRule
from tests.test_store import make_item


def test_verified_restore_safety_backs_up_current_database(tmp_path):
    current = tmp_path / "current.db"
    source = tmp_path / "source.db"
    with SqliteStore(str(current)) as store:
        store.add_item(make_item("a1", "old task"))
    with SqliteStore(str(source)) as store:
        store.add_item(make_item("a1", "restored task"))

    safety = restore_database(str(source), str(current))

    assert safety is not None and safety.exists()
    with SqliteStore(str(current)) as restored:
        assert restored.get_item("a1").task == "restored task"
    with SqliteStore(str(safety)) as previous:
        assert previous.get_item("a1").task == "old task"


def test_import_export_is_validated_and_atomic(tmp_path):
    current = tmp_path / "current.db"
    export = tmp_path / "hob.json"
    with SqliteStore(str(current)) as store:
        portable = make_item("a1", "portable task")
        portable.deadline_date = "2026-07-10"
        portable.duration_minutes = 60
        portable.depends_on = ["a9"]
        portable.reminder_offsets = [30, 5]
        portable.recurrence = RecurrenceRule(
            frequency="week", weekdays=["fri"], anchor_date="2026-07-03"
        )
        store.add_item(portable)
        export.write_text(json.dumps(store.export_data()), encoding="utf-8")

    replacement = tmp_path / "replacement.db"
    import_export(str(export), str(replacement))
    with SqliteStore(str(replacement)) as store:
        imported = store.get_item("a1")
        assert imported.task == "portable task"
        assert imported.deadline_date == "2026-07-10"
        assert imported.duration_minutes == 60
        assert imported.depends_on == ["a9"]
        assert imported.reminder_offsets == [30, 5]
        assert imported.recurrence.weekdays == ["fri"]

    broken = tmp_path / "broken.json"
    broken.write_text('{"schema_version": 999}', encoding="utf-8")
    with pytest.raises(ValueError):
        import_export(str(broken), str(replacement))
    with SqliteStore(str(replacement)) as store:
        assert store.get_item("a1").task == "portable task"


def test_database_lease_rejects_second_daemon_or_live_restore(tmp_path):
    db = str(tmp_path / "hob.db")
    with database_lease(db):
        with pytest.raises(DatabaseBusyError):
            with database_lease(db):
                pass


def test_portable_export_preserves_adopted_plan_sessions(tmp_path):
    source = tmp_path / "source.db"
    export = tmp_path / "hob.json"
    replacement = tmp_path / "replacement.db"
    with SqliteStore(str(source)) as store:
        task = make_item("a1", "portable planned task")
        store.add_item(task)
        run = PlanRun(
            "p1", "2026-07-11", "proposed", "plan", "2026-07-11T08:00:00"
        )
        store.save_plan_run(run, [PlanSession(
            "p1:s1", "p1", "a1", task.task,
            "2026-07-11T09:00:00", "2026-07-11T09:30:00",
        )])
        store.adopt_plan("p1", "2026-07-11T08:05:00")
        export.write_text(json.dumps(store.export_data()), encoding="utf-8")

    import_export(str(export), str(replacement))

    with SqliteStore(str(replacement)) as restored:
        assert restored.active_plan("2026-07-11").id == "p1"
        sessions = restored.plan_sessions("p1")
        assert len(sessions) == 1 and sessions[0].item_id == "a1"
        assert sessions[0].status == "planned"

    broken = json.loads(export.read_text(encoding="utf-8"))
    broken["plan_sessions"][0]["item_id"] = "invented"
    export.write_text(json.dumps(broken), encoding="utf-8")
    with pytest.raises(ValueError, match="unknown reference"):
        import_export(str(export), str(replacement))
    with SqliteStore(str(replacement)) as unchanged:
        assert unchanged.active_plan("2026-07-11").id == "p1"
