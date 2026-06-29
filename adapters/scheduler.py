# SPDX-License-Identifier: MIT
"""Scheduler adapter: in-process morning-digest timer + catch-up-on-wake.

An in-process timer does not fire while the Mac is asleep, so on every startup
and first post-wake tick the scheduler checks meta.last_digest_date and fires
the digest if today's is still owed and the time is past wake time. Marks the
date so it fires exactly once per day. Filled in Phase 3.
"""
from __future__ import annotations
