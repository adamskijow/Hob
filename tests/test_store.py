# SPDX-License-Identifier: MIT
from core.models import (
    STATUS_DONE,
    STATUS_OPEN,
    ActionLogEntry,
    Digest,
    DigestItem,
    Item,
)
from adapters.store_sqlite import SqliteStore


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


def test_export_and_backup_include_user_data(tmp_path):
    source = str(tmp_path / "hob.db")
    backup = str(tmp_path / "backup.db")
    s = SqliteStore(source)
    s.add_item(make_item("a1", "portable task"))
    s.set_meta("wake_time", "08:00")

    exported = s.export_data()
    assert exported["items"][0]["task"] == "portable task"
    assert exported["meta"]["wake_time"] == "08:00"

    s.backup(backup)
    copied = SqliteStore(backup)
    assert copied.get_item("a1").task == "portable task"
    copied.close()
    s.close()
