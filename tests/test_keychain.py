# SPDX-License-Identifier: MIT
from adapters import keychain


def test_token_write_never_places_secret_in_process_arguments(monkeypatch):
    recorded = []
    monkeypatch.setattr(keychain, "available", lambda: True)
    monkeypatch.setattr(
        keychain,
        "_set_generic_password",
        lambda service, account, password: recorded.append(
            (service, account, password)
        ),
    )

    def fail_subprocess(*args, **kwargs):
        raise AssertionError("token writes must not spawn the security CLI")

    monkeypatch.setattr(keychain.subprocess, "run", fail_subprocess)
    keychain.set_telegram_token("  123456:private-token  ")

    assert recorded == [
        (keychain.SERVICE, keychain._account(), "123456:private-token")
    ]
