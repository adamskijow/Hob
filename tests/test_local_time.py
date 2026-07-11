# SPDX-License-Identifier: MIT
from datetime import date
from zoneinfo import ZoneInfo

from core.local_time import wall_datetime, wall_time_status

TZ = ZoneInfo("America/New_York")


def test_wall_time_classifies_dst_gap_repeat_and_ordinary_time():
    assert wall_time_status(wall_datetime(date(2026, 3, 8), "02:30", TZ)) == (
        "nonexistent"
    )
    assert wall_time_status(wall_datetime(date(2026, 11, 1), "01:30", TZ)) == (
        "ambiguous"
    )
    assert wall_time_status(wall_datetime(date(2026, 7, 11), "09:00", TZ)) == (
        "valid"
    )
