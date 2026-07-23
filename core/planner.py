# SPDX-License-Identifier: MIT
"""Planner: reconciled Actions plus context -> concrete mutations and questions.

Pure, no I/O. This is where correctness lives: the model's output is a proposal,
not a command.

- Dates: the model never proposes a resolved date; it classifies the phrase into
  a typed intent and core.dates.resolve_intent does the calendar math. The model
  owns understanding, the core owns arithmetic. An intent of kind "ambiguous"
  produces a clarifying question and applies nothing; an unresolvable intent on a
  reschedule also asks.
- References: every target must match a real id in the active list, and
  confidence must clear the threshold; otherwise ask, never mutate.

Mutations are intents, not finished items: the planner is pure, so it cannot
allocate ids or read the clock. The edge (MessageService) materializes them.
"""
from __future__ import annotations

import difflib
import re
from dataclasses import asdict, dataclass, field
from datetime import date, timedelta

from core import dates, recurrence
from core.models import (
    Amend,
    Bulk,
    Capture,
    Chitchat,
    Complete,
    ConfirmationDecision,
    Drop,
    NudgeDecision,
    Note,
    OnboardingDecision,
    PlanAction,
    Prioritize,
    Query,
    Recap,
    Recur,
    Reschedule,
    Resume,
    Schedule,
    Setting,
    Snooze,
    Start,
    Undo,
    Unknown,
    Wait,
)

# Below this, a reference-bearing action (complete/drop/reschedule) is treated as
# a guess and asked about rather than applied.
CONFIDENCE_THRESHOLD = 0.5

# A resolved date further out than this is probably a typo or a joke ("in 200
# years"); confirm before applying rather than scheduling it silently.
FAR_FUTURE_DAYS = 365 * 5


@dataclass
class Mutation:
    kind: str  # capture | complete | drop | reschedule | amend | prioritize
    task: str | None = None
    raw: str | None = None
    due_date: str | None = None
    due_time: str | None = None
    target: str | None = None
    reason: str | None = None
    repeat: str | None = None  # recurrence rule for a capture
    priority: str | None = None  # high|normal|low, for capture and prioritize
    tag: str | None = None  # project/list for a capture
    minutes: int | None = None  # snooze length
    note: str | None = None  # note text (kind=note, or a capture's initial note)
    waiting: bool = False  # capture starts parked on someone else
    deadline_date: str | None = None
    duration_minutes: int | None = None
    duration_confidence: float | None = None
    schedule_kind: str | None = None
    splittable: bool | None = None
    earliest_start: str | None = None
    preferred_window: str | None = None
    parent_id: str | None = None
    depends_on: list[str] | None = None
    reminder_offsets: list[int] | None = None
    recurrence: dict | None = None
    clear: list[str] = field(default_factory=list)
    recur_op: str | None = None
    recur_anchor: str | None = None
    recur_end_date: str | None = None
    recur_count: int | None = None


@dataclass
class QueryIntent:
    kind: str  # today | date | all | overdue | week | search | done | tag |
    #             plan | outlook | explain | what_if
    date: str | None = None  # ISO; query day, planning day, or done-period start
    term: str | None = None  # search keywords, for kind=search
    tag: str | None = None  # project/list name, for kind=tag
    constraint: str | None = None  # user context for kind=plan
    budget_minutes: int | None = None
    budget_scope: str | None = None  # day | horizon
    energy: str | None = None  # low | normal | high
    earliest_time: str | None = None  # HH:MM
    latest_time: str | None = None  # HH:MM
    period: str | None = None  # today | week, for completed-history queries
    target: str | None = None  # exact task id in the latest analysis
    aspect: str | None = None  # why | changes | assumptions
    budget_delta_minutes: int | None = None
    duration_minutes: int | None = None  # temporary what-if estimate
    splittable: bool | None = None  # temporary what-if split permission
    work_start: str | None = None  # temporary what-if working bound
    work_end: str | None = None  # temporary what-if working bound


@dataclass
class SettingChange:
    key: str  # wake_time
    value: str  # validated value, e.g. "06:30"


@dataclass
class Pending:
    """A clarification Hob is waiting on, persisted between turns so a short
    reply ("thursday") can be resolved against the question it answers."""

    kind: str  # capture | reschedule | setting | query | amend
    question: str
    task: str | None = None  # capture: the clean label to re-capture
    target: str | None = None  # reschedule: the item id
    label: str | None = None  # reschedule: human label, for the next prompt
    key: str | None = None  # setting: preference key
    query_kind: str | None = None  # query: original query intent


@dataclass
class ConfirmIntent:
    """Mutations held back for a yes/no. The edge persists them and applies them
    only if the next message confirms. Used for a sweeping delete and for an
    implausibly far-out date that is probably a typo."""

    mutations: list[Mutation] = field(default_factory=list)
    question: str = ""


@dataclass
class Plan:
    mutations: list[Mutation] = field(default_factory=list)
    questions: list[str] = field(default_factory=list)
    queries: list[QueryIntent] = field(default_factory=list)
    pending: list[Pending] = field(default_factory=list)
    confirm: ConfirmIntent | None = None
    undo: bool = False  # the user asked to undo the last change
    settings: list[SettingChange] = field(default_factory=list)
    starts: list[str] = field(default_factory=list)
    plan_action: str | None = None  # adopt | replace | cancel
    chitchat: str | None = None  # a warm reply to a social pleasantry
    acknowledgement: str | None = None  # deterministic mutation-free outcome
    nudge_decision: str | None = None  # accepted digest decision
    confirmation_decision: str | None = None  # approve | reject
    onboarding_decision: str | None = None  # skip | cancel
    bulk_intent: bool = False  # typed bulk scope, used only by safety guards


def _reconcile_recap(action: Recap, ctx) -> Plan:
    """Validate a model-proposed semantic recap against machine-owned context."""
    plan = Plan()
    valid_context = (
        ctx.presented_kind == "eod"
        and bool(ctx.presented_items)
        and not ctx.forwarded_from
        and not ctx.pending
    )
    if (
        action.outcome != "none"
        or action.confidence < CONFIDENCE_THRESHOLD
        or not valid_context
    ):
        plan.questions.append(
            "i could not tie that report to a current evening recap. nothing changed."
        )
        return plan
    count = len(ctx.presented_items)
    if count == 1:
        plan.acknowledgement = (
            "okay. nothing marked done. that item stays open on deck."
        )
    elif count == 2:
        plan.acknowledgement = (
            "okay. nothing marked done. both items stay open on deck."
        )
    else:
        plan.acknowledgement = (
            f"okay. nothing marked done. all {count} items stay open on deck."
        )
    return plan


def _reconcile_nudge(action: NudgeDecision, ctx, today: date) -> Plan:
    """Apply model-owned meaning only to the exact machine-owned nudge target."""
    plan = Plan()
    nudge = ctx.nudge if isinstance(ctx.nudge, dict) else None
    active = {item["id"]: item for item in ctx.active_items}
    item = active.get(nudge.get("item_id")) if nudge else None
    kind = nudge.get("kind") if nudge else None
    allowed = {
        "stale_task": {"keep", "tomorrow", "drop"},
        "waiting": {"resume"},
    }.get(kind, set())
    if (
        action.confidence < CONFIDENCE_THRESHOLD
        or action.decision not in allowed
        or item is None
        or bool(item.get("waiting")) != (kind == "waiting")
        or ctx.forwarded_from
        or ctx.pending
        or ctx.confirmation_pending
        or ctx.onboarding_stage
    ):
        plan.questions.append(
            "i could not tie that decision to the current digest question. "
            "nothing changed."
        )
        return plan
    target = item["id"]
    if action.decision == "tomorrow":
        mutation = Mutation(
            kind="reschedule",
            target=target,
            due_date=(today + timedelta(days=1)).isoformat(),
        )
    else:
        mutation = Mutation(
            kind={"keep": "keep", "drop": "drop", "resume": "resume"}[
                action.decision
            ],
            target=target,
        )
    plan.mutations.append(mutation)
    plan.nudge_decision = action.decision
    return plan


def _reconcile_confirmation(action: ConfirmationDecision, ctx) -> Plan:
    plan = Plan()
    if (
        not ctx.confirmation_pending
        or ctx.forwarded_from
        or action.confidence < CONFIDENCE_THRESHOLD
        or action.decision not in {"approve", "reject"}
    ):
        plan.questions.append(
            "i could not verify a current confirmation. nothing changed."
        )
        return plan
    plan.confirmation_decision = action.decision
    return plan


def _reconcile_onboarding(action: OnboardingDecision, ctx) -> Plan:
    plan = Plan()
    if (
        not ctx.onboarding_stage
        or ctx.forwarded_from
        or action.confidence < CONFIDENCE_THRESHOLD
        or action.decision not in {"skip", "cancel"}
    ):
        plan.questions.append("setup is not waiting for that choice. nothing changed.")
        return plan
    plan.onboarding_decision = action.decision
    return plan


def _too_far(due_iso: str, today: date) -> int | None:
    """If a resolved date is implausibly far out, the rough number of years out;
    otherwise None."""
    try:
        days = (date.fromisoformat(due_iso) - today).days
    except (TypeError, ValueError):
        return None
    return round(days / 365) if days > FAR_FUTURE_DAYS else None


def _hold(plan: Plan, mutation: Mutation, question: str) -> None:
    """Stash a mutation for yes/no confirmation instead of applying it."""
    if plan.confirm is None:
        plan.confirm = ConfirmIntent()
    plan.confirm.mutations.append(mutation)
    plan.confirm.question = question


_NUM_WORDS = {
    "one": "1", "first": "1", "two": "2", "second": "2", "three": "3",
    "third": "3", "four": "4", "fourth": "4", "five": "5", "fifth": "5",
    "six": "6", "sixth": "6", "seven": "7", "seventh": "7", "eight": "8",
    "eighth": "8", "nine": "9", "ninth": "9", "ten": "10", "tenth": "10",
}


def _resolve_ref(ref: str, active: dict, by_pos: dict) -> str | None:
    """Map a target/relate reference to a stored id, tolerating the forms the
    model emits: an id (a1, any case), a list position (2), a stray "id:"/"#"
    prefix, a spelled ordinal (first/second), or the whole "id: label (due ...)"
    line copied verbatim (we take the leading token)."""
    if not ref:
        return None
    r = ref.strip().lower().removeprefix("id:").removeprefix("#").strip()
    r = _NUM_WORDS.get(r, r)
    if r in active:
        return r
    if r in by_pos:
        return by_pos[r]  # a 1-based list position
    # The model sometimes copies the whole list line ("a3: review the SR audit");
    # the id or position it put first still identifies the item.
    head = r.replace(":", " ").split()
    if head:
        first = _NUM_WORDS.get(head[0], head[0])
        if first in active:
            return first
        if first in by_pos:
            return by_pos[first]
    # Last resort: a noisy target carrying a trailing position ("url_not_provided_2",
    # "item 2"). The trailing number still points at the displayed item.
    tail = ""
    for ch in reversed(r):
        if ch.isdigit():
            tail = ch + tail
        else:
            break
    return by_pos.get(tail) if tail else None


def _check_target(
    target: str,
    confidence: float,
    active: dict,
    by_pos: dict,
    plan: Plan,
    *,
    proposed: Mutation | None = None,
    verb: str = "make that change",
) -> str | None:
    """Validate a reference. Queue a question and return None if it does not
    resolve confidently; otherwise return the id. Accepts an id or a position."""
    key = _resolve_ref(target, active, by_pos)
    if key is None:
        plan.questions.append("i could not find that item. check /today for the list.")
        return None
    if confidence < CONFIDENCE_THRESHOLD:
        if proposed is not None:
            proposed.target = key
            _hold(
                plan,
                proposed,
                f'did you mean "{active[key]}"? tell me whether to {verb} or cancel.',
            )
        else:
            plan.questions.append(
                f'i am not sure you meant "{active[key]}". say the task name again.'
            )
        return None
    return key


_REMINDER_PREFIXES = ("remind me to ", "remember to ", "dont forget to ", "don't forget to ")

# Trailing date/time phrases the model sometimes leaves in a label ("update gdp
# tomorrow night"). We strip ONLY the unambiguous ones: "tomorrow"/"tonight"/
# "today"/"yesterday" (with an optional part-of-day) and a trailing "at <time>".
# Bare "day"/"night"/weekday names are left alone because they are also real
# label words ("plan my day tomorrow" -> "plan my day"), so this never
# over-strips. Genuinely ambiguous tails ("during day", "monday") stay as-is.
_LABEL_DAY_TAIL = re.compile(
    r"\s+(tomorrow|tonight|today|yesterday)"
    r"(\s+(morning|afternoon|evening|night))?$",
    re.IGNORECASE,
)
_LABEL_TIME_TAIL = re.compile(
    r"\s+at\s+(\d{1,2}(:\d{2})?\s*(am|pm)?|noon|midnight)$",
    re.IGNORECASE,
)


# Reference / negation guards: the model resolves a description or a "did/didn't"
# report to an item, but on a typo it grabs the wrong item, and it inverts
# negations. These deterministic passes verify the model's target against the
# literal words: a mismatched target with a strong typo elsewhere becomes a "did
# you mean" confirm, and a target named in a negated clause is dropped. Favor
# asking over acting; never silently complete the wrong thing.
_REF_STOP = {
    "the", "a", "an", "my", "that", "this", "it", "one", "ones", "thing",
    "things", "task", "tasks", "did", "do", "done", "finish", "finished",
    "complete", "completed", "drop", "dropped", "cancel", "cancelled", "delete",
    "deleted", "remove", "removed", "already", "just", "please", "and", "but",
    "also", "for", "to", "of", "in", "on", "at", "is", "was", "i", "we", "you",
    "hob", "today", "yesterday", "tonight", "off", "out", "up",
    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
    "ninth", "tenth", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten",
}
_NEG_TOKENS = {
    "not", "never", "skip", "skipped", "no", "cant", "couldnt", "wasnt", "wont",
    "dont", "doesnt", "didnt", "havent", "wouldnt",
}
_MATCH = 0.8  # SequenceMatcher ratio for "this word is that word, typo aside"


def _words(text: str) -> list[str]:
    return [w for w in re.findall(r"[a-z]+", (text or "").lower())
            if len(w) >= 3 and w not in _REF_STOP]


def _word_hits(word: str, label_words: list[str]) -> bool:
    for lw in label_words:
        if word == lw or (len(word) >= 4 and len(lw) >= 4 and (word in lw or lw in word)):
            return True
        if difflib.SequenceMatcher(None, word, lw).ratio() >= _MATCH:
            return True
    return False


def _label_supports(words: list[str], label: str) -> bool:
    lw = _words(label)
    return any(_word_hits(w, lw) for w in words)


def _best_item(words: list[str], active_items: list[dict]) -> tuple[dict | None, float]:
    best, best_score = None, 0.0
    for item in active_items:
        lw = _words(item.get("label", ""))
        score = max((difflib.SequenceMatcher(None, w, l).ratio()
                     for w in words for l in lw), default=0.0)
        if score > best_score:
            best, best_score = item, score
    return best, best_score


def _negated_words(message: str) -> set[str]:
    """Content words that sit in a negated clause. 'did A, did not B' negates
    only B; 'but' resets polarity ('didnt do A but did B')."""
    msg = message.lower().replace("n't", " not").replace("’", "'")
    negated: set[str] = set()
    for clause in re.split(r"[,;]| and | but ", msg):
        toks = re.findall(r"[a-z]+", clause)
        if any(t in _NEG_TOKENS for t in toks):
            negated.update(w for w in toks if len(w) >= 3 and w not in _REF_STOP)
    return negated


def _confirm_did_you_mean(item: dict, kind: str) -> ConfirmIntent:
    verb = "mark it done" if kind == "complete" else "drop it"
    return ConfirmIntent(
        mutations=[Mutation(kind=kind, target=item["id"])],
        question=f'did you mean "{item["label"]}"? tell me whether to {verb} or cancel.',
    )


def _apply_reference_guards(plan: Plan, ctx) -> None:
    labels = {i["id"]: i.get("label", "") for i in ctx.active_items}

    # 1. Suppress mutations whose target sits in a negated clause: the user said
    # they did NOT do it, so completing/parking/noting it is an inversion.
    negated = _negated_words(ctx.message)
    if negated:
        kept = []
        for m in plan.mutations:
            if m.kind in ("complete", "drop", "wait", "note") and m.target and any(
                _word_hits(w, _words(labels.get(m.target, ""))) for w in negated
            ):
                continue  # target sits in a negated clause: user did NOT do it
            if m.kind == "capture":
                content = _words(m.task or m.raw or "")
                best, score = _best_item(content, ctx.active_items) if content else (None, 0.0)
                is_negation = bool(content) and all(w in negated for w in content)
                dupes_negated = best is not None and score >= _MATCH and any(
                    _word_hits(w, _words(best.get("label", ""))) for w in negated
                )
                if is_negation or dupes_negated:
                    continue  # the model captured the negation, or re-captured a
                    #            task the user said they did NOT do
            kept.append(m)
        plan.mutations = kept

    # 2. A lone complete/drop whose target the words do not support, when a
    # different item is a strong typo match ("table thing" -> "fable"): confirm
    # the right item instead of silently completing the wrong one. Skipped when
    # the message excludes or negates an item, since then a strongly-matched word
    # ("everything but the audit") is the item left OUT, not the target.
    if len(plan.mutations) == 1 and plan.mutations[0].kind in ("complete", "drop") \
            and plan.confirm is None and not negated and not plan.bulk_intent:
        mut = plan.mutations[0]
        words = _words(ctx.message)
        target_label = labels.get(mut.target, "")
        if words and target_label and not _label_supports(words, target_label):
            best, score = _best_item(words, ctx.active_items)
            if best is not None and best["id"] != mut.target and score >= _MATCH:
                plan.mutations = []
                plan.confirm = _confirm_did_you_mean(best, mut.kind)


def _is_typo_correction(message: str) -> bool:
    """A short message ending in '*' is the texting convention for correcting a
    typo in the previous message ("Hobbie*"), not a task. Kept short so a real
    sentence that happens to end in '*' is not swallowed."""
    m = message.strip()
    return len(m) > 1 and m.endswith("*") and len(m.split()) <= 4


def _clean_label(task: str | None) -> str | None:
    """Strip capture-phrasing the model echoes into labels: a "remind me to"
    prefix and an unambiguous trailing date/time phrase."""
    if not task:
        return task
    low = task.lower()
    for prefix in _REMINDER_PREFIXES:
        if low.startswith(prefix):
            task = task[len(prefix):]
            break
    prev = None
    while task != prev:
        prev = task
        for pat in (_LABEL_TIME_TAIL, _LABEL_DAY_TAIL):
            stripped = pat.sub("", task).strip()
            if stripped:  # never strip a label down to nothing
                task = stripped
    return task


def _clean_temporal_label(action: Capture) -> str | None:
    """Trim constraint clauses a model occasionally leaves in a capture label."""
    label = _clean_label(action.task)
    if not label:
        return label
    if ";" in label:
        label = label.split(";", 1)[0].strip()
    if action.repeat:
        label = re.split(
            r"\s+(?:every\s+\d+|every\s+(?:day|week|month|year|mon|tue|wed|thu|fri|sat|sun)|daily|weekdays)\b",
            label,
            maxsplit=1,
            flags=re.IGNORECASE,
        )[0].strip()
    if action.deadline:
        label = re.split(
            r"\s+(?:due|by|before|no later than)\b",
            label,
            maxsplit=1,
            flags=re.IGNORECASE,
        )[0].strip()
    if action.duration_minutes:
        label = re.split(
            r"\s+(?:and\s+)?takes?\b",
            label,
            maxsplit=1,
            flags=re.IGNORECASE,
        )[0].strip()
    if action.when:
        label = re.sub(
            r"\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tomorrow)$",
            "",
            label,
            flags=re.IGNORECASE,
        ).strip()
    return label or _clean_label(action.task)


_WINDOWS = {"morning", "afternoon", "evening"}
_CLOCK_WINDOW = re.compile(r"^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$")
_CLEARABLE = {"deadline", "duration", "earliest", "window", "dependencies", "reminders"}
def _window(value: str | None) -> str | None:
    if not value:
        return None
    normalized = value.strip().lower()
    return normalized if normalized in _WINDOWS or _CLOCK_WINDOW.match(normalized) else None


def _offsets(values: list[int]) -> list[int]:
    return sorted({value for value in values if 0 <= value <= 7 * 24 * 60}, reverse=True)


def _resolve_refs(refs: list[str], active: dict, by_pos: dict) -> tuple[list[str], bool]:
    resolved: list[str] = []
    missing = False
    for ref in refs:
        target = _resolve_ref(ref, active, by_pos)
        if target is None:
            missing = True
        elif target not in resolved:
            resolved.append(target)
    return resolved, missing


def _start_value(when, raw_time: str | None, today: date) -> tuple[str | None, bool]:
    resolution = dates.resolve_intent(when, today)
    parsed_time = dates.parse_time(raw_time)
    if resolution.ambiguous:
        return None, True
    start_date = resolution.date
    if parsed_time and start_date is None:
        start_date = today.isoformat()
    if start_date and parsed_time:
        return f"{start_date}T{parsed_time}", False
    return start_date, False


def _reconcile_capture(
    action: Capture,
    today: date,
    active_due: dict,
    by_pos: dict,
    plan: Plan,
) -> None:
    resolution = dates.resolve_intent(action.when, today)
    deadline = dates.resolve_intent(action.deadline, today)
    if resolution.ambiguous:
        question = f'when is "{action.task}" due? the date was not clear.'
        plan.questions.append(question)
        plan.pending.append(
            Pending(kind="capture", question=question, task=action.task)
        )
        return

    due_date = resolution.date
    if due_date is None and action.relate:
        # A task for an existing item (e.g. "bring soda" for a birthday) with no
        # date of its own inherits that item's date so it surfaces with it.
        rid = _resolve_ref(action.relate, active_due, by_pos)
        due_date = active_due.get(rid) if rid else None

    repeat = recurrence.normalize(action.repeat)
    if deadline.ambiguous:
        plan.questions.append(f'what is the hard deadline for "{action.task}"?')
        return
    earliest_start, earliest_ambiguous = _start_value(
        action.earliest, action.earliest_time, today
    )
    if earliest_ambiguous:
        plan.questions.append(f'when can "{action.task}" start?')
        return
    if deadline.date and due_date and due_date > deadline.date:
        plan.questions.append(
            f'the planned date for "{action.task}" is after its deadline. which date should change?'
        )
        return
    if deadline.date and earliest_start and earliest_start[:10] > deadline.date:
        plan.questions.append(
            f'"{action.task}" cannot start after its deadline. which constraint should change?'
        )
        return
    parent_id = _resolve_ref(action.parent, active_due, by_pos) if action.parent else None
    if action.parent and parent_id is None:
        plan.questions.append("i could not find the parent task. check /list and try again.")
        return
    dependencies, missing_dependency = _resolve_refs(
        action.depends_on, active_due, by_pos
    )
    if missing_dependency:
        plan.questions.append("i could not find one dependency. check /list and try again.")
        return
    repeat_end = dates.resolve_intent(action.repeat_end, today)
    if repeat_end.ambiguous and not action.repeat_count:
        plan.questions.append(f'when should "{action.task}" stop repeating?')
        return
    if repeat_end.ambiguous:
        repeat_end = dates.DateResolution()
    structured = recurrence.parse(
        repeat,
        anchor=action.repeat_anchor,
        end_date=repeat_end.date,
        count=action.repeat_count,
    )
    if structured is not None:
        # A recurring task's date is its next occurrence, decided by the rule.
        first = recurrence.next_due(structured, today, inclusive=True)
        if first is not None:
            due_date = first.isoformat()
            structured.anchor_date = first.isoformat()
    # The model classifies dates (when); a clock time it parses directly (time).
    due_time = dates.parse_time(action.time)

    mutation = Mutation(
        kind="capture",
        task=_clean_temporal_label(action),
        raw=action.raw,
        due_date=due_date,
        due_time=due_time,
        repeat=repeat,
        priority=action.priority,
        tag=action.tag,
        note=action.note,
        waiting=action.waiting,
        deadline_date=deadline.date,
        duration_minutes=(
            action.duration_minutes
            if action.duration_minutes and 1 <= action.duration_minutes <= 10080
            else None
        ),
        duration_confidence=(
            max(0.0, min(1.0, action.duration_confidence or 1.0))
            if action.duration_minutes
            else None
        ),
        schedule_kind=(
            "fixed" if action.schedule_kind == "fixed" else "flexible"
        ),
        splittable=bool(action.splittable),
        earliest_start=earliest_start,
        preferred_window=_window(action.preferred_window),
        parent_id=parent_id,
        depends_on=dependencies,
        reminder_offsets=_offsets(action.reminder_offsets),
        recurrence=asdict(structured) if structured else None,
    )
    years = _too_far(due_date, today) if due_date else None
    if years is not None:
        _hold(plan, mutation, f"that is {due_date}, about {years} years out. confirm or cancel it.")
        return
    plan.mutations.append(mutation)


def _reconcile_amend(action: Amend, active: dict, by_pos: dict, plan: Plan) -> None:
    target = _check_target(
        action.target,
        action.confidence,
        active,
        by_pos,
        plan,
        proposed=Mutation(kind="amend", task=action.task),
        verb="rename it",
    )
    if target is None:
        return
    if not action.task:
        question = f'what should "{active[target]}" say now?'
        plan.questions.append(question)
        plan.pending.append(
            Pending(kind="amend", question=question, target=target, label=active[target])
        )
        return
    plan.mutations.append(Mutation(kind="amend", target=target, task=action.task))


def _grounded_literal(raw: str, message: str) -> bool:
    """True when the model echoed actual user words instead of inventing a value."""
    normalize = lambda value: " ".join(re.findall(r"[a-z0-9:]+", value.lower()))
    literal = normalize(raw)
    return bool(literal) and literal in normalize(message)


def _setting_question(action: Setting, plan: Plan, question: str) -> None:
    plan.questions.append(question)
    plan.pending.append(Pending(kind="setting", question=question, key=action.key))


def _setting_value_question(key: str) -> str:
    return {
        "wake_time": "what time should i send the morning digest?",
        "eod_time": "what time should i send the evening recap?",
        "work_hours": "what start and end time should i use for the working hours?",
        "break_window": "what start and end time should i use for the protected break?",
        "work_days": "which weekdays may i plan flexible work on?",
        "default_duration": "how many minutes should i use for the default task estimate?",
        "transition_buffer": "how many minutes should i use for the transition buffer?",
    }.get(key, "what value should i use?")


def _reconcile_setting(action: Setting, message: str, plan: Plan) -> None:
    if action.confidence < CONFIDENCE_THRESHOLD or not _grounded_literal(
        action.raw, message
    ):
        _setting_question(
            action,
            plan,
            "i could not verify that setting value in your message. nothing changed. "
            + _setting_value_question(action.key),
        )
        return
    if action.key in ("wake_time", "eod_time"):
        literal = dates.parse_time(action.raw)
        value = dates.parse_time(action.time)
        if value is None or literal != value:
            what = "morning digest" if action.key == "wake_time" else "evening recap"
            _setting_question(action, plan, f"what time should i send the {what}?")
            return
        plan.settings.append(SettingChange(key=action.key, value=value))
    elif action.key in ("work_hours", "break_window"):
        if action.key == "break_window" and action.clear:
            plan.settings.append(SettingChange(key=action.key, value="none"))
            return
        literal = _parse_time_range(action.raw)
        start = dates.parse_time(action.start_time)
        end = dates.parse_time(action.end_time)
        value = f"{start}-{end}" if start and end and end > start else None
        if value is None or literal != value:
            what = "working hours" if action.key == "work_hours" else "protected break"
            _setting_question(
                action, plan, f"what start and end time should i use for the {what}?"
            )
            return
        plan.settings.append(SettingChange(key=action.key, value=value))
    elif action.key == "work_days":
        days = list(dict.fromkeys(day.lower() for day in action.days))
        if not days or any(day not in _DAY_CODES for day in days):
            _setting_question(
                action, plan, "which weekdays may i plan flexible work on?"
            )
            return
        ordered = [day for day in _DAY_CODES if day in days]
        plan.settings.append(SettingChange(key=action.key, value=",".join(ordered)))
    elif action.key in ("default_duration", "transition_buffer"):
        value = 0 if action.key == "transition_buffer" and action.clear else action.minutes
        literal = _parse_minutes(action.raw)
        low, high = (5, 480) if action.key == "default_duration" else (0, 120)
        if value is None or literal != value or not low <= value <= high:
            what = (
                "default task estimate"
                if action.key == "default_duration"
                else "transition buffer"
            )
            _setting_question(
                action, plan, f"how many minutes should i use for the {what}?"
            )
            return
        plan.settings.append(SettingChange(key=action.key, value=str(value)))
    else:
        plan.questions.append(
            "i can change digest, recap, work hours, work days, breaks, "
            "default effort, and buffers."
        )


def _parse_time_range(raw: str) -> str | None:
    """Parse a literal daily range, inferring an unmarked afternoon end."""
    token = r"(?:noon|midday|midnight|\d{1,2}(?::\d{2})?\s*(?:am|pm)?)"
    match = re.search(
        rf"({token})\s*(?:to|through|until|-)\s*({token})",
        raw.strip(),
        re.I,
    )
    if not match:
        return None
    def one(value: str) -> str | None:
        low = value.strip().lower()
        if low in {"noon", "midday"}:
            return "12:00"
        if low == "midnight":
            return "00:00"
        return dates.parse_time(value.strip())

    start = one(match.group(1))
    end = one(match.group(2))
    if start is None or end is None:
        return None
    if end <= start and not re.search(r"\b(am|pm)\b", match.group(2), re.I):
        hour, minute = map(int, end.split(":"))
        if hour < 12:
            end = f"{hour + 12:02d}:{minute:02d}"
    return f"{start}-{end}" if end > start else None


def _parse_minutes(raw: str) -> int | None:
    low = raw.strip().lower()
    if re.search(r"\b(?:no|zero)\s+(?:buffer|minutes?)\b|\bnone\b", low):
        return 0
    if "half an hour" in low or "half hour" in low:
        return 30
    if "quarter of an hour" in low or "quarter hour" in low:
        return 15
    if re.search(r"\b(?:an|one) hour\b", low):
        return 60
    hours = re.search(r"\b(\d+(?:\.\d+)?)\s*(?:hours?|hrs?)\b", low)
    if hours:
        return round(float(hours.group(1)) * 60)
    match = re.search(r"\b(\d+)\s*(minutes?|mins?)?\b", low)
    return int(match.group(1)) if match else None


_DAY_CODES = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


def _reconcile_prioritize(
    action: Prioritize, active: dict, by_pos: dict, plan: Plan
) -> None:
    target = _check_target(
        action.target,
        action.confidence,
        active,
        by_pos,
        plan,
        proposed=Mutation(kind="prioritize", priority=action.level),
        verb="change its priority",
    )
    if target is None:
        return
    level = action.level if action.level in ("high", "normal", "low") else "normal"
    plan.mutations.append(Mutation(kind="prioritize", target=target, priority=level))


def _reconcile_schedule(
    action: Schedule,
    today: date,
    active: dict,
    by_pos: dict,
    plan: Plan,
) -> None:
    target = _check_target(
        action.target,
        action.confidence,
        active,
        by_pos,
        plan,
        proposed=Mutation(kind="schedule"),
        verb="change its scheduling constraints",
    )
    if target is None:
        return
    deadline = dates.resolve_intent(action.deadline, today)
    if deadline.ambiguous:
        plan.questions.append(f'what is the hard deadline for "{active[target]}"?')
        return
    earliest_start, ambiguous = _start_value(
        action.earliest, action.earliest_time, today
    )
    if ambiguous:
        plan.questions.append(f'when can "{active[target]}" start?')
        return
    dependencies, missing = _resolve_refs(action.depends_on, active, by_pos)
    if missing:
        plan.questions.append("i could not find one dependency. check /list and try again.")
        return
    dependencies = [item_id for item_id in dependencies if item_id != target]
    clear = [name for name in action.clear if name in _CLEARABLE]
    mutation = Mutation(
        kind="schedule",
        target=target,
        deadline_date=deadline.date,
        duration_minutes=(
            action.duration_minutes
            if action.duration_minutes and 1 <= action.duration_minutes <= 10080
            else None
        ),
        duration_confidence=(
            max(0.0, min(1.0, action.duration_confidence or 1.0))
            if action.duration_minutes
            else None
        ),
        schedule_kind=(
            action.schedule_kind
            if action.schedule_kind in ("fixed", "flexible")
            else None
        ),
        splittable=action.splittable,
        earliest_start=earliest_start,
        preferred_window=_window(action.preferred_window),
        depends_on=dependencies if action.depends_on else None,
        reminder_offsets=(
            _offsets(action.reminder_offsets) if action.reminder_offsets else None
        ),
        clear=clear,
    )
    changed = any(
        value is not None
        for value in (
            mutation.deadline_date,
            mutation.duration_minutes,
            mutation.schedule_kind,
            mutation.splittable,
            mutation.earliest_start,
            mutation.preferred_window,
            mutation.depends_on,
            mutation.reminder_offsets,
        )
    ) or bool(clear)
    if not changed:
        plan.questions.append("which deadline, duration, window, dependency, or reminder should change?")
        return
    years = _too_far(deadline.date, today) if deadline.date else None
    if years is not None:
        _hold(
            plan,
            mutation,
            f'that deadline is {deadline.date}, about {years} years out. confirm or cancel it.',
        )
        return
    plan.mutations.append(mutation)


def _reconcile_recur(
    action: Recur, today: date, active: dict, by_pos: dict, plan: Plan
) -> None:
    target = _check_target(
        action.target,
        action.confidence,
        active,
        by_pos,
        plan,
        proposed=Mutation(kind="recur", recur_op=action.op),
        verb="change that recurring series",
    )
    if target is None:
        return
    end = dates.resolve_intent(action.end, today)
    if end.ambiguous:
        plan.questions.append(f'when should "{active[target]}" stop repeating?')
        return
    plan.mutations.append(
        Mutation(
            kind="recur",
            target=target,
            recur_op=action.op,
            recur_anchor=(
                action.anchor if action.anchor in ("fixed", "completion") else None
            ),
            recur_end_date=end.date,
            recur_count=action.count if action.count and action.count > 0 else None,
        )
    )


def _reconcile_reschedule(
    action: Reschedule, today: date, active: dict, by_pos: dict, ctx, plan: Plan
) -> None:
    # Resolve the reference first, then hold the fully resolved move if confidence
    # is low. That makes the subsequent "yes" deterministic and resumable.
    target = _resolve_ref(action.target, active, by_pos)
    if target is None:
        plan.questions.append("i could not find that item. check /today for the list.")
    if target is None:
        return
    label = active[target]

    resolution = dates.resolve_intent(action.when, today)
    new_time = dates.parse_time(action.time)
    low = ctx.message.lower()

    # A time-only reschedule with no conversational anchor and no overlap with
    # the item's own words is a guess ("make it 4pm" out of nowhere): ask.
    if new_time is not None and resolution.date is None:
        anchored = bool(ctx.focus) or bool(ctx.replied)
        overlap = set(label.lower().split()) & set(low.split())
        if not anchored and not overlap:
            plan.questions.append(f'did you want to move "{label}"? if so, say which task.')
            return

    if resolution.ambiguous:
        question = f'when should i move "{label}" to? the date was not clear.'
        plan.questions.append(question)
        plan.pending.append(
            Pending(kind="reschedule", question=question, target=target, label=label)
        )
        return
    if resolution.date is None and new_time is None:
        question = f'to when should i move "{label}"?'
        plan.questions.append(question)
        plan.pending.append(
            Pending(kind="reschedule", question=question, target=target, label=label)
        )
        return

    mutation = Mutation(
        kind="reschedule", target=target, due_date=resolution.date, due_time=new_time
    )
    if resolution.date is not None:
        years = _too_far(resolution.date, today)
        if years is not None:
            _hold(plan, mutation, f'move "{label}" to {resolution.date}, about {years} years out. confirm or cancel it.')
            return
    if action.confidence < CONFIDENCE_THRESHOLD:
        _hold(
            plan,
            mutation,
            f'did you mean "{label}"? confirm the move or cancel it.',
        )
        return
    plan.mutations.append(mutation)


def _in_scope(item: dict, scope: str, today: str, target_date: str | None) -> bool:
    """Whether an open item falls in a bulk action's scope. 'today' mirrors the
    digest's on-deck set: undated, due today, or overdue (future and parked
    waiting items excluded)."""
    due = item.get("due_date")
    if scope == "all":
        return True
    if scope == "date":
        return due == target_date
    if item.get("waiting"):
        return False  # parked on someone else: not part of "today's stuff"
    return due is None or due <= today


def _reconcile_bulk(action: Bulk, today: date, ctx, plan: Plan) -> None:
    plan.bulk_intent = True
    if action.op not in ("complete", "drop", "reschedule"):
        plan.questions.append("i did not catch a task there. can you rephrase?")
        return
    scope = (
        action.scope
        if action.scope in ("today", "all", "date", "presented")
        else "today"
    )
    when = dates.resolve_intent(action.when, today)
    target_date = None
    if scope == "date":
        if when.ambiguous or when.date is None:
            plan.questions.append("which day did you mean?")
            return
        target_date = when.date
    if scope == "presented":
        displayed = ctx.presented_items or ctx.last_digest
        if not displayed:
            plan.questions.append("which list did you mean? i changed nothing.")
            return
        presented_ids = {item["id"] for item in displayed}
        matching = [i for i in ctx.active_items if i["id"] in presented_ids]
    else:
        matching = [
            i for i in ctx.active_items
            if _in_scope(i, scope, ctx.today, target_date)
        ]
    if not matching:
        plan.questions.append("nothing matched, so i changed nothing.")
        return
    active_all = {i["id"]: i.get("label", "") for i in ctx.active_items}
    position_items = _position_items(ctx, presented=scope == "presented")
    positions = {
        str(n): item["id"] for n, item in enumerate(position_items, start=1)
    }
    excluded = {
        r for r in (
            _resolve_ref(e, active_all, positions) for e in action.exclude
        )
        if r is not None
    }
    ids = [i["id"] for i in matching if i["id"] not in excluded]
    if not ids:
        plan.questions.append("that excluded everything, so i changed nothing.")
        return
    if action.confidence < CONFIDENCE_THRESHOLD:
        # A sweeping mutation is the last place to guess. Hold the exact typed
        # set for an explicit, separately interpreted confirmation.
        verb = {
            "complete": "finish",
            "drop": "drop",
            "reschedule": "move",
        }[action.op]
        proposed = [
            Mutation(
                kind=action.op,
                target=item_id,
                due_date=when.date if action.op == "reschedule" else None,
            )
            for item_id in ids
        ]
        plan.confirm = ConfirmIntent(
            mutations=proposed,
            question=(
                f"that would {verb} {len(ids)} open item(s). "
                "confirm or cancel that change?"
            ),
        )
        return
    if action.op == "reschedule":
        # Move them all to one destination date (non-destructive, so no confirm).
        if when.ambiguous or when.date is None:
            plan.questions.append("to when should i move them?")
            return
        for item_id in ids:
            plan.mutations.append(
                Mutation(kind="reschedule", target=item_id, due_date=when.date)
            )
        return
    # Deleting across more than one day is a big swing: hold it for a yes/no.
    if action.op == "drop":
        days = {(i.get("due_date") or "undated") for i in matching}
        if len(days) > 1:
            plan.confirm = ConfirmIntent(
                mutations=[Mutation(kind="drop", target=i) for i in ids],
                question=(
                    f"that deletes {len(ids)} items across {len(days)} days. "
                    "confirm or cancel that change."
                ),
            )
            return
    for item_id in ids:
        plan.mutations.append(Mutation(kind=action.op, target=item_id))


def _typed_query(
    action: Query,
    *,
    kind: str,
    date_value: str | None = None,
    constraint: str | None = None,
) -> QueryIntent:
    budget = (
        action.budget_minutes
        if action.budget_minutes is not None
        and 1 <= action.budget_minutes <= 7 * 24 * 60
        else None
    )
    earliest = dates.parse_time(action.earliest_time)
    latest = dates.parse_time(action.latest_time)
    if earliest and latest and earliest >= latest:
        earliest = latest = None
    return QueryIntent(
        kind=kind,
        date=date_value,
        constraint=constraint,
        budget_minutes=budget,
        budget_scope=(
            action.budget_scope
            if action.budget_scope in {"day", "horizon"}
            else None
        ),
        energy=action.energy if action.energy in {"low", "normal", "high"} else None,
        earliest_time=earliest,
        latest_time=latest,
        period=action.period if action.period in {"today", "week"} else None,
    )


def _reconcile_query(action: Query, today: date, ctx, plan: Plan) -> None:
    kind, term = action.kind, action.term
    if kind in {"explain", "what_if"}:
        analysis = ctx.analysis if isinstance(ctx.analysis, dict) else None
        analysis_kind = analysis.get("kind") if analysis else None
        if analysis_kind not in {"plan", "outlook"}:
            plan.questions.append(
                "ask me to plan a day or check your outlook first, then ask why "
                "or try a what-if."
            )
            return
        item_ids = {
            str(item_id)
            for item_id in analysis.get("item_ids", [])
            if isinstance(item_id, str)
        }
        target = action.target
        if target and target not in item_ids:
            if kind == "explain" and action.aspect in {
                "changes", "assumptions"
            }:
                # Those aspects can validly address the whole saved result.
                # An invented task id never reaches an item-specific claim.
                target = None
            else:
                plan.questions.append(
                    "i could not tie that task to the latest plan or outlook. "
                    "nothing changed."
                )
                return
        if kind == "explain":
            plan.queries.append(
                QueryIntent(
                    kind="explain",
                    target=target,
                    aspect=(
                        action.aspect
                        if action.aspect in {"why", "changes", "assumptions"}
                        else "why"
                    ),
                    constraint=action.constraint or ctx.message,
                )
            )
            return
        active_ids = {
            str(item.get("id"))
            for item in ctx.active_items
            if item.get("id") is not None
        }
        if target and target not in active_ids:
            plan.questions.append(
                "that task is no longer open, so i did not run the hypothetical."
            )
            return
        duration = (
            action.duration_minutes
            if isinstance(action.duration_minutes, int)
            and 5 <= action.duration_minutes <= 480
            else None
        )
        budget = (
            action.budget_minutes
            if isinstance(action.budget_minutes, int)
            and 1 <= action.budget_minutes <= 10080
            else None
        )
        delta = (
            action.budget_delta_minutes
            if isinstance(action.budget_delta_minutes, int)
            and -10080 <= action.budget_delta_minutes <= 10080
            and action.budget_delta_minutes != 0
            else None
        )
        energy = (
            action.energy
            if action.energy in {"low", "normal", "high"}
            else None
        )
        earliest = dates.parse_time(action.earliest_time)
        latest = dates.parse_time(action.latest_time)
        if earliest and latest and earliest >= latest:
            plan.questions.append(
                "the temporary working window needs a start before its end. "
                "nothing changed."
            )
            return
        clock_pattern = re.compile(r"^(?:[01]\d|2[0-3]):[0-5]\d$")
        work_start = (
            action.work_start
            if action.work_start and clock_pattern.fullmatch(action.work_start)
            else None
        )
        work_end = (
            action.work_end
            if action.work_end and clock_pattern.fullmatch(action.work_end)
            else None
        )
        if work_start and work_end and work_start >= work_end:
            plan.questions.append(
                "the temporary working bounds need a start before their end. "
                "nothing changed."
            )
            return
        if not any(
            value is not None
            for value in (
                duration,
                budget,
                delta,
                energy,
                earliest,
                latest,
                action.splittable,
                work_start,
                work_end,
            )
        ):
            plan.questions.append(
                "what assumption should i test—available minutes, working "
                "window, energy, task estimate, or split permission?"
            )
            return
        if (duration is not None or action.splittable is not None) and not target:
            plan.questions.append(
                "which task should use that temporary estimate or split assumption?"
            )
            return
        plan.queries.append(
            QueryIntent(
                kind="what_if",
                target=target,
                constraint=action.constraint or ctx.message,
                budget_minutes=budget,
                budget_scope=(
                    action.budget_scope
                    if action.budget_scope in {"day", "horizon"}
                    else None
                ),
                budget_delta_minutes=delta,
                energy=energy,
                earliest_time=earliest,
                latest_time=latest,
                duration_minutes=duration,
                splittable=action.splittable,
                work_start=work_start,
                work_end=work_end,
            )
        )
        return
    if kind == "outlook":
        resolution = dates.resolve_intent(action.when, today)
        plan.queries.append(
            _typed_query(
                action,
                kind="outlook",
                date_value=resolution.date,
                constraint=action.constraint or ctx.message,
            )
        )
        return
    if kind == "plan_status":
        plan.queries.append(QueryIntent(kind="plan_status"))
        return
    if kind == "plan":
        resolution = dates.resolve_intent(action.when, today)
        if resolution.ambiguous:
            question = "which day should i plan?"
            plan.questions.append(question)
            plan.pending.append(
                Pending(kind="query", question=question, query_kind="plan")
            )
            return
        target = resolution.date or today.isoformat()
        if target < today.isoformat():
            plan.questions.append("i can only build an executable plan for today or later.")
            return
        plan.queries.append(
            _typed_query(
                action,
                kind="plan",
                date_value=target,
                constraint=action.constraint or ctx.message,
            )
        )
        return
    if kind == "done":
        # The model classifies the requested history window; the core does math.
        start = today - timedelta(days=6) if action.period == "week" else today
        plan.queries.append(QueryIntent(kind="done", date=start.isoformat()))
        return
    if term:
        # "anything about X" -> search, even if the model also guessed a tag.
        plan.queries.append(QueryIntent(kind="search", term=term))
        return
    if kind == "search":  # asked to search but gave no term
        plan.queries.append(QueryIntent(kind="all"))
        return
    if kind == "tag" and action.tag:
        plan.queries.append(QueryIntent(kind="tag", tag=action.tag))
        return
    if kind in ("overdue", "week", "waiting"):
        plan.queries.append(QueryIntent(kind=kind))
        return
    model_kind = kind if kind in ("today", "date", "all") else "today"
    # A specific day named in the query (its when intent) is a date query for
    # that day; today -> today query.
    resolution = dates.resolve_intent(action.when, today)
    if resolution.ambiguous:
        question = "which day did you mean?"
        plan.questions.append(question)
        plan.pending.append(Pending(kind="query", question=question, query_kind=kind))
        return
    if resolution.date is not None:
        if resolution.date == today.isoformat():
            plan.queries.append(QueryIntent(kind="today"))
        else:
            plan.queries.append(QueryIntent(kind="date", date=resolution.date))
        return
    if model_kind == "date":
        # model wanted a specific day but the message names none
        question = "which day did you mean?"
        plan.questions.append(question)
        plan.pending.append(Pending(kind="query", question=question, query_kind=kind))
        return
    plan.queries.append(QueryIntent(kind=model_kind))


def _position_items(ctx, *, presented: bool = False) -> list[dict]:
    """Return the exact displayed order a numeric reference belongs to."""
    if presented and (ctx.presented_items or ctx.last_digest):
        return ctx.presented_items or ctx.last_digest
    return ctx.last_digest or ctx.active_items


_ORDINAL_POSITIONS = {
    "first": "1", "second": "2", "third": "3", "fourth": "4",
    "fifth": "5", "sixth": "6", "seventh": "7", "eighth": "8",
    "ninth": "9", "tenth": "10",
}
_REFERENCE_ACTIONS = (
    Amend, Complete, Drop, Note, Prioritize, Recur, Reschedule, Resume,
    Schedule, Snooze, Start, Wait,
)


def _literal_ordinal(message: str) -> str | None:
    match = re.search(
        r"\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)"
        r"(?:\s+one|\s+task|\s+item)?\b",
        message,
        re.IGNORECASE,
    )
    return _ORDINAL_POSITIONS.get(match.group(1).lower()) if match else None


def reconcile(actions: list, ctx) -> Plan:
    today = date.fromisoformat(ctx.today)
    if len(actions) == 1 and isinstance(actions[0], NudgeDecision):
        return _reconcile_nudge(actions[0], ctx, today)
    if len(actions) == 1 and isinstance(actions[0], ConfirmationDecision):
        return _reconcile_confirmation(actions[0], ctx)
    if len(actions) == 1 and isinstance(actions[0], OnboardingDecision):
        return _reconcile_onboarding(actions[0], ctx)
    # A contextual decision never rides alongside another action. The concrete
    # action wins, while the decision is discarded rather than widening scope.
    actions = [
        action
        for action in actions
        if not isinstance(
            action, (NudgeDecision, ConfirmationDecision, OnboardingDecision)
        )
    ]
    recap_actions = [action for action in actions if isinstance(action, Recap)]
    if len(actions) == 1 and len(recap_actions) == 1:
        return _reconcile_recap(recap_actions[0], ctx)
    # A contradictory model proposal cannot let a zero-result report suppress
    # a concrete task action. Ignore the recap proposal and reconcile the rest.
    if recap_actions:
        actions = [action for action in actions if not isinstance(action, Recap)]
    active = {i["id"]: i.get("label", "") for i in ctx.active_items}
    plan = Plan()
    active_due = {i["id"].lower(): i.get("due_date") for i in ctx.active_items}
    # Preserve the displayed morning order even after earlier rows close. This
    # prevents a later position from silently shifting to a different item.
    position_items = _position_items(ctx)
    by_pos = {
        str(n): item["id"] for n, item in enumerate(position_items, start=1)
    }
    if ctx.focus and ctx.focus[0].get("context") == "plan":
        planned = [
            item
            for item in ctx.focus
            if item.get("id") in active
        ]
        if planned:
            by_pos = {
                str(n): item["id"] for n, item in enumerate(planned, start=1)
            }
    ordinal = _literal_ordinal(ctx.message)
    if ordinal and ordinal in by_pos:
        if len(actions) == 1 and isinstance(actions[0], _REFERENCE_ACTIONS):
            actions[0].target = by_pos[ordinal]
            actions[0].confidence = 1.0
    for action in actions:
        if isinstance(action, Capture):
            _reconcile_capture(
                action, today, active_due, by_pos, plan,
            )
        elif isinstance(action, Amend):
            _reconcile_amend(action, active, by_pos, plan)
        elif isinstance(action, Start):
            target = _check_target(
                action.target,
                action.confidence,
                active,
                by_pos,
                plan,
                verb="start it",
            )
            if target is not None:
                plan.starts.append(target)
        elif isinstance(action, PlanAction):
            if action.op not in {"adopt", "replace", "cancel"}:
                plan.questions.append("i could not verify that plan action. nothing changed.")
            elif action.confidence < CONFIDENCE_THRESHOLD:
                plan.questions.append(
                    f"do you want me to {action.op} the day plan?"
                )
            else:
                plan.plan_action = action.op
        elif isinstance(action, Prioritize):
            _reconcile_prioritize(action, active, by_pos, plan)
        elif isinstance(action, Schedule):
            _reconcile_schedule(action, today, active, by_pos, plan)
        elif isinstance(action, Recur):
            _reconcile_recur(action, today, active, by_pos, plan)
        elif isinstance(action, Setting):
            _reconcile_setting(action, ctx.message, plan)
        elif isinstance(action, Complete):
            target = _check_target(
                action.target,
                action.confidence,
                active,
                by_pos,
                plan,
                proposed=Mutation(kind="complete"),
                verb="mark it done",
            )
            if target is not None:
                plan.mutations.append(Mutation(kind="complete", target=target))
        elif isinstance(action, Drop):
            target = _check_target(
                action.target,
                action.confidence,
                active,
                by_pos,
                plan,
                proposed=Mutation(kind="drop", reason=action.reason),
                verb="drop it",
            )
            if target is not None:
                plan.mutations.append(
                    Mutation(kind="drop", target=target, reason=action.reason)
                )
        elif isinstance(action, Reschedule):
            _reconcile_reschedule(action, today, active, by_pos, ctx, plan)
        elif isinstance(action, Query):
            _reconcile_query(action, today, ctx, plan)
        elif isinstance(action, Bulk):
            _reconcile_bulk(action, today, ctx, plan)
        elif isinstance(action, Snooze):
            target = _check_target(
                action.target,
                action.confidence,
                active,
                by_pos,
                plan,
                proposed=Mutation(kind="snooze", minutes=max(1, action.minutes)),
                verb="snooze it",
            )
            if target is not None:
                plan.mutations.append(
                    Mutation(kind="snooze", target=target, minutes=max(1, action.minutes))
                )
        elif isinstance(action, Note):
            target = _check_target(
                action.target,
                action.confidence,
                active,
                by_pos,
                plan,
                proposed=Mutation(kind="note", note=action.text),
                verb="add that note",
            )
            if target is not None:
                plan.mutations.append(
                    Mutation(kind="note", target=target, note=action.text)
                )
        elif isinstance(action, Wait):
            target = _check_target(
                action.target,
                action.confidence,
                active,
                by_pos,
                plan,
                proposed=Mutation(kind="wait"),
                verb="park it as waiting",
            )
            if target is not None:
                plan.mutations.append(Mutation(kind="wait", target=target))
        elif isinstance(action, Resume):
            target = _check_target(action.target, 1.0, active, by_pos, plan)
            if target is not None:
                # Resume only means something on a waiting item. If the model
                # picked a non-waiting one (focus pull), retarget to the only
                # waiting item; with several, ask instead of guessing.
                waiting_ids = [
                    i["id"] for i in ctx.active_items if i.get("waiting")
                ]
                if target not in waiting_ids:
                    if len(waiting_ids) == 1:
                        target = waiting_ids[0]
                    elif not waiting_ids:
                        plan.questions.append("nothing is parked as waiting right now.")
                        continue
                    else:
                        plan.questions.append("which waiting item do you mean?")
                        continue
                mutation = Mutation(kind="resume", target=target)
                if action.confidence < CONFIDENCE_THRESHOLD:
                    _hold(
                        plan,
                        mutation,
                        f'did you mean "{active[target]}"? confirm putting it '
                        "back on deck, or cancel.",
                    )
                else:
                    plan.mutations.append(mutation)
        elif isinstance(action, Undo):
            plan.undo = True
        elif isinstance(action, Chitchat):
            plan.chitchat = (action.reply or "sure thing").strip()
        elif isinstance(action, Unknown):
            if _is_typo_correction(ctx.message):
                # "Hobbie*": a texting typo-fix of a prior message, not a task.
                plan.chitchat = "no worries"
            else:
                _reconcile_unknown(ctx, plan)
    _apply_reference_guards(plan, ctx)
    return plan


def _reconcile_unknown(ctx, plan: Plan) -> None:
    """The model caught nothing. If a strong typo match to an item exists ("the
    table thing" -> "fable"), suggest it rather than nagging to rephrase."""
    words = _words(ctx.message)
    best, score = _best_item(words, ctx.active_items) if words else (None, 0.0)
    if best is not None and score >= _MATCH and plan.confirm is None:
        plan.questions.append(
            f'i found "{best["label"]}", but not the action. tell me what you '
            "want to do with it."
        )
        return
    plan.questions.append("i did not catch a task there. can you rephrase?")
