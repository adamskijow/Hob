# SPDX-License-Identifier: MIT
from types import SimpleNamespace

import app


def test_help_and_unknown_command_never_start_the_daemon(monkeypatch, capsys):
    def config_must_not_load():
        raise AssertionError("non-daemon CLI handling loaded configuration")

    monkeypatch.setattr(app.Config, "from_env", config_must_not_load)

    assert app.main(["--help"]) == 0
    assert "usage: python app.py" in capsys.readouterr().out

    assert app.main(["--definitely-not-a-command"]) == 2
    captured = capsys.readouterr()
    assert "unknown command" in captured.err


def test_daemon_and_status_refuse_ambiguous_database_selection(
    monkeypatch, capsys
):
    cfg = SimpleNamespace(telegram_token="private", db_path="hob.db")
    monkeypatch.setattr(app.Config, "from_env", lambda: cfg)
    monkeypatch.setattr(
        app,
        "_database_choice_error",
        lambda configured: "both legacy and app data databases exist",
    )

    assert app.main([]) == 2
    assert "start refused" in capsys.readouterr().err
    assert app.main(["status"]) == 2
    assert "status refused" in capsys.readouterr().err
