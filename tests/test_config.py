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
    assert not c.telegram_enabled


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
