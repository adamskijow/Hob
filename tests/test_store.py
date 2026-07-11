# SPDX-License-Identifier: MIT
from core.models import (
    STATUS_DONE,
    STATUS_OPEN,
    ActionLogEntry,
    Digest,
    DigestItem,
    Item,
    PlanRun,
    PlanSession,
)
from adapters.store_sqlite import SCHEMA_VERSION, SqliteStore


def make_item(id, task="t", status=STATUS_OPEN, created_at="2026-06-29T09:00:00"):
    return Item(
        id=id,
        raw_text=task,
        task=task,
        due_date=None,
        due_time=None,
        status=status,
        source="capture",
        created_at=created_at,
        updated_at=created_at,
    )


def mem():
    return SqliteStore(":memory:")


def test_next_item_id_monotonic():
    s = mem()
    assert s.next_item_id() == "a1"
    assert s.next_item_id() == "a2"
    assert s.next_item_id() == "a3"


def test_add_get_roundtrip():
    s = mem()
    item = make_item("a1", "call the pool guy")
    s.add_item(item)
    got = s.get_item("a1")
    assert got == item
    assert s.get_item("nope") is None


def test_update_item():
    s = mem()
    s.add_item(make_item("a1"))
    item = s.get_item("a1")
    item.status = STATUS_DONE
    item.task = "changed"
    s.update_item(item)
    assert s.get_item("a1").status == STATUS_DONE
    assert s.get_item("a1").task == "changed"


def test_open_items_filters_and_orders():
    s = mem()
    s.add_item(make_item("a1", "first", created_at="2026-06-29T08:00:00"))
    s.add_item(make_item("a2", "done", status=STATUS_DONE, created_at="2026-06-29T08:30:00"))
    s.add_item(make_item("a3", "second", created_at="2026-06-29T09:00:00"))
    open_ids = [i.id for i in s.open_items()]
    assert open_ids == ["a1", "a3"]


def test_meta_roundtrip():
    s = mem()
    assert s.get_meta("k") is None
    s.set_meta("k", "v")
    assert s.get_meta("k") == "v"
    s.set_meta("k", "v2")
    assert s.get_meta("k") == "v2"


def test_digest_roundtrip():
    s = mem()
    d = Digest(sent_at="2026-06-29T07:00:00", items=[DigestItem("a1", "x"), DigestItem("a2", "y")])
    s.save_digest(d)
    assert d.id is not None
    last = s.last_digest()
    assert last.sent_at == "2026-06-29T07:00:00"
    assert [(i.id, i.label) for i in last.items] == [("a1", "x"), ("a2", "y")]


def entry(batch, item_id, atype="capture"):
    return ActionLogEntry(
        batch_id=batch, ts="2026-06-29T10:00:00", action_type=atype, item_id=item_id
    )


def test_action_log_last_batch_and_undo():
    s = mem()
    s.append_actions([entry("b1", "a1"), entry("b1", "a2")])
    s.append_actions([entry("b2", "a3")])
    last = s.last_batch()
    assert [e.batch_id for e in last] == ["b2"]
    # undo most recent -> previous batch becomes the last
    s.mark_batch_undone("b2")
    last = s.last_batch()
    assert [e.item_id for e in last] == ["a1", "a2"]
    s.mark_batch_undone("b1")
    assert s.last_batch() == []


def test_action_log_undo_respects_interleaving():
    s = mem()
    s.append_actions([entry("b1", "a1")])
    s.append_actions([entry("b2", "a2")])
    s.mark_batch_undone("b2")
    s.append_actions([entry("b3", "a3")])
    # most recent live batch is b3, not the undone b2
    assert [e.batch_id for e in s.last_batch()] == ["b3"]


def test_persists_across_reopen(tmp_path):
    db = str(tmp_path / "hob.db")
    s = SqliteStore(db)
    assert s.next_item_id() == "a1"
    s.add_item(make_item("a1", "survive restart"))
    s.set_meta("last_digest_date", "2026-06-29")
    s.close()

    s2 = SqliteStore(db)
    assert s2.get_item("a1").task == "survive restart"
    assert s2.get_meta("last_digest_date") == "2026-06-29"
    # id counter continues, no collision after restart
    assert s2.next_item_id() == "a2"
    s2.close()


def test_plan_runs_preserve_split_sessions_adoption_and_replacement():
    s = mem()
    s.add_item(make_item("a1", "draft report"))
    first = PlanRun(
        "p1", "2026-07-11", "proposed", "plan my day", "2026-07-11T08:00:00"
    )
    s.save_plan_run(first, [
        PlanSession(
            "p1:s1", "p1", "a1", "draft report",
            "2026-07-11T09:00:00", "2026-07-11T10:00:00", 1,
        ),
        PlanSession(
            "p1:s2", "p1", "a1", "draft report",
            "2026-07-11T11:00:00", "2026-07-11T11:30:00", 2,
        ),
    ])
    before, adopted = s.adopt_plan("p1", "2026-07-11T08:05:00")
    assert before["runs"]["p1"]["status"] == "proposed"
    assert adopted["runs"]["p1"]["status"] == "active"
    assert [session.status for session in s.plan_sessions("p1")] == [
        "planned", "planned"
    ]
    assert s.adopted_plan("2026-07-11").id == "p1"

    second = PlanRun(
        "p2", "2026-07-11", "proposed", "lost an hour", "2026-07-11T08:10:00"
    )
    s.save_plan_run(second, [
        PlanSession(
            "p2:s1", "p2", "a1", "draft report",
            "2026-07-11T10:00:00", "2026-07-11T11:30:00",
        )
    ])
    replacement_before, _ = s.adopt_plan("p2", "2026-07-11T08:11:00")
    assert replacement_before["runs"]["p1"]["status"] == "active"
    assert s.get_plan_run("p1").status == "superseded"
    assert s.active_plan("2026-07-11").id == "p2"
    assert s.adopted_plan("2026-07-11").id == "p2"
    s.restore_plan_state(replacement_before)
    assert s.active_plan("2026-07-11").id == "p1"


def test_adopted_plan_keeps_completed_run_available_for_evening_review():
    s = mem()
    run = PlanRun(
        "p1",
        "2026-07-11",
        "completed",
        "plan",
        "2026-07-11T08:00:00",
        adopted_at="2026-07-11T08:05:00",
        ended_at="2026-07-11T17:00:00",
    )
    s.save_plan_run(run, [])

    assert s.active_plan("2026-07-11") is None
    assert s.adopted_plan("2026-07-11").id == "p1"


def test_plan_session_due_and_task_lifecycle_sync_are_deterministic():
    s = mem()
    task = make_item("a1", "call supplier")
    s.add_item(task)
    run = PlanRun(
        "p1", "2026-07-11", "proposed", "plan", "2026-07-11T08:00:00"
    )
    session = PlanSession(
        "p1:s1", "p1", "a1", task.task,
        "2026-07-11T09:00:00", "2026-07-11T09:30:00",
    )
    s.save_plan_run(run, [session])
    s.adopt_plan("p1", "2026-07-11T08:05:00")
    due = s.due_plan_sessions(
        "2026-07-11T08:45:00", "2026-07-11T09:00:00"
    )
    assert [entry.id for entry in due] == ["p1:s1"]
    s.mark_plan_session_notified("p1:s1", "2026-07-11T09:00:00")
    assert s.due_plan_sessions(
        "2026-07-11T08:45:00", "2026-07-11T09:01:00"
    ) == []
    s.sync_plan_sessions(task, "complete")
    assert s.plan_sessions("p1")[0].status == "done"
    assert s.get_plan_run("p1").status == "completed"
    s.sync_plan_sessions(task)
    assert s.plan_sessions("p1")[0].status == "planned"
    assert s.get_plan_run("p1").status == "active"
    s.sync_plan_sessions(task, "reschedule", "2026-07-11T09:05:00")
    assert s.plan_sessions("p1")[0].status == "canceled"
    assert s.get_plan_run("p1").status == "active"


def test_recurring_completion_keeps_a_future_occurrence_session_open():
    s = mem()
    task = make_item("a1", "daily review")
    task.repeat = "daily"
    s.add_item(task)
    for run_id, day in (("p1", "2026-07-11"), ("p2", "2026-07-12")):
        run = PlanRun(run_id, day, "proposed", "plan", f"{day}T08:00:00")
        s.save_plan_run(run, [PlanSession(
            f"{run_id}:s1", run_id, "a1", task.task,
            f"{day}T09:00:00", f"{day}T09:30:00",
        )])
        s.adopt_plan(run_id, f"{day}T08:05:00")

    s.sync_plan_sessions(task, "complete", "2026-07-11T09:20:00")

    assert s.plan_sessions("p1")[0].status == "done"
    assert s.get_plan_run("p1").status == "completed"
    assert s.plan_sessions("p2")[0].status == "planned"
    assert s.get_plan_run("p2").status == "active"


def test_stale_active_plan_expires_without_implying_task_completion():
    s = mem()
    task = make_item("a1", "unfinished task")
    s.add_item(task)
    run = PlanRun("p1", "2026-07-10", "proposed", "plan", "2026-07-10T08:00:00")
    s.save_plan_run(run, [PlanSession(
        "p1:s1", "p1", "a1", task.task,
        "2026-07-10T09:00:00", "2026-07-10T09:30:00",
    )])
    s.adopt_plan("p1", "2026-07-10T08:05:00")

    assert s.expire_plans("2026-07-11", "2026-07-11T00:01:00") == 1

    assert s.get_plan_run("p1").status == "expired"
    assert s.plan_sessions("p1")[0].status == "canceled"
    assert s.get_item("a1").status == "open"


def test_export_and_backup_include_user_data(tmp_path):
    source = str(tmp_path / "hob.db")
    backup = str(tmp_path / "backup.db")
    s = SqliteStore(source)
    s.add_item(make_item("a1", "portable task"))
    s.set_meta("wake_time", "08:00")
    s.set_meta("work_days", "mon,tue,wed,thu,fri")

    exported = s.export_data()
    assert exported["items"][0]["task"] == "portable task"
    assert exported["meta"]["wake_time"] == "08:00"
    assert exported["meta"]["work_days"] == "mon,tue,wed,thu,fri"

    s.backup(backup)
    copied = SqliteStore(backup)
    assert copied.get_meta("work_days") == "mon,tue,wed,thu,fri"
    assert copied.get_item("a1").task == "portable task"
    copied.close()
    s.close()


def test_transaction_rolls_back_every_store_change():
    s = mem()
    try:
        with s.transaction():
            item_id = s.next_item_id()
            s.add_item(make_item(item_id, "do not keep"))
            s.set_meta("pending", "question")
            raise RuntimeError("kill point")
    except RuntimeError:
        pass
    assert s.open_items() == []
    assert s.get_meta("pending") is None
    assert s.next_item_id() == "a1"


def test_released_v7_fixture_migrates_with_backup_and_data(tmp_path):
    import sqlite3
    from pathlib import Path

    db = tmp_path / "hob.db"
    fixture = Path(__file__).parent / "fixtures" / "schema_v7.sql"
    conn = sqlite3.connect(db)
    conn.executescript(fixture.read_text(encoding="utf-8"))
    conn.close()

    with SqliteStore(str(db)) as migrated:
        assert migrated.schema_version == SCHEMA_VERSION
        assert migrated.get_item("a1").note == "ask about trip"
        migrated.enqueue_inbound("telegram:1", 1, "noop", {}, "now")
        assert len(migrated.pending_inbound()) == 1

    backups = list(tmp_path.glob("hob.db.pre-v7-to-v11-*.bak"))
    assert len(backups) == 1
    old = sqlite3.connect(backups[0])
    assert old.execute("PRAGMA user_version").fetchone()[0] == 7
    assert old.execute("SELECT task FROM items WHERE id='a1'").fetchone()[0] == "call mum"
    old.close()


def test_released_v9_fixture_adds_plan_tables_without_losing_data(tmp_path):
    import sqlite3
    from pathlib import Path

    db = tmp_path / "hob.db"
    fixture = Path(__file__).parent / "fixtures" / "schema_v9.sql"
    conn = sqlite3.connect(db)
    conn.executescript(fixture.read_text(encoding="utf-8"))
    conn.close()

    with SqliteStore(str(db)) as migrated:
        item = migrated.get_item("a1")
        assert migrated.schema_version == SCHEMA_VERSION
        assert item.task == "draft release notes" and item.duration_minutes == 45
        run = PlanRun(
            "p1", "2026-07-11", "proposed", "plan", "2026-07-11T08:00:00"
        )
        migrated.save_plan_run(run, [])
        assert migrated.latest_proposed_plan().id == "p1"

        assert migrated.queue_recovery_history() == []

    assert len(list(tmp_path.glob("hob.db.pre-v9-to-v11-*.bak"))) == 1


def test_outbox_dedupe_and_delivery_state():
    s = mem()
    first = s.enqueue_outbound("digest:today", 1, "digest", "hello", "now")
    again = s.enqueue_outbound("digest:today", 1, "digest", "changed", "later")
    assert again.id == first.id
    assert len(s.pending_outbound()) == 1
    s.mark_outbound_attempt(first.id, "offline")
    assert s.pending_outbound()[0].attempts == 1
    s.mark_outbound_sent(first.id, "later", 99)
    sent = s.outbound_for_key("digest:today")
    assert sent.status == "sent"
    assert sent.telegram_message_id == 99


def test_execution_metrics_are_privacy_safe_and_track_adoption_and_nudges():
    s = mem()
    s.add_item(make_item("a1", "secret task label"))
    run = PlanRun(
        "p1", "2026-07-11", "proposed", "private constraint",
        "2026-07-11T08:00:00",
    )
    session = PlanSession(
        "p1:s1", "p1", "a1", "secret task label",
        "2026-07-11T09:00:00", "2026-07-11T09:30:00",
    )
    s.save_plan_run(run, [session])
    s.adopt_plan("p1", "2026-07-11T08:05:00")
    s.mark_plan_session_notified("p1:s1", "2026-07-11T09:00:00")
    outbound = s.enqueue_outbound(
        "plan-session:p1:s1:2026-07-11T09:00:00",
        1,
        "message",
        "private nudge text",
        "2026-07-11T09:00:00",
    )
    s.mark_outbound_sent(outbound.id, "2026-07-11T09:00:01", 7)

    metrics = s.execution_metrics()

    assert metrics == {
        "runs": {"active": 1},
        "sessions": {"planned": 1},
        "adopted_runs": 1,
        "latest_adopted_at": "2026-07-11T08:05:00",
        "notified_sessions": 1,
        "nudge_delivery": {"sent": 1},
    }
    assert "secret" not in repr(metrics) and "private" not in repr(metrics)
