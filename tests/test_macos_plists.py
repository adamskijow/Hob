from __future__ import annotations

import plistlib
from pathlib import Path

from scripts.render_macos_plists import render_daemon, render_menu


ROOT = Path(__file__).resolve().parents[1]


def read_plist(path: Path) -> dict:
    with path.open("rb") as source:
        return plistlib.load(source)


def test_daemon_renderer_replaces_arrays_atomically(tmp_path):
    output = tmp_path / "com.local.hob.plist"
    render_daemon(
        template=ROOT / "deploy/com.local.hob.plist",
        output=output,
        python_path="/Users/test user/Git/Hob/.venv/bin/python",
        uv_path="/Users/test user/.local/bin/uv",
        project_root="/Users/test user/Git/Hob",
        model="test-model",
        timezone="America/New_York",
        database_path="/Users/test user/Library/Application Support/Hob/hob.db",
        log_path="/Users/test user/Library/Application Support/Hob/hob.log",
        ollama_host="http://localhost:11434",
        allow_remote_ollama="0",
        allowed_telegram_user_id=None,
    )

    payload = read_plist(output)
    assert payload["ProgramArguments"] == [
        "/Users/test user/Git/Hob/.venv/bin/python",
        "app.py",
    ]
    assert payload["WorkingDirectory"] == "/Users/test user/Git/Hob"
    assert payload["StandardOutPath"] == "/dev/null"
    assert payload["StandardErrorPath"] == "/dev/null"
    assert payload["EnvironmentVariables"]["HOB_LOG_PATH"].endswith("hob.log")
    assert "HOB_ALLOWED_TELEGRAM_USER_ID" not in payload["EnvironmentVariables"]
    assert "/Users/you" not in output.read_text()


def test_daemon_renderer_keeps_explicit_owner(tmp_path):
    output = tmp_path / "com.local.hob.plist"
    render_daemon(
        template=ROOT / "deploy/com.local.hob.plist",
        output=output,
        python_path="/opt/hob/.venv/bin/python",
        uv_path="/opt/uv",
        project_root="/opt/hob",
        model="test-model",
        timezone="UTC",
        database_path="/data/hob.db",
        log_path="/logs/hob.log",
        ollama_host="https://ollama.example.test",
        allow_remote_ollama="1",
        allowed_telegram_user_id="8761124835",
    )

    assert (
        read_plist(output)["EnvironmentVariables"]["HOB_ALLOWED_TELEGRAM_USER_ID"]
        == "8761124835"
    )
    environment = read_plist(output)["EnvironmentVariables"]
    assert environment["HOB_OLLAMA_HOST"] == "https://ollama.example.test"
    assert environment["HOB_ALLOW_REMOTE_OLLAMA"] == "1"


def test_daemon_renderer_preserves_existing_schedule_and_preferences(tmp_path):
    existing = tmp_path / "existing.plist"
    with (ROOT / "deploy/com.local.hob.plist").open("rb") as source:
        payload = plistlib.load(source)
    payload["EnvironmentVariables"]["HOB_WAKE_TIME"] = "06:45"
    payload["EnvironmentVariables"]["HOB_WORK_DAYS"] = "mon,wed,fri"
    with existing.open("wb") as destination:
        plistlib.dump(payload, destination)
    output = tmp_path / "rendered.plist"

    render_daemon(
        template=existing,
        output=output,
        python_path="/opt/hob/.venv/bin/python",
        uv_path="/opt/uv",
        project_root="/opt/hob",
        model="test-model",
        timezone="UTC",
        database_path="/data/hob.db",
        log_path="/logs/hob.log",
        ollama_host="http://localhost:11434",
        allow_remote_ollama="0",
        allowed_telegram_user_id="8761124835",
    )

    environment = read_plist(output)["EnvironmentVariables"]
    assert environment["HOB_WAKE_TIME"] == "06:45"
    assert environment["HOB_WORK_DAYS"] == "mon,wed,fri"


def test_menu_renderer_has_exactly_one_executable(tmp_path):
    output = tmp_path / "com.local.hob.menu.plist"
    executable = (
        "/Users/test user/Applications/Hob Local.app/Contents/MacOS/"
        "HobOpenLocalMenu"
    )
    render_menu(
        template=ROOT / "deploy/com.local.hob.menu.plist",
        output=output,
        executable_path=executable,
        project_root="/Users/test user/Git/Hob",
        database_path="/Users/test user/Library/Application Support/Hob/hob.db",
        uv_path="/Users/test user/.local/bin/uv",
        log_path="/Users/test user/Library/Application Support/Hob/hob.log",
        model="test-model",
        ollama_host="http://localhost:11434",
        allow_remote_ollama="0",
        timezone="America/New_York",
    )

    payload = read_plist(output)
    assert payload["ProgramArguments"] == [executable]
    assert payload["StandardOutPath"] == "/dev/null"
    assert payload["StandardErrorPath"] == "/dev/null"
    assert payload["EnvironmentVariables"]["HOB_PROJECT_PATH"] == (
        "/Users/test user/Git/Hob"
    )
    assert "/Users/you" not in output.read_text()
