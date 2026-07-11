# SPDX-License-Identifier: MIT
"""Deterministic day planning against working hours and opaque busy periods.

The LLM may explain the result, but it never decides whether two things overlap
or whether work fits.  Calendar event titles are deliberately absent from these
types: feasibility needs only time boundaries.
"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, time, timedelta

from core.models import Item

DEFAULT_DURATION_MINUTES = 30
MIN_SPLIT_MINUTES = 25
_PRIORITY = {"high": 0, "normal": 1, "low": 2}


@dataclass(frozen=True)
class BusyPeriod:
    start: datetime
    end: datetime
    source: str = "calendar"
    opaque_id: str | None = None


@dataclass
class CalendarSnapshot:
    status: str  # authorized | denied | not_determined | restricted | unavailable
    busy: list[BusyPeriod] = field(default_factory=list)
    detail: str | None = None


@dataclass(frozen=True)
class PlanPreferences:
    work_start: str = "09:00"
    work_end: str = "17:30"
    breaks: tuple[tuple[str, str], ...] = (("12:00", "13:00"),)
    budget_minutes: int | None = None
    earliest_time: str | None = None
    latest_time: str | None = None
    energy: str | None = None


@dataclass
class PlanBlock:
    item_id: str
    label: str
    start: datetime
    end: datetime
    fixed: bool = False
    inferred_duration: bool = False
    segment: int = 1

    def to_dict(self) -> dict:
        out = asdict(self)
        out["start"] = self.start.isoformat()
        out["end"] = self.end.isoformat()
        return out


@dataclass
class DeferredItem:
    item_id: str
    label: str
    reason: str
    remaining_minutes: int


@dataclass
class DayPlan:
    day: str
    generated_at: str
    calendar_status: str
    blocks: list[PlanBlock] = field(default_factory=list)
    deferred: list[DeferredItem] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    free_minutes: int = 0

    def to_dict(self) -> dict:
        return {
            "day": self.day,
            "generated_at": self.generated_at,
            "calendar_status": self.calendar_status,
            "blocks": [block.to_dict() for block in self.blocks],
            "deferred": [asdict(item) for item in self.deferred],
            "warnings": list(self.warnings),
            "free_minutes": self.free_minutes,
        }


def _clock(value: str) -> time:
    return time.fromisoformat(value)


def _at(day: date, value: str, tzinfo) -> datetime:
    return datetime.combine(day, _clock(value), tzinfo=tzinfo)


def _parse_spoken_time(raw: str) -> str | None:
    text = raw.strip().lower().replace(".", "")
    if text in {"noon", "midday"}:
        return "12:00"
    if text == "midnight":
        return "00:00"
    match = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?", text)
    if not match:
        return None
    hour = int(match.group(1))
    minute = int(match.group(2) or 0)
    meridiem = match.group(3)
    if minute > 59 or hour > (12 if meridiem else 23) or hour == 0 and meridiem:
        return None
    if meridiem == "pm" and hour != 12:
        hour += 12
    elif meridiem == "am" and hour == 12:
        hour = 0
    elif meridiem is None and 1 <= hour <= 6:
        hour += 12
    return f"{hour:02d}:{minute:02d}"


def parse_plan_preferences(
    constraint: str,
    *,
    work_start: str = "09:00",
    work_end: str = "17:30",
    breaks: tuple[tuple[str, str], ...] = (("12:00", "13:00"),),
) -> PlanPreferences:
    """Extract hard planning bounds literally; unknown prose remains harmless."""
    low = (constraint or "").lower()
    budget = None
    match = re.search(r"\b(\d+)\s*(?:minutes?|mins?)\b", low)
    if match:
        budget = int(match.group(1))
    else:
        match = re.search(r"\b(\d+(?:\.\d+)?)\s*(?:hours?|hrs?)\b", low)
        if match:
            budget = round(float(match.group(1)) * 60)

    earliest = latest = None
    after = re.search(
        r"\b(?:after|starting at|start at|from)\s+(\d{1,2}(?::\d{2})?\s*(?:am|pm)?|noon|midday)",
        low,
    )
    before = re.search(
        r"\b(?:before|until|ending at|end at)\s+(\d{1,2}(?::\d{2})?\s*(?:am|pm)?|noon|midday)",
        low,
    )
    if after:
        earliest = _parse_spoken_time(after.group(1))
    if before:
        latest = _parse_spoken_time(before.group(1))
    if any(phrase in low for phrase in (
        "morning gone", "morning is gone", "morning's gone", "no morning",
    )):
        earliest = max(filter(None, (earliest, "12:00")))
    if any(phrase in low for phrase in (
        "afternoon gone", "afternoon is gone", "afternoon's gone", "no afternoon",
    )):
        latest = min(filter(None, (latest, "12:00")))

    energy = "low" if re.search(r"\b(low|little|tired|drained)\s+energy\b|\bexhausted\b", low) else None
    return PlanPreferences(
        work_start=work_start,
        work_end=work_end,
        breaks=breaks,
        budget_minutes=budget,
        earliest_time=earliest,
        latest_time=latest,
        energy=energy,
    )


def _merge(periods: list[BusyPeriod]) -> list[BusyPeriod]:
    merged: list[BusyPeriod] = []
    for period in sorted(periods, key=lambda p: (p.start, p.end)):
        if period.end <= period.start:
            continue
        if merged and period.start <= merged[-1].end:
            prior = merged[-1]
            merged[-1] = BusyPeriod(
                prior.start, max(prior.end, period.end), prior.source, prior.opaque_id
            )
        else:
            merged.append(period)
    return merged


def _free_slots(start: datetime, end: datetime, busy: list[BusyPeriod]) -> list[tuple[datetime, datetime]]:
    cursor = start
    slots: list[tuple[datetime, datetime]] = []
    for period in _merge(busy):
        if period.end <= start or period.start >= end:
            continue
        blocked_start, blocked_end = max(start, period.start), min(end, period.end)
        if blocked_start > cursor:
            slots.append((cursor, blocked_start))
        cursor = max(cursor, blocked_end)
    if cursor < end:
        slots.append((cursor, end))
    return slots


def _minutes(start: datetime, end: datetime) -> int:
    return max(0, int((end - start).total_seconds() // 60))


def _round_up(value: datetime, minutes: int = 5) -> datetime:
    discard = timedelta(
        minutes=value.minute % minutes,
        seconds=value.second,
        microseconds=value.microsecond,
    )
    rounded = value - discard
    return rounded if discard == timedelta(0) else rounded + timedelta(minutes=minutes)


def _item_ready(item: Item, day: date, horizon_start: datetime) -> tuple[bool, datetime | None]:
    if not item.earliest_start:
        return True, None
    try:
        if "T" in item.earliest_start:
            ready = datetime.fromisoformat(item.earliest_start)
            if ready.tzinfo is None:
                ready = ready.replace(tzinfo=horizon_start.tzinfo)
            return ready <= horizon_start or ready.date() == day, ready
        ready_day = date.fromisoformat(item.earliest_start)
        return ready_day <= day, None
    except ValueError:
        return True, None


def _preferred_bounds(item: Item, day: date, tzinfo) -> tuple[datetime, datetime] | None:
    raw = (item.preferred_window or "").strip().lower()
    named = {
        "morning": ("09:00", "12:00"),
        "afternoon": ("13:00", "17:30"),
        "evening": ("17:30", "21:00"),
    }
    if raw in named:
        start, end = named[raw]
    elif re.fullmatch(r"\d{2}:\d{2}-\d{2}:\d{2}", raw):
        start, end = raw.split("-", 1)
    else:
        return None
    try:
        return _at(day, start, tzinfo), _at(day, end, tzinfo)
    except ValueError:
        return None


def _candidate_key(item: Item, target: date, low_energy: bool) -> tuple:
    deadline = item.deadline_date or "9999-12-31"
    due = item.due_date or "9999-12-31"
    urgent_day = 0 if deadline <= target.isoformat() or due <= target.isoformat() else 1
    duration = item.duration_minutes or DEFAULT_DURATION_MINUTES
    return (
        urgent_day,
        deadline,
        _PRIORITY.get(item.priority, 1),
        duration if low_energy else 0,
        due,
        item.created_at,
    )


def _place_in_slots(
    slots: list[tuple[datetime, datetime]],
    minutes: int,
    preferred: tuple[datetime, datetime] | None,
    earliest: datetime | None = None,
) -> tuple[datetime, datetime] | None:
    eligible = [
        (max(start, earliest), end) if earliest else (start, end)
        for start, end in slots
        if not earliest or end > earliest
    ]
    ordered = eligible
    if preferred:
        pstart, pend = preferred
        preferred_slots = [
            (max(start, pstart), min(end, pend))
            for start, end in eligible
            if max(start, pstart) < min(end, pend)
        ]
        ordered = preferred_slots + eligible
    need = timedelta(minutes=minutes)
    for start, end in ordered:
        if end - start >= need:
            return start, start + need
    return None


def build_day_plan(
    items: list[Item],
    snapshot: CalendarSnapshot,
    now: datetime,
    preferences: PlanPreferences,
    previous: dict | None = None,
) -> DayPlan:
    """Build a feasibility-checked plan, explaining every item left out."""
    target = now.date()
    tzinfo = now.tzinfo
    work_start = _at(target, preferences.work_start, tzinfo)
    work_end = _at(target, preferences.work_end, tzinfo)
    if preferences.earliest_time:
        work_start = max(work_start, _at(target, preferences.earliest_time, tzinfo))
    if preferences.latest_time:
        work_end = min(work_end, _at(target, preferences.latest_time, tzinfo))
    horizon_start = max(work_start, _round_up(now))

    plan = DayPlan(
        day=target.isoformat(),
        generated_at=now.isoformat(),
        calendar_status=snapshot.status,
    )
    if work_end <= horizon_start:
        plan.warnings.append("no working time remains inside the requested window")

    busy = list(snapshot.busy)
    for start, end in preferences.breaks:
        busy.append(BusyPeriod(_at(target, start, tzinfo), _at(target, end, tzinfo), "break"))

    open_ids = {item.id for item in items}
    candidates: list[Item] = []
    for item in items:
        if item.due_date and item.due_date > target.isoformat():
            continue
        if item.waiting_since:
            plan.deferred.append(DeferredItem(item.id, item.task, "waiting on someone else", item.duration_minutes or DEFAULT_DURATION_MINUTES))
            continue
        blocking = [dependency for dependency in item.depends_on if dependency in open_ids]
        if blocking:
            plan.deferred.append(DeferredItem(item.id, item.task, "blocked by " + ", ".join(blocking), item.duration_minutes or DEFAULT_DURATION_MINUTES))
            continue
        ready, ready_at = _item_ready(item, target, horizon_start)
        if not ready or ready_at and ready_at.date() > target:
            plan.deferred.append(DeferredItem(item.id, item.task, f"not ready until {item.earliest_start}", item.duration_minutes or DEFAULT_DURATION_MINUTES))
            continue
        candidates.append(item)

    # A timed task is anchored. Explicit fixed commitments never move; ordinary
    # timed tasks also retain their stated time because moving them silently
    # would make reminders and the plan disagree.
    flexible: list[Item] = []
    for item in candidates:
        if item.due_date == target.isoformat() and item.due_time:
            start = _at(target, item.due_time, tzinfo)
            end = start + timedelta(minutes=item.duration_minutes or DEFAULT_DURATION_MINUTES)
            if end <= now:
                plan.deferred.append(
                    DeferredItem(
                        item.id,
                        item.task,
                        "stated time has passed; it was not moved",
                        item.duration_minutes or DEFAULT_DURATION_MINUTES,
                    )
                )
                plan.warnings.append(
                    f'missed stated time: "{item.task}" was at {item.due_time}'
                )
                continue
            overlaps = any(start < period.end and end > period.start for period in busy)
            outside = start < work_start or end > work_end
            if overlaps or outside:
                problem = "overlaps protected calendar time" if overlaps else "falls outside working hours"
                plan.warnings.append(f'"{item.task}" {problem}; its stated time was not moved')
            block = PlanBlock(
                item.id,
                item.task,
                start,
                end,
                fixed=item.schedule_kind == "fixed",
                inferred_duration=item.duration_minutes is None,
            )
            plan.blocks.append(block)
            busy.append(BusyPeriod(start, end, "task", item.id))
        else:
            flexible.append(item)

    remaining_budget = preferences.budget_minutes
    flexible.sort(key=lambda item: _candidate_key(item, target, preferences.energy == "low"))
    anchors: dict[str, tuple[datetime, datetime]] = {}
    if (
        previous
        and previous.get("day") == target.isoformat()
        and remaining_budget is None
    ):
        old_blocks: dict[str, list[dict]] = {}
        for block in previous.get("blocks", []):
            if isinstance(block, dict):
                old_blocks.setdefault(str(block.get("item_id")), []).append(block)
        reserved = list(busy)
        anchor_budget = remaining_budget
        for item in flexible:
            prior = old_blocks.get(item.id, [])
            if len(prior) != 1:
                continue
            duration = item.duration_minutes or DEFAULT_DURATION_MINUTES
            allowed = duration if anchor_budget is None else min(duration, anchor_budget)
            if allowed <= 0 or allowed < duration and not item.splittable:
                continue
            try:
                start = datetime.fromisoformat(str(prior[0]["start"]))
                end = datetime.fromisoformat(str(prior[0]["end"]))
            except (KeyError, TypeError, ValueError):
                continue
            if start.tzinfo is None:
                start = start.replace(tzinfo=tzinfo)
                end = end.replace(tzinfo=tzinfo)
            required = allowed if item.splittable else duration
            item_earliest = None
            if item.earliest_start and "T" in item.earliest_start:
                try:
                    item_earliest = datetime.fromisoformat(item.earliest_start)
                    if item_earliest.tzinfo is None:
                        item_earliest = item_earliest.replace(tzinfo=tzinfo)
                except ValueError:
                    pass
            if (
                _minutes(start, end) != required
                or start < horizon_start
                or end > work_end
                or item_earliest and start < item_earliest
                or any(start < period.end and end > period.start for period in reserved)
            ):
                continue
            anchors[item.id] = (start, end)
            reserved.append(BusyPeriod(start, end, "task", item.id))
            if anchor_budget is not None:
                anchor_budget -= required
        busy = reserved
        remaining_budget = anchor_budget

    for item in flexible:
        if item.id in anchors:
            start, end = anchors[item.id]
            plan.blocks.append(
                PlanBlock(
                    item.id,
                    item.task,
                    start,
                    end,
                    inferred_duration=item.duration_minutes is None,
                )
            )
            continue
        duration = item.duration_minutes or DEFAULT_DURATION_MINUTES
        allowed = duration if remaining_budget is None else min(duration, remaining_budget)
        if allowed <= 0:
            plan.deferred.append(DeferredItem(item.id, item.task, "outside the stated time budget", duration))
            continue
        if allowed < duration and not item.splittable:
            plan.deferred.append(
                DeferredItem(
                    item.id, item.task, "does not fit the stated time budget", duration
                )
            )
            continue
        preferred = _preferred_bounds(item, target, tzinfo)
        item_earliest = None
        if item.earliest_start and "T" in item.earliest_start:
            try:
                item_earliest = datetime.fromisoformat(item.earliest_start)
                if item_earliest.tzinfo is None:
                    item_earliest = item_earliest.replace(tzinfo=tzinfo)
            except ValueError:
                pass
        slots = _free_slots(horizon_start, work_end, busy) if work_end > horizon_start else []
        placed = _place_in_slots(
            slots,
            allowed if item.splittable else duration,
            preferred,
            item_earliest,
        )
        if placed:
            start, end = placed
            used = _minutes(start, end)
            plan.blocks.append(PlanBlock(item.id, item.task, start, end, inferred_duration=item.duration_minutes is None))
            busy.append(BusyPeriod(start, end, "task", item.id))
            if remaining_budget is not None:
                remaining_budget -= used
            if used < duration:
                plan.deferred.append(DeferredItem(item.id, item.task, "partially scheduled", duration - used))
            continue

        # Splittable work may consume several real gaps, never tiny fragments.
        if item.splittable:
            left = allowed
            segment = 1
            for start, end in slots:
                if item_earliest:
                    start = max(start, item_earliest)
                available = _minutes(start, end)
                take = min(left, available)
                if take < MIN_SPLIT_MINUTES and take != left:
                    continue
                block_end = start + timedelta(minutes=take)
                plan.blocks.append(PlanBlock(item.id, item.task, start, block_end, inferred_duration=item.duration_minutes is None, segment=segment))
                busy.append(BusyPeriod(start, block_end, "task", item.id))
                left -= take
                segment += 1
                if remaining_budget is not None:
                    remaining_budget -= take
                if left <= 0:
                    break
            if left < allowed:
                if duration - (allowed - left) > 0:
                    plan.deferred.append(DeferredItem(item.id, item.task, "partially scheduled", duration - (allowed - left)))
                continue

        reason = "does not fit the remaining free time"
        if item.preferred_window:
            reason += f" (preferred {item.preferred_window})"
        plan.deferred.append(DeferredItem(item.id, item.task, reason, duration))

    plan.blocks.sort(key=lambda block: (block.start, block.end, block.item_id))
    final_slots = _free_slots(horizon_start, work_end, busy) if work_end > horizon_start else []
    plan.free_minutes = sum(_minutes(start, end) for start, end in final_slots)
    for item in plan.deferred:
        source = next((candidate for candidate in items if candidate.id == item.item_id), None)
        if source and source.deadline_date:
            days = (date.fromisoformat(source.deadline_date) - target).days
            if days <= 0:
                plan.warnings.append(
                    f'deadline at risk: "{source.task}" still needs {item.remaining_minutes}m'
                )
            elif days == 1:
                plan.warnings.append(
                    f'deadline tomorrow: "{source.task}" still needs {item.remaining_minutes}m'
                )
    return plan


def diff_day_plans(previous: dict | None, current: DayPlan) -> list[str]:
    """Describe material changes without treating a new generated timestamp as one."""
    if not previous or previous.get("day") != current.day:
        return []
    old_blocks: dict[str, list[tuple[str, str]]] = {}
    for block in previous.get("blocks", []):
        old_blocks.setdefault(str(block.get("item_id")), []).append((str(block.get("start")), str(block.get("end"))))
    new_blocks: dict[str, list[tuple[str, str]]] = {}
    labels: dict[str, str] = {}
    for block in current.blocks:
        new_blocks.setdefault(block.item_id, []).append((block.start.isoformat(), block.end.isoformat()))
        labels[block.item_id] = block.label
    labels.update({item.item_id: item.label for item in current.deferred})
    changes: list[str] = []
    for item_id in sorted(set(old_blocks) | set(new_blocks)):
        if old_blocks.get(item_id) == new_blocks.get(item_id):
            continue
        label = labels.get(item_id) or item_id
        if item_id not in new_blocks:
            changes.append(f'deferred "{label}"')
        elif item_id not in old_blocks:
            new_time = new_blocks[item_id][0][0][11:16]
            changes.append(f'added "{label}" at {new_time}')
        else:
            old_time = old_blocks[item_id][0][0][11:16]
            new_time = new_blocks[item_id][0][0][11:16]
            changes.append(f'moved "{label}" {old_time} → {new_time}')
    return changes[:5]
