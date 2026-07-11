# SPDX-License-Identifier: MIT
import pytest

from config import Config, ConfigError, _system_timezone

BASE = {
    "HOB_TELEGRAM_TOKEN": "tok",
    "HOB_MODEL": "qwen2.5:7b-instruct",
    "HOB_WAKE_TIME": "07:00",
    "HOB_TIMEZONE": "UTC",
    "HOB_DB_PATH": "hob.db",
}


def test_valid_config():
    c = Config.from_env(BASE)
    assert c.wake_time == "07:00"
    assert c.timezone == "UTC"
    assert c.telegram_enabled
    assert c.telegram_token_source == "environment"


def test_defaults_applied():
    c = Config.from_env({"HOME": "/Users/tester"})
    assert c.model == "qwen2.5:7b-instruct"
    assert c.wake_time == "07:00"
    assert c.db_path == "/Users/tester/Library/Application Support/Hob/hob.db"
    assert c.keep_alive == "-1"  # resident by default
    assert c.reminder_lead == 10  # a heads-up 10 min before, by default
    assert not c.telegram_enabled
    assert c.allowed_telegram_user_id is None
    assert c.calendar_enabled
    assert (c.work_start, c.work_end) == ("09:00", "17:30")
    assert c.work_days == (0, 1, 2, 3, 4)
    assert c.breaks == (("12:00", "13:00"),)
    assert c.default_duration_minutes == 30
    assert c.transition_buffer_minutes == 0


def test_system_timezone_prefers_tz_then_localtime_then_timezone_file(tmp_path):
    assert _system_timezone({"TZ": "Europe/Paris"}) == "Europe/Paris"

    zone = tmp_path / "zoneinfo" / "America" / "Chicago"
    zone.parent.mkdir(parents=True)
    zone.write_text("fixture", encoding="utf-8")
    localtime = tmp_path / "localtime"
    localtime.symlink_to(zone)
    assert _system_timezone(
        {}, localtime=localtime, timezone_file=tmp_path / "missing"
    ) == "America/Chicago"

    timezone_file = tmp_path / "timezone"
    timezone_file.write_text("Asia/Tokyo\n", encoding="utf-8")
    assert _system_timezone(
        {"TZ": "invalid"},
        localtime=tmp_path / "missing",
        timezone_file=timezone_file,
    ) == "Asia/Tokyo"
    assert _system_timezone(
        {}, localtime=tmp_path / "missing", timezone_file=tmp_path / "also-missing"
    ) == "UTC"


def test_allowed_telegram_user_id():
    assert Config.from_env(
        {**BASE, "HOB_ALLOWED_TELEGRAM_USER_ID": "12345"}
    ).allowed_telegram_user_id == 12345
    for bad in ("abc", "0", "-2"):
        with pytest.raises(ConfigError):
            Config.from_env({**BASE, "HOB_ALLOWED_TELEGRAM_USER_ID": bad})


def test_reminder_lead_override_and_validation():
    assert Config.from_env({**BASE, "HOB_REMINDER_LEAD": "0"}).reminder_lead == 0
    assert Config.from_env({**BASE, "HOB_REMINDER_LEAD": "30"}).reminder_lead == 30
    for bad in ("soon", "-5"):
        with pytest.raises(ConfigError):
            Config.from_env({**BASE, "HOB_REMINDER_LEAD": bad})


def test_keep_alive_override_and_validation():
    assert Config.from_env({**BASE, "HOB_KEEP_ALIVE": "30m"}).keep_alive == "30m"
    assert Config.from_env({**BASE, "HOB_KEEP_ALIVE": "1.5h"}).keep_alive == "1.5h"
    for bad in ("forever", "1.5"):  # unit-less decimal would break at ollama
        with pytest.raises(ConfigError):
            Config.from_env({**BASE, "HOB_KEEP_ALIVE": bad})


def test_missing_token_disables_telegram():
    env = {k: v for k, v in BASE.items() if k != "HOB_TELEGRAM_TOKEN"}
    c = Config.from_env(env)
    assert not c.telegram_enabled
    assert c.telegram_token_source == "none"


def test_runtime_config_falls_back_to_keychain(monkeypatch, tmp_path):
    monkeypatch.delenv("HOB_TELEGRAM_TOKEN", raising=False)
    monkeypatch.setenv("HOB_DB_PATH", str(tmp_path / "hob.db"))
    monkeypatch.delenv("HOB_TIMEZONE", raising=False)
    monkeypatch.setattr("config.get_telegram_token", lambda: "keychain-token")
    monkeypatch.setattr("config._system_timezone", lambda: "America/Los_Angeles")
    c = Config.from_env()
    assert c.telegram_token == "keychain-token"
    assert c.telegram_token_source == "keychain"
    assert c.timezone == "America/Los_Angeles"


def test_bad_wake_time():
    with pytest.raises(ConfigError):
        Config.from_env({**BASE, "HOB_WAKE_TIME": "7am"})


def test_bad_wake_time_out_of_range():
    with pytest.raises(ConfigError):
        Config.from_env({**BASE, "HOB_WAKE_TIME": "24:00"})


def test_bad_timezone():
    with pytest.raises(ConfigError):
        Config.from_env({**BASE, "HOB_TIMEZONE": "Mars/Olympus"})


def test_planning_frame_configuration_and_validation():
    cfg = Config.from_env({
        **BASE,
        "HOB_CALENDAR_ENABLED": "off",
        "HOB_WORK_HOURS": "08:30-16:30",
        "HOB_WORK_DAYS": "mon,wed,sat",
        "HOB_BREAKS": "10:00-10:15,12:30-13:00",
        "HOB_DEFAULT_DURATION": "45",
        "HOB_TRANSITION_BUFFER": "10",
    })
    assert not cfg.calendar_enabled
    assert (cfg.work_start, cfg.work_end) == ("08:30", "16:30")
    assert cfg.work_days == (0, 2, 5)
    assert cfg.breaks == (("10:00", "10:15"), ("12:30", "13:00"))
    assert cfg.default_duration_minutes == 45
    assert cfg.transition_buffer_minutes == 10
    for env in (
        {**BASE, "HOB_CALENDAR_ENABLED": "perhaps"},
        {**BASE, "HOB_WORK_HOURS": "9 to 5"},
        {**BASE, "HOB_BREAKS": "13:00-12:00"},
        {**BASE, "HOB_WORK_DAYS": "someday"},
        {**BASE, "HOB_DEFAULT_DURATION": "4"},
        {**BASE, "HOB_TRANSITION_BUFFER": "121"},
    ):
        with pytest.raises(ConfigError):
            Config.from_env(env)
