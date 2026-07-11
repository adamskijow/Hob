# SPDX-License-Identifier: MIT
"""Pure seven-day capacity outlook built from the daily feasibility engine.

The outlook is a read-only simulation. It may treat a prerequisite as finished
on a later forecast day after all of its effort fits, but it never persists that
assumption or changes tasks, adopted plans, reminders, or Calendar.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field, replace
from datetime import date, datetime, timedelta

from core.feasibility import (
    BusyPeriod,
    CalendarSnapshot,
    PlanBlock,
    PlanPreferences,
    build_day_plan,
)
from core.models import Item, PlanSession


@dataclass
class ForecastDay:
    day: str
    calendar_status: str
    blocks: list[PlanBlock] = field(default_factory=list)
    free_minutes: int = 0
    warnings: list[str] = field(default_factory=list)

    @property
    def used_minutes(self) -> int:
        return sum(
            max(0, int((block.end - block.start).total_seconds() // 60))
            for block in self.blocks
        )

    def to_dict(self) -> dict:
        return {
            "day": self.day,
            "calendar_status": self.calendar_status,
            "used_minutes": self.used_minutes,
            "free_minutes": self.free_minutes,
            "blocks": [block.to_dict() for block in self.blocks],
            "warnings": list(self.warnings),
        }


@dataclass
class ForecastRisk:
    item_id: str
    label: str
    remaining_minutes: int
    reason: str
    deadline: str | None = None


@dataclass
class WeekForecast:
    start_day: str
    end_day: str
    days: list[ForecastDay] = field(default_factory=list)
    risks: list[ForecastRisk] = field(default_factory=list)
    unplaced: list[ForecastRisk] = field(default_factory=list)
    assumed_item_ids: list[str] = field(default_factory=list)

    @property
    def used_minutes(self) -> int:
        return sum(day.used_minutes for day in self.days)

    @property
    def free_minutes(self) -> int:
        return sum(day.free_minutes for day in self.days)

    def to_dict(self) -> dict:
        return {
            "start_day": self.start_day,
            "end_day": self.end_day,
            "used_minutes": self.used_minutes,
            "free_minutes": self.free_minutes,
            "days": [day.to_dict() for day in self.days],
            "risks": [asdict(risk) for risk in self.risks],
            "unplaced": [asdict(item) for item in self.unplaced],
            "assumed_item_ids": list(self.assumed_item_ids),
        }


def _minutes(start: str, end: str) -> int:
    return max(
        0,
        int(
            (datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds()
            // 60
        ),
    )


def build_week_forecast(
    items: list[Item],
    snapshots: dict[str, CalendarSnapshot],
    now: datetime,
    preferences: PlanPreferences,
    *,
    horizon_days: int = 7,
    adopted_sessions: list[PlanSession] | None = None,
) -> WeekForecast:
    """Allocate each open task's effort at most once over a short horizon."""
    if horizon_days < 1 or horizon_days > 31:
        raise ValueError("forecast horizon must be between 1 and 31 days")
    start = now.date()
    end = start + timedelta(days=horizon_days - 1)
    forecast = WeekForecast(start.isoformat(), end.isoformat())

    relevant = [
        item
        for item in items
        if not (
            item.due_date
            and item.due_date > end.isoformat()
            and (not item.deadline_date or item.deadline_date > end.isoformat())
        )
        and not (
            item.earliest_start and item.earliest_start[:10] > end.isoformat()
        )
    ]
    remaining_items = {
        item.id: Item.from_dict(item.to_dict()) for item in relevant
    }
    source_items = {item.id: item for item in relevant}
    remaining_minutes = {
        item.id: item.duration_minutes or preferences.default_duration_minutes
        for item in relevant
    }
    forecast.assumed_item_ids = sorted(
        item.id for item in relevant if item.duration_minutes is None
    )
    completed_in_forecast: set[str] = set()
    completion_day: dict[str, str] = {}
    horizon_budget = (
        preferences.budget_minutes
        if preferences.budget_scope == "horizon"
        else None
    )
    adopted_by_day: dict[str, list[PlanSession]] = {}
    for session in adopted_sessions or []:
        if (
            session.status in {"planned", "started"}
            and start.isoformat() <= session.start[:10] <= end.isoformat()
        ):
            adopted_by_day.setdefault(session.start[:10], []).append(session)

    for offset in range(horizon_days):
        target = start + timedelta(days=offset)
        day_iso = target.isoformat()
        snapshot = snapshots.get(day_iso, CalendarSnapshot("unavailable"))
        busy = list(snapshot.busy)
        adopted_blocks: list[PlanBlock] = []
        adopted_used: dict[str, int] = {}
        for session in adopted_by_day.get(day_iso, []):
            item = source_items.get(session.item_id)
            session_start = datetime.fromisoformat(session.start)
            session_end = datetime.fromisoformat(session.end)
            busy.append(
                BusyPeriod(session_start, session_end, "adopted", session.id)
            )
            adopted_blocks.append(
                PlanBlock(
                    item_id=session.item_id,
                    label=session.label,
                    start=session_start,
                    end=session_end,
                    fixed=True,
                    inferred_duration=(
                        item is not None and item.duration_minutes is None
                    ),
                    segment=session.segment,
                )
            )
            adopted_used[session.item_id] = (
                adopted_used.get(session.item_id, 0)
                + _minutes(session.start, session.end)
            )
        adopted_minutes = sum(
            _minutes(session.start, session.end)
            for session in adopted_by_day.get(day_iso, [])
        )
        if horizon_budget is not None:
            horizon_budget = max(
                0,
                horizon_budget - adopted_minutes,
            )
        for item_id, used in adopted_used.items():
            if item_id not in remaining_minutes or remaining_minutes[item_id] <= 0:
                continue
            remaining_minutes[item_id] = max(0, remaining_minutes[item_id] - used)
            if remaining_minutes[item_id] == 0:
                completed_in_forecast.add(item_id)
                completion_day[item_id] = day_iso
                remaining_items.pop(item_id, None)

        candidates: list[Item] = []
        for item_id, item in remaining_items.items():
            clone = Item.from_dict(item.to_dict())
            clone.depends_on = [
                dependency
                for dependency in clone.depends_on
                if dependency not in completed_in_forecast
            ]
            clone.duration_minutes = remaining_minutes[item_id]
            candidates.append(clone)

        day_preferences = (
            replace(preferences, budget_minutes=horizon_budget)
            if horizon_budget is not None
            else preferences
        )
        plan = build_day_plan(
            candidates,
            CalendarSnapshot(snapshot.status, busy, snapshot.detail),
            now,
            day_preferences,
            target_day=target,
        )
        used_by_item: dict[str, int] = {}
        for block in plan.blocks:
            if block.item_id in forecast.assumed_item_ids:
                block.inferred_duration = True
            used_by_item[block.item_id] = used_by_item.get(block.item_id, 0) + int(
                (block.end - block.start).total_seconds() // 60
            )
        for item_id, used in used_by_item.items():
            if item_id not in remaining_minutes:
                continue
            remaining_minutes[item_id] = max(0, remaining_minutes[item_id] - used)
            if remaining_minutes[item_id] == 0:
                completed_in_forecast.add(item_id)
                completion_day[item_id] = day_iso
                remaining_items.pop(item_id, None)
        if horizon_budget is not None:
            horizon_budget = max(0, horizon_budget - sum(used_by_item.values()))
        day_free_minutes = plan.free_minutes
        if (
            preferences.budget_scope == "day"
            and preferences.budget_minutes is not None
        ):
            day_free_minutes = min(
                day_free_minutes,
                max(
                    0,
                    preferences.budget_minutes
                    - adopted_minutes
                    - sum(used_by_item.values()),
                ),
            )
        forecast.days.append(
            ForecastDay(
                day=day_iso,
                calendar_status=snapshot.status,
                blocks=sorted(
                    adopted_blocks + plan.blocks,
                    key=lambda block: (block.start, block.end, block.item_id),
                ),
                free_minutes=day_free_minutes,
                warnings=list(dict.fromkeys(plan.warnings)),
            )
        )

    if horizon_budget is not None:
        visible_free = horizon_budget
        for day in forecast.days:
            day.free_minutes = min(day.free_minutes, visible_free)
            visible_free -= day.free_minutes

    for item_id, item in source_items.items():
        deadline = item.deadline_date
        completed = completion_day.get(item_id)
        if completed and deadline and completed > deadline:
            forecast.risks.append(
                ForecastRisk(
                    item_id,
                    item.task,
                    0,
                    f"forecast completion {completed} is after the deadline",
                    deadline,
                )
            )
            continue
        if item_id not in remaining_items:
            continue
        remaining = remaining_minutes[item_id]
        if item.waiting_since:
            reason = "waiting on someone else"
        elif item.depends_on:
            unresolved = [
                dependency
                for dependency in item.depends_on
                if dependency not in completed_in_forecast
            ]
            reason = (
                "blocked by " + ", ".join(unresolved)
                if unresolved
                else "does not fit after its prerequisite"
            )
        elif deadline and deadline <= end.isoformat():
            reason = f"does not fit by deadline {deadline}"
        elif item.due_date and item.due_date <= end.isoformat():
            reason = f"does not fit on or after scheduled date {item.due_date}"
        else:
            reason = "outside the remaining seven-day capacity"
        entry = ForecastRisk(item_id, item.task, remaining, reason, deadline)
        if (
            deadline and deadline <= end.isoformat()
            or item.due_date and item.due_date <= end.isoformat()
        ):
            forecast.risks.append(entry)
        else:
            forecast.unplaced.append(entry)
    forecast.risks.sort(key=lambda risk: (risk.deadline or "9999-12-31", risk.label))
    forecast.unplaced.sort(key=lambda item: item.label)
    return forecast
