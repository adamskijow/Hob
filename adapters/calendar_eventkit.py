# SPDX-License-Identifier: MIT
"""Read-only macOS EventKit adapter through Hob's small Swift bridge."""
from __future__ import annotations

import json
import subprocess
from datetime import datetime
from pathlib import Path

from core.feasibility import BusyPeriod, CalendarSnapshot

DEFAULT_BRIDGE = (
    Path(__file__).resolve().parent.parent
    / "native"
    / "HobCalendarBridge"
    / ".build"
    / "HobCalendarBridge.app"
    / "Contents"
    / "MacOS"
    / "HobCalendarBridge"
)


class EventKitCalendar:
    """Fetch opaque busy ranges. Event names never cross the adapter boundary."""

    def __init__(self, bridge_path: str | None = None, enabled: bool = True) -> None:
        self._path = Path(bridge_path).expanduser() if bridge_path else DEFAULT_BRIDGE
        self._enabled = enabled

    @property
    def bridge_path(self) -> Path:
        return self._path

    def _run(self, *args: str) -> dict:
        if not self._enabled:
            return {"status": "disabled"}
        if not self._path.is_file():
            return {
                "status": "unavailable",
                "detail": f"calendar bridge not built at {self._path}",
            }
        try:
            result = subprocess.run(
                [str(self._path), *args],
                check=False,
                capture_output=True,
                text=True,
                timeout=130 if args and args[0] == "request-access" else 15,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return {"status": "unavailable", "detail": str(exc)}
        try:
            data = json.loads(result.stdout)
        except (TypeError, json.JSONDecodeError):
            detail = result.stderr.strip() or f"bridge exited {result.returncode}"
            return {"status": "unavailable", "detail": detail}
        if not isinstance(data, dict):
            return {"status": "unavailable", "detail": "invalid bridge response"}
        return data

    def status(self) -> CalendarSnapshot:
        data = self._run("status")
        return CalendarSnapshot(
            status=str(data.get("status") or "unavailable"),
            detail=str(data.get("detail")) if data.get("detail") else None,
        )

    def request_access(self) -> CalendarSnapshot:
        data = self._run("request-access")
        return CalendarSnapshot(
            status=str(data.get("status") or "unavailable"),
            detail=str(data.get("detail")) if data.get("detail") else None,
        )

    def snapshot(self, start: datetime, end: datetime) -> CalendarSnapshot:
        data = self._run("events", start.isoformat(), end.isoformat())
        status = str(data.get("status") or "unavailable")
        busy: list[BusyPeriod] = []
        if status == "authorized":
            for event in data.get("events", []):
                if not isinstance(event, dict):
                    continue
                try:
                    event_start = datetime.fromisoformat(str(event["start"]))
                    event_end = datetime.fromisoformat(str(event["end"]))
                except (KeyError, TypeError, ValueError):
                    continue
                if event_end > event_start:
                    busy.append(
                        BusyPeriod(
                            event_start,
                            event_end,
                            "calendar",
                            None,
                        )
                    )
        return CalendarSnapshot(
            status=status,
            busy=busy,
            detail=str(data.get("detail")) if data.get("detail") else None,
        )
