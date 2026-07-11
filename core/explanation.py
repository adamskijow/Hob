# SPDX-License-Identifier: MIT
"""Grounded, read-only explanations of the latest deterministic planning result."""
from __future__ import annotations

import re

DECISION_VERSION = 1
_ORDINALS = {
    "first": 1,
    "second": 2,
    "third": 3,
    "fourth": 4,
    "fifth": 5,
    "sixth": 6,
    "seventh": 7,
    "eighth": 8,
    "ninth": 9,
    "tenth": 10,
}
_STOP = {
    "a", "about", "and", "did", "do", "for", "how", "i", "in", "it",
    "make", "my", "not", "of", "on", "one", "plan", "scheduled", "that",
    "the", "this", "to", "was", "what", "why", "will", "would",
}


def is_explanation_question(value: str) -> bool:
    """Literal safe route for a planning explanation, including model outage."""
    return bool(
        re.search(
            r"(?:\bwhy\b.{0,60}\b(?:plan|fit|placed|scheduled|deferred|at risk)\b|"
            r"\bwhy\b.{0,60}\bnot\b.{0,30}\b(?:on|in)\b.{0,20}\bplan\b|"
            r"\bwhat (?:would|needs? to|should) change\b.{0,60}\bfit\b|"
            r"\bwhat would make\b.{0,60}\bfit\b|"
            r"\bhow (?:can|could|do)\b.{0,20}\bmake\b.{0,40}\bfit\b|"
            r"\bwhat would it take\b.{0,60}\bfit\b)",
            value.lower(),
        )
    )


def _words(value: str) -> set[str]:
    return {
        word
        for word in re.findall(r"[a-z0-9]+", value.lower())
        if len(word) > 1 and word not in _STOP
    }


def _valid(snapshot: dict) -> bool:
    return (
        isinstance(snapshot, dict)
        and snapshot.get("version") == DECISION_VERSION
        and snapshot.get("kind") in {"plan", "outlook"}
        and isinstance(snapshot.get("preferences", {}), dict)
        and isinstance(snapshot.get("calendar", {}), dict)
        and isinstance(snapshot.get("items"), list)
        and len(snapshot["items"]) <= 100
        and all(
            isinstance(item, dict)
            and isinstance(item.get("id"), str)
            and len(item["id"]) <= 100
            and isinstance(item.get("label"), str)
            and len(item["label"]) <= 500
            and item.get("outcome")
            in {"scheduled", "partial", "deferred", "risk", "unplaced"}
            and isinstance(item.get("blocks", []), list)
            and len(item.get("blocks", [])) <= 50
            and all(
                isinstance(block, dict)
                and isinstance(block.get("day"), str)
                and isinstance(block.get("start"), str)
                and isinstance(block.get("end"), str)
                for block in item.get("blocks", [])
            )
            and (
                item.get("remaining_minutes") is None
                or isinstance(item.get("remaining_minutes"), int)
            )
            and (
                item.get("reason") is None
                or isinstance(item.get("reason"), str)
                and len(item["reason"]) <= 1000
            )
            for item in snapshot["items"]
        )
    )


def _target(snapshot: dict, question: str, term: str | None) -> tuple[dict | None, list[str]]:
    items = snapshot["items"]
    low = question.lower()
    supplied = (term or "").lower()
    for item in items:
        if re.search(
            rf"\b{re.escape(item['id'].lower())}\b", f"{low} {supplied}"
        ):
            return item, []
    for word, number in _ORDINALS.items():
        if re.search(rf"\b{word}\b", low) and number <= len(items):
            return items[number - 1], []
    if re.search(r"\blast\b", low) and items:
        return items[-1], []
    numbered = re.search(r"\b(?:number|item|task)\s+(\d{1,2})\b", low)
    if numbered and 1 <= int(numbered.group(1)) <= len(items):
        return items[int(numbered.group(1)) - 1], []

    def scored_matches(words: set[str], minimum: int = 1) -> list[tuple[int, dict]]:
        scored = []
        for item in items:
            overlap = words & _words(item["label"])
            if len(overlap) >= minimum:
                scored.append((len(overlap), item))
        return scored

    scored = scored_matches(_words(question))
    if not scored and supplied:
        exact = [
            item
            for item in items
            if supplied.strip(" ?!.") == item["label"].lower()
        ]
        if len(exact) == 1:
            return exact[0], []
        scored = scored_matches(_words(supplied), minimum=2)
    if scored:
        best = max(score for score, _ in scored)
        matches = [item for score, item in scored if score == best]
        if len(matches) == 1:
            return matches[0], []
        return None, [item["label"] for item in matches[:3]]

    unresolved = [
        item
        for item in items
        if item["outcome"] in {"partial", "deferred", "risk", "unplaced"}
    ]
    if len(unresolved) == 1 and re.search(r"\b(?:fit|placed|risk|left out)\b", low):
        return unresolved[0], []
    return None, []


def _window(snapshot: dict) -> str:
    start = snapshot.get("start_day") or "the recorded day"
    end = snapshot.get("end_day") or start
    return start if start == end else f"{start} through {end}"


def _assumptions(snapshot: dict) -> str:
    preferences = snapshot.get("preferences") or {}
    parts = []
    if preferences.get("work_start") and preferences.get("work_end"):
        parts.append(
            f"planning hours {preferences['work_start']}-{preferences['work_end']}"
        )
    work_days = preferences.get("work_days")
    if isinstance(work_days, list):
        names = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
        labels = [
            names[index]
            for index in work_days
            if isinstance(index, int) and 0 <= index < len(names)
        ]
        if labels:
            parts.append(f"planning days {','.join(labels)}")
    breaks = preferences.get("breaks")
    if isinstance(breaks, list) and breaks:
        windows = [
            f"{window[0]}-{window[1]}"
            for window in breaks[:3]
            if isinstance(window, list)
            and len(window) == 2
            and all(isinstance(value, str) for value in window)
        ]
        if windows:
            parts.append(f"protected {','.join(windows)}")
    budget = preferences.get("budget_minutes")
    if isinstance(budget, int):
        scope = (
            "across the outlook"
            if preferences.get("budget_scope") == "horizon"
            else "per day"
        )
        parts.append(f"a {budget}m stated budget {scope}")
    if preferences.get("earliest_time"):
        parts.append(
            f"a requested start no earlier than {preferences['earliest_time']}"
        )
    if preferences.get("latest_time"):
        parts.append(f"a requested end by {preferences['latest_time']}")
    if preferences.get("energy") == "low":
        parts.append("the stated low-energy constraint")
    if preferences.get("default_duration_minutes") is not None:
        parts.append(
            f"a {preferences['default_duration_minutes']}m visible default estimate"
        )
    if preferences.get("transition_buffer_minutes"):
        parts.append(
            f"a {preferences['transition_buffer_minutes']}m transition buffer"
        )
    calendar = snapshot.get("calendar") or {}
    if calendar.get("total_days") is not None:
        parts.append(
            f"EventKit availability used on {calendar.get('authorized_days', 0)}/"
            f"{calendar['total_days']} day(s)"
        )
    return ", ".join(parts) or "the visible planning profile"


def _options(item: dict) -> str:
    reason = str(item.get("reason") or "").lower()
    remaining = item.get("remaining_minutes")
    amount = f" for {remaining}m" if isinstance(remaining, int) and remaining > 0 else ""
    if "prerequisite" in reason or "depends" in reason:
        return (
            "Resolve the recorded prerequisite, or explicitly change that dependency, "
            "then ask for a new proposal."
        )
    if "planning day" in reason:
        return (
            "Add that day to the visible planning days or choose another day, then ask "
            "for a new proposal."
        )
    if "daylight saving" in reason:
        return (
            "Choose an unambiguous local time, then ask for a new proposal. Hob will "
            "not guess across a daylight-saving clock change."
        )
    if "fixed" in reason and "conflict" in reason:
        return (
            "Move the task's explicit fixed time or remove the conflicting commitment, "
            "then ask for a new proposal."
        )
    if "stated time budget" in reason:
        task_effort = (
            f"the task's {remaining}m"
            if isinstance(remaining, int) and remaining > 0
            else "the task"
        )
        return (
            f"Increase the stated what-if budget enough to cover {task_effort} "
            "plus any visible buffers, reduce the explicit estimate, or allow a "
            "useful split, then ask for a new proposal."
        )
    if "deadline" in reason:
        return (
            f"Make room{amount} plus any visible buffers before the recorded deadline, "
            "reduce the explicit estimate, or change the deadline, then ask for a new "
            "outlook."
        )
    return (
        f"Make room{amount} plus any visible buffers inside the planning window, reduce "
        "the visible estimate, allow splitting when appropriate, or move another "
        "commitment, then ask for a new proposal."
    )


def _scheduled_factors(item: dict) -> str:
    if item.get("fixed"):
        return "its explicit fixed time required that block"
    factors = []
    if item.get("priority") == "high":
        factors.append("high priority")
    if item.get("deadline"):
        factors.append(f"deadline {item['deadline']}")
    if item.get("due_date"):
        factors.append(f"scheduled date {item['due_date']}")
    if item.get("preferred_window"):
        factors.append(f"preferred window {item['preferred_window']}")
    if item.get("earliest_start"):
        factors.append(f"earliest start {item['earliest_start']}")
    dependencies = item.get("depends_on")
    if isinstance(dependencies, list) and dependencies:
        factors.append(f"{len(dependencies)} recorded prerequisite(s)")
    detail = ", ".join(factors)
    base = (
        "the deterministic planner used the first compatible opening after "
        "availability, fixed commitments, protected breaks, and transition buffers"
    )
    return f"{base}; recorded task factors were {detail}" if detail else base


def explain_decision(snapshot: dict, question: str, term: str | None = None) -> str:
    """Explain only recorded facts; never infer or mutate a planning decision."""
    if not _valid(snapshot):
        return (
            'i do not have a usable recent planning result. ask "plan my day" or '
            'use /outlook, then ask why.'
        )
    item, ambiguous = _target(snapshot, question, term)
    if ambiguous:
        choices = " or ".join(f'"{label}"' for label in ambiguous)
        return f"which result did you mean: {choices}?"
    wants_options = bool(
        re.search(
            r"\b(?:what (?:would|needs? to|should) change|how (?:can|could|do) .*fit|"
            r"make .*fit|what would it take)\b",
            question.lower(),
        )
    )
    if item is None:
        counts = {
            outcome: sum(i["outcome"] == outcome for i in snapshot["items"])
            for outcome in ("scheduled", "partial", "deferred", "risk", "unplaced")
        }
        unresolved = (
            counts["partial"]
            + counts["deferred"]
            + counts["risk"]
            + counts["unplaced"]
        )
        return (
            f"the latest {snapshot['kind']} covers {_window(snapshot)}: "
            f"{counts['scheduled']} scheduled result(s) and {unresolved} not fully "
            f"placed or at risk. it used {_assumptions(snapshot)}. name a displayed "
            "task, or say its number, for the exact recorded reason. "
            + (
                "the saved explanation context was capped; regenerate a narrower "
                "result for work beyond it. "
                if snapshot.get("truncated")
                else ""
            )
            + "nothing changed."
        )

    label = item["label"]
    outcome = item["outcome"]
    if outcome == "scheduled":
        blocks = item.get("blocks") or []
        shown = ", ".join(
            f"{block.get('day')} {block.get('start')}-{block.get('end')}"
            for block in blocks[:4]
        ) or "a recorded block"
        estimate = " using the visible default estimate" if item.get("inferred") else ""
        answer = (
            f'"{label}" was scheduled at {shown}{estimate}. '
            f"{_scheduled_factors(item)}."
        )
    else:
        reason = item.get("reason") or "no deterministic placement was recorded"
        remaining = item.get("remaining_minutes")
        left = f" ({remaining}m remaining)" if isinstance(remaining, int) else ""
        blocks = item.get("blocks") or []
        state = {
            "partial": "deferred",
            "risk": "at risk",
            "unplaced": "outside the fit",
        }.get(outcome, outcome)
        if blocks:
            shown = ", ".join(
                f"{block['day']} {block['start']}-{block['end']}"
                for block in blocks[:4]
            )
            if outcome == "risk" and remaining == 0:
                answer = (
                    f'"{label}" was scheduled at {shown}, but it was at risk: '
                    f"{reason}."
                )
            else:
                answer = (
                    f'"{label}" was partly scheduled at {shown}; the remainder was '
                    f"{state}: {reason}{left}."
                )
        else:
            answer = f'"{label}" was {state}: {reason}{left}.'
        if item.get("deadline"):
            answer += f" recorded deadline: {item['deadline']}."
    answer += f" the result used {_assumptions(snapshot)}."
    if wants_options and outcome != "scheduled":
        answer += " " + _options(item)
    answer += " nothing changed."
    return answer
