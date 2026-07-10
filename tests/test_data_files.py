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
        store.add_item(make_item("a1", "portable task"))
        export.write_text(json.dumps(store.export_data()), encoding="utf-8")

    replacement = tmp_path / "replacement.db"
    import_export(str(export), str(replacement))
    with SqliteStore(str(replacement)) as store:
        assert store.get_item("a1").task == "portable task"

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
