# SPDX-License-Identifier: MIT
"""Minimal macOS Keychain adapter for Hob's Telegram credential."""
from __future__ import annotations

import ctypes
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
    _set_generic_password(SERVICE, _account(), token)


def _set_generic_password(service: str, account: str, password: str) -> None:
    """Write through Security.framework so the secret never appears in argv."""
    try:
        security = ctypes.CDLL(
            "/System/Library/Frameworks/Security.framework/Security"
        )
        core_foundation = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )
    except OSError as exc:
        raise KeychainError("could not load macOS Security.framework") from exc

    status_type = ctypes.c_int32
    item = ctypes.c_void_p()
    service_bytes = service.encode("utf-8")
    account_bytes = account.encode("utf-8")
    password_bytes = password.encode("utf-8")
    password_buffer = ctypes.create_string_buffer(password_bytes)

    security.SecKeychainFindGenericPassword.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_char_p,
        ctypes.c_uint32,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    security.SecKeychainFindGenericPassword.restype = status_type
    status = security.SecKeychainFindGenericPassword(
        None,
        len(service_bytes),
        service_bytes,
        len(account_bytes),
        account_bytes,
        None,
        None,
        ctypes.byref(item),
    )

    # errSecItemNotFound. Avoid stringly shell behavior and update the same item
    # in place so access-control prompts remain stable across token rotations.
    if status == -25300:
        security.SecKeychainAddGenericPassword.argtypes = [
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.c_char_p,
            ctypes.c_uint32,
            ctypes.c_char_p,
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        security.SecKeychainAddGenericPassword.restype = status_type
        status = security.SecKeychainAddGenericPassword(
            None,
            len(service_bytes),
            service_bytes,
            len(account_bytes),
            account_bytes,
            len(password_bytes),
            ctypes.cast(password_buffer, ctypes.c_void_p),
            None,
        )
    elif status == 0:
        security.SecKeychainItemModifyAttributesAndData.argtypes = [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.c_void_p,
        ]
        security.SecKeychainItemModifyAttributesAndData.restype = status_type
        status = security.SecKeychainItemModifyAttributesAndData(
            item,
            None,
            len(password_bytes),
            ctypes.cast(password_buffer, ctypes.c_void_p),
        )

    if item.value:
        core_foundation.CFRelease.argtypes = [ctypes.c_void_p]
        core_foundation.CFRelease(item)
    if status != 0:
        raise KeychainError(f"could not update Keychain (OSStatus {status})")


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
