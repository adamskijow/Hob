# SPDX-License-Identifier: MIT
"""Privacy, operator UX, and ordering guarantees for poison-queue recovery."""
from __future__ import annotations

import json
from types import SimpleNamespace

import app
from adapters.data_files import database_lease
from adapters.store_sqlite import SqliteStore


def test_inbox_quarantine_is_private_reversible_and_unblocks_order(tmp_path):
    db = tmp_path / "hob.db"
    secret = "private medical appointment"
    error = "model error copied private medical appointment"
    with SqliteStore(str(db)) as store:
        store.enqueue_inbound(
            "telegram:10", 10, "message", {"text": secret, "chat_id": 42}, "now"
        )
        store.enqueue_inbound(
            "telegram:11", 11, "message", {"text": "later"}, "later"
        )
        store.mark_inbound_attempt("telegram:10", error)

        summaries = store.queue_problem_entries()
        assert len(summaries) == 1
        assert summaries[0].ref == "telegram:10"
        assert secret not in repr(summaries) and error not in repr(summaries)
        assert store.queue_metrics()["failed_in"] == 1

        assert store.recover_queue_entry(
            "inbox", "telegram:10", "quarantine", "quarantine-time"
        )
        assert [entry.key for entry in store.pending_inbound()] == ["telegram:11"]
        assert store.queue_metrics()["quarantined_in"] == 1
        history = store.queue_recovery_history()
        assert history[0].action == "quarantine"
        assert secret not in repr(history) and error not in repr(history)

        assert store.recover_queue_entry(
            "inbox", "telegram:10", "retry", "retry-time"
        )
        retried = store.pending_inbound()[0]
        assert retried.key == "telegram:10"
        assert retried.attempts == 0 and retried.last_error is None


def test_outbox_quarantine_retains_state_and_warns_of_retry_risk(tmp_path, capsys):
    db = tmp_path / "hob.db"
    secret = "private response text"
    with SqliteStore(str(db)) as store:
        first = store.enqueue_outbound("one", 42, "reply", secret, "now")
        second = store.enqueue_outbound("two", 42, "reply", "later", "later")
        store.mark_outbound_attempt(first.id, "connection failed with private data")
        assert store.recover_queue_entry(
            "outbox", str(first.id), "quarantine", "quarantine-time"
        )
        assert [entry.id for entry in store.pending_outbound()] == [second.id]
        assert store.outbound_for_key("one").text == secret

    cfg = SimpleNamespace(db_path=str(db))
    assert app._queue_command(
        cfg, ["queue", "retry", "outbox", str(first.id)]
    ) == 0
    output = capsys.readouterr().out
    assert "can duplicate a message" in output
    assert secret not in output


def test_queue_cli_is_actionable_and_never_prints_payload_or_error(
    tmp_path, capsys
):
    db = tmp_path / "hob.db"
    secret = "salary negotiation"
    error = "trace includes salary negotiation"
    with SqliteStore(str(db)) as store:
        store.enqueue_inbound(
            "telegram:90", 90, "message", {"text": secret, "chat_id": 42}, "now"
        )
        store.mark_inbound_attempt("telegram:90", error)

    cfg = SimpleNamespace(db_path=str(db))
    assert app._queue_command(cfg, ["queue", "status"]) == 1
    output = capsys.readouterr().out
    assert "failed=1" in output and "telegram:90" in output
    assert "stop the Hob daemon" in output
    assert secret not in output and error not in output and "42" not in output

    assert app._queue_command(
        cfg, ["queue", "quarantine", "inbox", "telegram:90"]
    ) == 0
    assert "later updates may proceed" in capsys.readouterr().out
    assert app._queue_command(cfg, ["queue", "history"]) == 0
    history = capsys.readouterr().out
    assert "quarantine inbox telegram:90" in history
    assert secret not in history and error not in history


def test_queue_mutation_requires_stopped_daemon(tmp_path, capsys):
    db = tmp_path / "hob.db"
    with SqliteStore(str(db)) as store:
        store.enqueue_inbound("telegram:1", 1, "noop", {}, "now")
        store.mark_inbound_attempt("telegram:1", "poison")
    cfg = SimpleNamespace(db_path=str(db))

    with database_lease(str(db)):
        assert app._queue_command(
            cfg, ["queue", "quarantine", "inbox", "telegram:1"]
        ) == 1
    assert "stop the Hob daemon first" in capsys.readouterr().err


def test_queue_recovery_rejects_unsafe_or_irrelevant_targets():
    store = SqliteStore(":memory:")
    store.enqueue_inbound("telegram:1", 1, "noop", {}, "now")
    assert not store.recover_queue_entry(
        "inbox", "telegram:1", "quarantine", "now"
    )
    assert not store.recover_queue_entry("inbox", "missing", "retry", "now")
    try:
        store.recover_queue_entry("sideways", "1", "retry", "now")
    except ValueError as exc:
        assert "direction" in str(exc)
    else:
        raise AssertionError("invalid direction accepted")
    try:
        store.recover_queue_entry("outbox", "not-a-number", "retry", "now")
    except ValueError as exc:
        assert "numeric" in str(exc)
    else:
        raise AssertionError("invalid outbox reference accepted")


def test_backup_retains_recovery_but_portable_export_starts_fresh(tmp_path):
    source = tmp_path / "source.db"
    backup = tmp_path / "backup.db"
    secret = "private queue content"
    with SqliteStore(str(source)) as store:
        store.enqueue_inbound(
            "telegram:3", 3, "message", {"text": secret, "chat_id": 42}, "now"
        )
        store.mark_inbound_attempt("telegram:3", f"error with {secret}")
        store.recover_queue_entry(
            "inbox", "telegram:3", "quarantine", "quarantine-time"
        )
        portable = store.export_data()
        store.backup(str(backup))

    assert secret not in json.dumps(portable)
    assert "inbox" not in portable and "queue_recovery_log" not in portable
    with SqliteStore(str(backup)) as restored:
        assert restored.queue_metrics()["quarantined_in"] == 1
        assert restored.queue_recovery_history()[0].ref == "telegram:3"

    imported = tmp_path / "imported.db"
    with SqliteStore(str(imported)) as store:
        store.enqueue_inbound("telegram:9", 9, "noop", {}, "now")
        store.mark_inbound_attempt("telegram:9", "failure")
        store.recover_queue_entry(
            "inbox", "telegram:9", "quarantine", "quarantine-time"
        )
        store.import_data(portable)
        assert store.queue_metrics() == {
            "pending_in": 0,
            "pending_out": 0,
            "failed_in": 0,
            "failed_out": 0,
            "quarantined_in": 0,
            "quarantined_out": 0,
        }
        assert store.queue_recovery_history() == []
