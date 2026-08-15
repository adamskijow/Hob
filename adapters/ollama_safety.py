# SPDX-License-Identifier: MIT
"""Validate whether an Ollama endpoint keeps Hob's private prompts local."""
from __future__ import annotations

import ipaddress
from urllib.parse import urlsplit


def is_loopback_ollama_host(host: str) -> bool:
    parsed = urlsplit(host)
    hostname = (parsed.hostname or "").lower().rstrip(".")
    if hostname == "localhost" or hostname.endswith(".localhost"):
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


def validate_ollama_host(host: str, *, allow_remote: bool = False) -> str:
    """Return a validated endpoint or raise with an actionable privacy message."""
    value = host.strip()
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("must be an http:// or https:// URL with a host")
    if parsed.username or parsed.password:
        raise ValueError("must not put credentials in the endpoint URL")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ValueError("must not include a path, query, or fragment")
    if is_loopback_ollama_host(value):
        return value.rstrip("/")
    if not allow_remote:
        raise ValueError(
            "is remote; set HOB_ALLOW_REMOTE_OLLAMA=1 only if sending task text "
            "to that server is intentional"
        )
    if parsed.scheme != "https":
        raise ValueError("remote endpoints require https://")
    return value.rstrip("/")
