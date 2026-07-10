# SPDX-License-Identifier: MIT
import pytest

from config import Config, ConfigError

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


def test_defaults_applied():
    c = Config.from_env({})
    assert c.model == "qwen2.5:7b-instruct"
    assert c.wake_time == "07:00"
    assert c.db_path == "hob.db"
    assert c.keep_alive == "-1"  # resident by default
    assert c.reminder_lead == 10  # a heads-up 10 min before, by default
    assert not c.telegram_enabled
    assert c.allowed_telegram_user_id is None


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


def test_bad_wake_time():
    with pytest.raises(ConfigError):
        Config.from_env({**BASE, "HOB_WAKE_TIME": "7am"})


def test_bad_wake_time_out_of_range():
    with pytest.raises(ConfigError):
        Config.from_env({**BASE, "HOB_WAKE_TIME": "24:00"})


def test_bad_timezone():
    with pytest.raises(ConfigError):
        Config.from_env({**BASE, "HOB_TIMEZONE": "Mars/Olympus"})
