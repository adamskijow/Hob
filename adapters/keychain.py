# SPDX-License-Identifier: MIT
"""Minimal macOS Keychain adapter for Hob's Telegram credential."""
from __future__ import annotations

import getpass
import platform
import subprocess

SERVICE = "com.local.hob.telegram"


class KeychainError(RuntimeError):
    pass


def _account() -> str:
    return getpass.getuser()


def available() -> bool:
    return platform.system() == "Darwin"


def get_telegram_token() -> str | None:
    if not available():
        return None
    result = subprocess.run(
        [
            "/usr/bin/security",
            "find-generic-password",
            "-s",
            SERVICE,
            "-a",
            _account(),
            "-w",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    token = result.stdout.strip()
    return token or None


def set_telegram_token(token: str) -> None:
    token = token.strip()
    if not token:
        raise KeychainError("token must not be empty")
    if not available():
        raise KeychainError("macOS Keychain is unavailable on this platform")
    result = subprocess.run(
        [
            "/usr/bin/security",
            "add-generic-password",
            "-U",
            "-s",
            SERVICE,
            "-a",
            _account(),
            "-w",
            token,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise KeychainError(result.stderr.strip() or "could not update Keychain")


def delete_telegram_token() -> bool:
    if not available():
        return False
    result = subprocess.run(
        [
            "/usr/bin/security",
            "delete-generic-password",
            "-s",
            SERVICE,
            "-a",
            _account(),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0
