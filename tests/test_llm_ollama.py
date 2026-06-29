# SPDX-License-Identifier: MIT
"""Ollama adapter: only the pure keep_alive parsing is unit-tested; the network
call itself is exercised live, not here."""
from adapters.llm_ollama import _parse_keep_alive


def test_keep_alive_integers_pass_as_int():
    # ollama reads a bare number as seconds (-1 = forever); it must not be a str.
    assert _parse_keep_alive("-1") == -1
    assert _parse_keep_alive("0") == 0
    assert _parse_keep_alive("300") == 300


def test_keep_alive_durations_pass_as_str():
    assert _parse_keep_alive("30m") == "30m"
    assert _parse_keep_alive("2h") == "2h"
