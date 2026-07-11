# SPDX-License-Identifier: MIT
import plistlib
import subprocess
from pathlib import Path

import pytest

from adapters.launchd import (
    LaunchdError,
    install_launch_agent,
    installed_definition,
    launch_agent_payload,
    service_paths,
    service_status,
    uninstall_launch_agent,
)
from config import Config
from adapters.store_sqlite import SqliteStore


def config(tmp_path: Path) -> Config:
    return Config.from_env({
        "HOME": str(tmp_path),
        "HOB_TELEGRAM_TOKEN": "private-token-must-never-be-in-plist",
        "HOB_ALLOWED_TELEGRAM_USER_ID": "12345",
        "HOB_TIMEZONE": "America/Los_Angeles",
        "HOB_DB_PATH": str(tmp_path / "Application Support" / "hob.db"),
    })


def completed(argv, code=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(argv, code, stdout, stderr)


def test_launch_agent_uses_exact_paths_and_never_persists_secret(tmp_path):
    cfg = config(tmp_path)
    root = tmp_path / "checkout & daily"
    uv = tmp_path / "tools" / "uv"

    payload = launch_agent_payload(
        cfg,
        root=root,
        uv_path=uv,
        home=tmp_path,
        environ={"HOB_TIMEZONE": "America/Los_Angeles"},
    )
    rendered = plistlib.dumps(payload).decode()

    assert payload["ProgramArguments"] == [
        str(uv), "run", "--frozen", "--no-sync", "--directory", str(root),
        "python", "app.py",
    ]
    assert payload["WorkingDirectory"] == str(root)
    assert payload["EnvironmentVariables"]["HOB_ALLOWED_TELEGRAM_USER_ID"] == "12345"
    assert payload["EnvironmentVariables"]["HOB_MODEL"] == "qwen2.5:14b-instruct"
    assert payload["EnvironmentVariables"]["HOB_TIMEZONE"] == "America/Los_Angeles"
    assert "private-token" not in rendered and "HOB_TELEGRAM_TOKEN" not in rendered
    assert payload["ThrottleInterval"] == 30


def test_system_timezone_is_not_frozen_into_launch_agent(tmp_path):
    payload = launch_agent_payload(
        config(tmp_path),
        root=tmp_path,
        uv_path=tmp_path / "uv",
        home=tmp_path,
        environ={},
    )

    assert "HOB_TIMEZONE" not in payload["EnvironmentVariables"]


def test_installed_definition_reports_runtime_and_secret_violation(tmp_path):
    paths = service_paths(tmp_path)
    paths.plist.parent.mkdir(parents=True)
    paths.plist.write_bytes(plistlib.dumps({
        "WorkingDirectory": "/released/hob",
        "EnvironmentVariables": {
            "HOB_DB_PATH": "/owner/hob.db",
            "HOB_MODEL": "qwen2.5:7b-instruct",
            "HOB_TELEGRAM_TOKEN": "unsafe-hand-edit",
        },
    }))

    installed = installed_definition(paths)

    assert installed.checkout == "/released/hob"
    assert installed.database == "/owner/hob.db"
    assert installed.model == "qwen2.5:7b-instruct"
    assert installed.contains_token


def test_update_backs_up_definition_and_bootstraps_new_agent(tmp_path):
    paths = service_paths(tmp_path)
    paths.plist.parent.mkdir(parents=True)
    old = plistlib.dumps({"Label": "old"})
    paths.plist.write_bytes(old)
    calls = []
    backed_up = []

    def run(argv, **kwargs):
        calls.append(argv)
        return completed(argv)

    updated = install_launch_agent(
        {"Label": "com.local.hob"},
        paths,
        uid=501,
        before_replace=lambda: backed_up.append(True),
        run=run,
    )

    assert updated and backed_up == [True]
    assert plistlib.loads(paths.plist.read_bytes())["Label"] == "com.local.hob"
    assert paths.previous_plist.read_bytes() == old
    assert any("bootout" in call for call in calls)
    assert any("bootstrap" in call for call in calls)


def test_service_status_uses_one_top_level_value_per_field():
    output = """
state = running
pid = 42
last exit code = 0
state = active
state = active
"""

    loaded, detail = service_status(
        uid=501,
        run=lambda argv, **kwargs: completed(argv, stdout=output),
    )

    assert loaded
    assert detail == "state = running; pid = 42; last exit code = 0"


def test_failed_bootstrap_restores_prior_definition(tmp_path):
    paths = service_paths(tmp_path)
    paths.plist.parent.mkdir(parents=True)
    old = plistlib.dumps({"Label": "old"})
    paths.plist.write_bytes(old)
    bootstraps = 0

    def run(argv, **kwargs):
        nonlocal bootstraps
        if "bootstrap" in argv:
            bootstraps += 1
            if bootstraps == 1:
                return completed(argv, 5, stderr="new agent rejected")
        return completed(argv)

    with pytest.raises(LaunchdError, match="new agent rejected"):
        install_launch_agent(
            {"Label": "com.local.hob"}, paths, uid=501, run=run
        )

    assert paths.plist.read_bytes() == old
    assert bootstraps == 2


def test_failed_database_callback_reloads_prior_agent(tmp_path):
    paths = service_paths(tmp_path)
    paths.plist.parent.mkdir(parents=True)
    old = plistlib.dumps({"Label": "old"})
    paths.plist.write_bytes(old)
    calls = []

    def run(argv, **kwargs):
        calls.append(argv)
        return completed(argv)

    with pytest.raises(OSError, match="backup failed"):
        install_launch_agent(
            {"Label": "com.local.hob"},
            paths,
            uid=501,
            before_replace=lambda: (_ for _ in ()).throw(OSError("backup failed")),
            run=run,
        )

    assert paths.plist.read_bytes() == old
    assert sum("bootstrap" in call for call in calls) == 1


def test_uninstall_removes_only_service_definition(tmp_path):
    paths = service_paths(tmp_path)
    paths.plist.parent.mkdir(parents=True)
    paths.data_dir.mkdir(parents=True)
    paths.plist.write_text("service")
    data = paths.data_dir / "hob.db"
    data.write_text("owner data")

    removed = uninstall_launch_agent(
        paths, uid=501, run=lambda argv, **kwargs: completed(argv)
    )

    assert removed and not paths.plist.exists()
    assert paths.uninstalled_plist.read_text() == "service"
    assert data.read_text() == "owner data"


def test_service_install_takes_verified_database_backup_after_stop(
    tmp_path, monkeypatch, capsys
):
    import app

    cfg = config(tmp_path)
    with SqliteStore(cfg.db_path) as store:
        store.set_meta("owner-proof", "retained")
    paths = service_paths(tmp_path)

    monkeypatch.setattr(app.sys, "platform", "darwin")
    monkeypatch.setattr(app, "service_paths", lambda home: paths)
    monkeypatch.setattr(app, "_doctor", lambda check_database=False: 0)
    monkeypatch.setattr(app.shutil, "which", lambda name: str(tmp_path / "uv"))
    monkeypatch.setattr(app, "launch_agent_payload", lambda *args, **kwargs: {})

    def install(payload, selected, *, uid, before_replace):
        before_replace()
        return True

    monkeypatch.setattr(app, "install_launch_agent", install)

    assert app._service_command(cfg, ["service", "install"]) == 0
    backups = list((paths.data_dir / "Backups").glob("*.db"))
    assert len(backups) == 1
    with SqliteStore(str(backups[0])) as stored:
        assert stored.get_meta("owner-proof") == "retained"
        assert stored.integrity_check() == (True, "ok")
    assert "verified pre-update backup" in capsys.readouterr().out
