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
from datetime import date, datetime, timedelta

from core import dates, recurrence
from core.models import (
    Amend,
    Bulk,
    Capture,
    Chitchat,
    Complete,
    Drop,
    Note,
    PlanAction,
    Prioritize,
    Query,
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
RETRACTION_TTL_MINUTES = 15


def _is_recent_literal_retraction(ctx) -> bool:
    """A short standalone retraction undoes only a fresh mutation batch."""
    tokens = tuple(re.findall(r"[a-z]+", (ctx.message or "").lower()))
    if tokens not in {
        ("nevermind",),
        ("never", "mind"),
        ("nevermind", "i", "m", "good"),
        ("never", "mind", "i", "m", "good"),
        ("nevermind", "im", "good"),
        ("never", "mind", "im", "good"),
        ("nevermind", "all", "good"),
        ("never", "mind", "all", "good"),
        ("nevermind", "no", "thanks"),
        ("never", "mind", "no", "thanks"),
    }:
        return False
    if not ctx.last_change_at:
        return False
    try:
        age = datetime.fromisoformat(ctx.now) - datetime.fromisoformat(
            ctx.last_change_at
        )
    except (TypeError, ValueError):
        return False
    return timedelta(0) <= age <= timedelta(minutes=RETRACTION_TTL_MINUTES)


_ZERO_COMPLETION_REPORT = re.compile(
    r"(?:"
    r"nothing(?: at all)?(?: really)? (?:(?:got|was|is|has been) )?"
    r"(?:done|finished|completed)"
    r"|(?:i|we) (?:did|finished|completed) nothing"
    r"|(?:i|we) got nothing done"
    r"|(?:(?:i|we) )?(?:didn't|did not|haven't|have not) "
    r"(?:get anything done|finish anything|complete anything|do anything|"
    r"done anything|get any tasks? done|finish any tasks?|complete any tasks?|"
    r"get any of (?:it|them|these|those) done|"
    r"finish any of (?:it|them|these|those)|"
    r"complete any of (?:it|them|these|those))"
    r"|(?:(?:i|we) )?(?:couldn't|could not|wasn't able to|weren't able to|"
    r"was not able to|were not able to) "
    r"(?:get anything done|finish anything|complete anything|do anything)"
    r"|(?:i|we) (?:made|had) no progress"
    r"|(?:i|we) got none of (?:it|them|these|those) done"
    r"|none of (?:it|them|these|those) "
    r"(?:(?:got|was|were) )?(?:done|finished|completed)"
    r"|no (?:tasks?|items?|work) "
    r"(?:(?:got|was|were) )?(?:done|finished|completed)"
    r"|(?:no|zero) progress"
    r")"
    r"(?: today| tonight| this evening)?",
    re.IGNORECASE,
)


def zero_completion_ack(ctx) -> str | None:
    """Acknowledge an explicit report that no work was completed.

    This is a first-class, mutation-free outcome, not an unknown task command.
    Full-string matching prevents a negative clause from hiding a completion in
    a mixed report such as "nothing on taxes, but I finished the deck". Very
    terse answers are accepted only when a recent proactive list supplies the
    conversational context.
    """
    if ctx.forwarded_from or any(
        pending.get("kind") == "setting" for pending in ctx.pending
    ):
        return None
    low = (ctx.message or "").lower().replace("\u2019", "'")
    low = re.sub(r"\s+", " ", low).strip(" \t\r\n.!?,;:")
    low = re.sub(
        r"^(?:sorry|sadly|honestly|unfortunately)[,:]?\s+|"
        r"^(?:no|nope)[,:]\s+",
        "",
        low,
    )
    short_contextual = {
        "none",
        "nothing",
        "nothing today",
        "no progress",
        "no progress today",
        "not a thing",
        "zero",
    }
    if not _ZERO_COMPLETION_REPORT.fullmatch(low) and not (
        ctx.presented_items and not ctx.pending and low in short_contextual
    ):
        return None
    count = len(ctx.presented_items)
    if count == 1:
        return "okay. nothing marked done. that item stays open on deck."
    if count == 2:
        return "okay. nothing marked done. both items stay open on deck."
    if count > 2:
        return f"okay. nothing marked done. all {count} items stay open on deck."
    return "okay. nothing marked done."


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
    kind: str  # today | date | all | overdue | week | search | done | tag | plan | outlook
    date: str | None = None  # ISO; query day, planning day, or done-period start
    term: str | None = None  # search keywords, for kind=search
    tag: str | None = None  # project/list name, for kind=tag
    constraint: str | None = None  # user context for kind=plan


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
                f'did you mean "{active[key]}"? reply yes to {verb}, or no to cancel.',
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
        question=f'did you mean "{item["label"]}"? reply yes to {verb}.',
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
            and plan.confirm is None and not negated \
            and _EVERYTHING_BUT.search(ctx.message) is None:
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
_DEADLINE_CUE = re.compile(
    r"\b(by|before|deadline|due|due by|no later than)\b", re.IGNORECASE
)


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
    message: str,
    solo: bool,
    shared_date: str | None,
    active_due: dict,
    by_pos: dict,
    plan: Plan,
) -> None:
    resolution = dates.resolve_intent(action.when, today)
    if resolution.date is None and not resolution.ambiguous and shared_date is not None:
        # A leading date shared across a multi-task message (computed above).
        resolution = dates.DateResolution(date=shared_date)

    deadline = dates.resolve_intent(action.deadline, today)
    literal_deadline = dates.deadline_in_text(message, today)
    if literal_deadline:
        deadline = dates.DateResolution(date=literal_deadline)
        if resolution.date == literal_deadline:
            resolution = dates.DateResolution()
    if (
        solo
        and not literal_deadline
        and deadline.date is None
        and not deadline.ambiguous
        and resolution.date is not None
        and _DEADLINE_CUE.search(message)
    ):
        deadline = resolution
        resolution = dates.DateResolution()

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
    repeat_anchor = action.repeat_anchor
    if re.search(
        r"\b(after (i |it is |it was )?(finish|finished|complete|completed)|after completion)\b",
        message,
        re.IGNORECASE,
    ):
        repeat_anchor = "completion"
    literal_count = re.search(
        r"\b(?:stop|end) after (\d+) (?:times?|occurrences?)\b",
        message,
        re.IGNORECASE,
    )
    repeat_count = action.repeat_count or (
        int(literal_count.group(1)) if literal_count else None
    )
    structured = recurrence.parse(
        repeat,
        anchor=repeat_anchor,
        end_date=repeat_end.date,
        count=repeat_count,
    )
    if structured is not None:
        # A recurring task's date is its next occurrence, decided by the rule.
        first = recurrence.next_due(structured, today, inclusive=True)
        if first is not None:
            due_date = first.isoformat()
            structured.anchor_date = first.isoformat()
    elif solo:
        # Deterministic backstop: a day word in the message wins over a
        # misclassified intent ("taxes monday" read as tomorrow). Lone captures
        # only: with several, a trailing day must not smear across them (the
        # leading-date share above handles the "Tomorrow: A, B, C" shape).
        planned_words = (
            message.split(";", 1)[0]
            if literal_deadline and ";" in message
            else message
        )
        corrected = dates.named_day_correction(planned_words, due_date, today)
        if corrected is not None:
            due_date = corrected

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
        _hold(plan, mutation, f"that is {due_date}, about {years} years out. reply yes to keep it.")
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


def _reconcile_setting(action: Setting, plan: Plan) -> None:
    if action.key in ("wake_time", "eod_time"):
        value = dates.parse_time(action.raw)
        if value is None:
            what = "morning digest" if action.key == "wake_time" else "evening recap"
            question = f"what time should i send the {what}?"
            plan.questions.append(question)
            plan.pending.append(Pending(kind="setting", question=question, key=action.key))
            return
        plan.settings.append(SettingChange(key=action.key, value=value))
    elif action.key in ("work_hours", "break_window"):
        if action.key == "break_window" and action.raw.strip().lower() in {
            "none", "off", "no break", "remove", "remove break",
        }:
            plan.settings.append(SettingChange(key=action.key, value="none"))
            return
        value = _parse_time_range(action.raw)
        if value is None:
            what = "working hours" if action.key == "work_hours" else "protected break"
            question = f"what start and end time should i use for the {what}?"
            plan.questions.append(question)
            plan.pending.append(Pending(kind="setting", question=question, key=action.key))
            return
        plan.settings.append(SettingChange(key=action.key, value=value))
    elif action.key == "work_days":
        value = _parse_work_days(action.raw)
        if value is None:
            question = "which weekdays may i plan flexible work on?"
            plan.questions.append(question)
            plan.pending.append(
                Pending(kind="setting", question=question, key=action.key)
            )
            return
        plan.settings.append(SettingChange(key=action.key, value=value))
    elif action.key in ("default_duration", "transition_buffer"):
        value = _parse_minutes(action.raw)
        low, high = (5, 480) if action.key == "default_duration" else (0, 120)
        if value is None or not low <= value <= high:
            what = (
                "default task estimate"
                if action.key == "default_duration"
                else "transition buffer"
            )
            question = f"how many minutes should i use for the {what}?"
            plan.questions.append(question)
            plan.pending.append(
                Pending(kind="setting", question=question, key=action.key)
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


_DAY_NAMES = {
    "monday": 0, "mon": 0,
    "tuesday": 1, "tues": 1, "tue": 1,
    "wednesday": 2, "wed": 2,
    "thursday": 3, "thurs": 3, "thur": 3, "thu": 3,
    "friday": 4, "fri": 4,
    "saturday": 5, "sat": 5,
    "sunday": 6, "sun": 6,
}
_DAY_CODES = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


def _parse_work_days(raw: str) -> str | None:
    low = raw.strip().lower()
    exclusion = re.search(r"\b(?:except|but not|not)\s+(.+)$", low)
    included_text = low[:exclusion.start()] if exclusion else low

    def mentioned(text: str) -> set[int]:
        days: set[int] = set()
        if re.search(r"\b(?:every day|all days|daily|seven days)\b", text):
            days.update(range(7))
        if "weekdays" in text:
            days.update(range(5))
        if "weekends" in text:
            days.update((5, 6))
        names = "|".join(_DAY_NAMES)
        for match in re.finditer(
            rf"\b({names})\s+(?:through|to|-)\s+({names})\b", text
        ):
            first = _DAY_NAMES[match.group(1)]
            last = _DAY_NAMES[match.group(2)]
            days.update(
                range(first, last + 1)
                if first <= last
                else (*range(first, 7), *range(last + 1))
            )
        days.update(
            index
            for name, index in _DAY_NAMES.items()
            if re.search(rf"\b{re.escape(name)}\b", text)
        )
        return days

    chosen = mentioned(included_text)
    if exclusion:
        if not chosen:
            chosen = set(range(7))
        chosen -= mentioned(exclusion.group(1))
    if not chosen:
        return None
    return ",".join(_DAY_CODES[index] for index in sorted(chosen))


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
    message: str,
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
    literal_deadline = dates.deadline_in_text(message, today)
    if literal_deadline:
        deadline = dates.DateResolution(date=literal_deadline)
    else:
        corrected = dates.named_day_correction(message, deadline.date, today)
        if corrected is not None:
            deadline = dates.DateResolution(date=corrected)
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
            f'that deadline is {deadline.date}, about {years} years out. reply yes to keep it.',
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


_TODAY_WORDS = ("today", "tonight", "this morning", "this afternoon", "this evening", "now")


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

    # The model pads a time-only change ("make it 4pm") with kind "today". If the
    # user never said a today-word, the day is NOT changing: keep the item's date.
    if (
        new_time is not None
        and action.when is not None
        and action.when.kind == "today"
        and not any(w in low for w in _TODAY_WORDS)
    ):
        resolution = dates.DateResolution()

    # A day word named in the message wins over a misclassified intent.
    corrected = dates.named_day_correction(ctx.message, resolution.date, today)
    if corrected is not None:
        resolution = dates.DateResolution(date=corrected)

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
            _hold(plan, mutation, f'move "{label}" to {resolution.date}, about {years} years out. reply yes to keep it.')
            return
    if action.confidence < CONFIDENCE_THRESHOLD:
        _hold(
            plan,
            mutation,
            f'did you mean "{label}"? reply yes to move it, or no to cancel.',
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
    if action.op not in ("complete", "drop", "reschedule"):
        plan.questions.append("i did not catch a task there. can you rephrase?")
        return
    scope = action.scope if action.scope in ("today", "all", "date") else "today"
    when = dates.resolve_intent(action.when, today)
    target_date = None
    if scope == "date":
        if when.ambiguous or when.date is None:
            plan.questions.append("which day did you mean?")
            return
        target_date = when.date
    list_reference = re.search(
        r"\b(?:that|this) list\b|\b(?:those|these) (?:tasks|items|ones)\b",
        ctx.message,
        re.IGNORECASE,
    )
    completion_digest_reference = (
        _EVERYTHING_BUT.search(ctx.message) is not None
        and _COMPLETION_BULK.search(ctx.message) is not None
        and bool(ctx.last_digest)
    )
    if list_reference:
        if not ctx.presented_items:
            plan.questions.append("which list did you mean? i changed nothing.")
            return
        presented_ids = {item["id"] for item in ctx.presented_items}
        matching = [i for i in ctx.active_items if i["id"] in presented_ids]
    elif completion_digest_reference:
        active_by_id = {item["id"]: item for item in ctx.active_items}
        matching = [
            active_by_id[item["id"]]
            for item in ctx.last_digest
            if item["id"] in active_by_id
        ]
    else:
        matching = [
            i for i in ctx.active_items
            if _in_scope(i, scope, ctx.today, target_date)
        ]
    if not matching:
        plan.questions.append("nothing matched, so i changed nothing.")
        return
    active_all = {i["id"]: i.get("label", "") for i in ctx.active_items}
    position_items = _position_items(ctx, presented=bool(list_reference))
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
    if action.confidence < CONFIDENCE_THRESHOLD:
        # A sweeping mutation is the last place to guess; confirm, never apply.
        verb = "finish" if action.op == "complete" else "drop"
        plan.confirm = ConfirmIntent(
            mutations=[Mutation(kind=action.op, target=item_id) for item_id in ids],
            question=(
                f"that would {verb} {len(ids)} open item(s). "
                "reply yes to confirm, or no to cancel."
            ),
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
                    "reply yes to confirm."
                ),
            )
            return
    for item_id in ids:
        plan.mutations.append(Mutation(kind=action.op, target=item_id))


def _reconcile_query(action: Query, today: date, ctx, plan: Plan) -> None:
    kind, term = action.kind, action.term
    if kind == "outlook":
        resolution = dates.resolve_intent(action.when, today)
        corrected = dates.named_day_correction(
            ctx.message, resolution.date, today
        )
        horizon = corrected or resolution.date or dates.deadline_in_text(
            ctx.message, today
        )
        plan.queries.append(
            QueryIntent(
                kind="outlook",
                date=horizon,
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
        corrected = dates.named_day_correction(
            ctx.message, resolution.date, today
        )
        if corrected is not None:
            resolution = dates.DateResolution(date=corrected)
        target = resolution.date or today.isoformat()
        if target < today.isoformat():
            plan.questions.append("i can only build an executable plan for today or later.")
            return
        plan.queries.append(
            QueryIntent(
                kind="plan",
                date=target,
                constraint=action.constraint or ctx.message,
            )
        )
        return
    if kind == "done":
        # "what did I finish": this week -> last 7 days, otherwise today.
        start = today - timedelta(days=6) if "week" in ctx.message.lower() else today
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
    # Backstop: a day word in the question wins over a dropped or misfiled
    # intent ("what about tomorrow" read as a today query).
    corrected = dates.named_day_correction(ctx.message, resolution.date, today)
    if corrected is not None:
        resolution = dates.DateResolution(date=corrected)
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


_EVERYTHING_BUT = re.compile(
    r"\b(?:everything|all(?:\s+of\s+(?:it|them)|\s+my\s+\w+)?)\b"
    r".{0,40}?\b(?:but|except|besides|aside from)\b(?P<tail>.*)",
    re.IGNORECASE | re.DOTALL,
)

_COMPLETION_BULK = re.compile(
    r"\b(?:finish(?:ed)?|complete(?:d)?|did|done|knocked\s+out|"
    r"wrapped\s+up|got\s+through)\b",
    re.IGNORECASE,
)

_POSITION_TOKEN = (
    r"(?:\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|first|"
    r"second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)"
)
_POSITION_PREFIX = r"(?:the\s+)?(?:(?:items?|tasks?|numbers?|#)\s*)?"
_POSITION_EXCLUSION_TAIL = re.compile(
    rf"\s*{_POSITION_PREFIX}{_POSITION_TOKEN}"
    rf"(?:\s*(?:,|and|&)\s*{_POSITION_PREFIX}"
    rf"{_POSITION_TOKEN})*\s*(?:for\s+now|please)?\s*[.!]?\s*",
    re.IGNORECASE,
)


# Words too generic to identify an item when matching an exclusion tail.
_TAIL_STOP = {"the", "and", "one", "ones", "thing", "things", "stuff", "task", "tasks", "that", "this"}


def _tail_words(text: str) -> set[str]:
    return {
        w for w in re.findall(r"[a-z]+", text.lower())
        if len(w) > 2 and w not in _TAIL_STOP
    }


def _tail_matches(label: str, tail_words: set[str]) -> bool:
    return any(
        w in tail_words
        for w in label.lower().split()
        if len(w) > 2 and w not in _TAIL_STOP
    )


def _position_items(ctx, *, presented: bool = False) -> list[dict]:
    """Return the exact displayed order a numeric reference belongs to."""
    if presented and ctx.presented_items:
        return ctx.presented_items
    return ctx.last_digest or ctx.active_items


def _position_exclusions(tail: str, ctx) -> tuple[list[str], bool]:
    if not _POSITION_EXCLUSION_TAIL.fullmatch(tail):
        looks_positional = re.match(
            rf"\s*{_POSITION_PREFIX}{_POSITION_TOKEN}\b",
            tail,
            re.IGNORECASE,
        )
        return [], bool(looks_positional)
    items = _position_items(ctx)
    by_pos = {str(n): item["id"] for n, item in enumerate(items, start=1)}
    labels = {item["id"]: item.get("label", "") for item in items}
    excluded = []
    for token in re.findall(_POSITION_TOKEN, tail, re.IGNORECASE):
        item_id = _resolve_ref(token, labels, by_pos)
        if item_id is None:
            return [], True
        if item_id not in excluded:
            excluded.append(item_id)
    return excluded, True


def _fix_everything_but(actions: list, ctx) -> list:
    """Deterministic backstop for "did everything BUT X": the model sometimes
    emits a lone complete of X (the one item the user spared) or a bulk with an
    empty except list. When the message clearly excludes items, make the plan
    match: a bulk over the rest, with the named items excluded."""
    match = _EVERYTHING_BUT.search(ctx.message)
    if not match:
        return actions
    tail = match.group("tail")
    excluded, positional = _position_exclusions(tail, ctx)
    tail_words = _tail_words(tail)
    labels = {i["id"]: i.get("label", "") for i in ctx.active_items}
    by_pos = {str(n): i["id"] for n, i in enumerate(ctx.active_items, start=1)}
    if positional and not excluded:
        return [Unknown(note="numbered exclusion outside the displayed list")]
    if not positional:
        if not tail_words:
            return actions
        excluded = [
            item_id
            for item_id, label in labels.items()
            if _tail_matches(label, tail_words)
        ]
    if not excluded:
        return actions
    if _COMPLETION_BULK.search(ctx.message):
        return [
            Bulk(
                op="complete",
                scope="today",
                exclude=list(excluded),
                confidence=1.0,
            )
        ]
    bulks = [a for a in actions if isinstance(a, Bulk)]
    if bulks:
        # Guarantee every literal exclusion even when the model proposed a
        # non-empty but incomplete list.
        for b in bulks:
            b.exclude = list(dict.fromkeys([*b.exclude, *excluded]))
        return actions
    singles = [a for a in actions if isinstance(a, (Complete, Drop))]
    if singles and all(
        _tail_matches(
            labels.get(_resolve_ref(a.target, labels, by_pos) or "", ""),
            tail_words,
        )
        for a in singles
    ):
        # Every explicit action targets an item the user EXCLUDED: inverted.
        op = "drop" if all(isinstance(a, Drop) for a in singles) else "complete"
        others = [a for a in actions if not isinstance(a, (Complete, Drop))]
        return others + [Bulk(op=op, scope="today", exclude=list(excluded))]
    return actions


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


def _strongly_names_item(text: str, item: dict | None) -> bool:
    if not item:
        return False
    label_words = list(dict.fromkeys(_words(item.get("label", ""))))
    text_words = _words(text)
    if not label_words or not text_words:
        return False
    matched = [
        label_word
        for label_word in label_words
        if _word_hits(label_word, text_words)
    ]
    if len(matched) >= min(2, len(label_words)):
        return True
    generic = {
        "call", "draft", "email", "item", "meeting", "new", "plan",
        "report", "review", "task", "waiting", "work",
    }
    return any(len(word) >= 4 and word not in generic for word in matched)


def _merge_new_capture_constraints(actions: list, ctx) -> list:
    """Attach a pronoun-led constraint clause to the new capture it describes.

    Small models occasionally emit "new task; it is due Monday" as a Capture
    plus a Schedule aimed at an unrelated open item. The literal pronoun and the
    absence of that target's words make the ownership deterministic.
    """
    captures = [action for action in actions if isinstance(action, Capture)]
    schedules = [action for action in actions if isinstance(action, Schedule)]
    if (
        len(captures) != 1
        or not schedules
        or not re.search(r"[;,.]\s*(?:it|this|that)\b", ctx.message, re.I)
    ):
        return actions
    capture = captures[0]
    active = {item["id"].lower(): item.get("label", "") for item in ctx.active_items}
    by_pos = {str(n): item["id"] for n, item in enumerate(ctx.active_items, start=1)}
    merged: set[int] = set()
    constraint_clause = re.split(r"[;,.]", ctx.message, maxsplit=1)[-1]
    for schedule in schedules:
        target = _resolve_ref(schedule.target, active, by_pos)
        target_item = (
            {"label": active.get(target, "")} if target is not None else None
        )
        if _strongly_names_item(constraint_clause, target_item):
            continue
        if capture.deadline is None and schedule.deadline is not None:
            capture.deadline = schedule.deadline
        if capture.duration_minutes is None and schedule.duration_minutes is not None:
            capture.duration_minutes = schedule.duration_minutes
            capture.duration_confidence = schedule.duration_confidence
        if schedule.schedule_kind is not None:
            capture.schedule_kind = schedule.schedule_kind
        if schedule.splittable is not None:
            capture.splittable = schedule.splittable
        if capture.earliest is None and schedule.earliest is not None:
            capture.earliest = schedule.earliest
            capture.earliest_time = schedule.earliest_time
        if capture.preferred_window is None and schedule.preferred_window:
            capture.preferred_window = schedule.preferred_window
        if schedule.depends_on:
            capture.depends_on = list(schedule.depends_on)
        if schedule.reminder_offsets:
            capture.reminder_offsets = list(schedule.reminder_offsets)
        merged.add(id(schedule))
    return [action for action in actions if id(action) not in merged]


def _recover_new_recurrence(actions: list, ctx) -> list:
    """Recover a new recurring capture misclassified as editing a series."""
    if len(actions) != 1 or not isinstance(actions[0], Recur):
        return actions
    action = actions[0]
    active = {item["id"].lower(): item.get("label", "") for item in ctx.active_items}
    by_pos = {str(n): item["id"] for n, item in enumerate(ctx.active_items, start=1)}
    if _resolve_ref(action.target, active, by_pos) is not None:
        return actions
    match = re.search(
        r"\bevery\s+(\d+)\s+(day|week|month|year)s?\b",
        ctx.message,
        re.IGNORECASE,
    )
    if not match:
        return actions
    task = ctx.message[:match.start()].strip(" ,;:")
    if not task:
        return actions
    best, _ = _best_item(_words(task), ctx.active_items)
    if _strongly_names_item(task, best):
        return actions
    anchor = (
        "completion"
        if re.search(r"\bafter (?:i |it )?(?:finish|complete)", ctx.message, re.I)
        else "fixed"
    )
    return [
        Capture(
            task=task,
            raw=ctx.message,
            repeat=f"every:{int(match.group(1))}:{match.group(2).lower()}",
            repeat_anchor=anchor,
            repeat_count=action.count,
        )
    ]


def _drop_redundant_new_recur(actions: list, message: str) -> list:
    """Keep a stop-after count on its new capture, not an unrelated series."""
    captures = [
        action
        for action in actions
        if isinstance(action, Capture) and recurrence.normalize(action.repeat)
    ]
    series_edits = [action for action in actions if isinstance(action, Recur)]
    if (
        len(captures) == 1
        and len(series_edits) == 1
        and series_edits[0].op == "stop"
        and re.search(
            r"\bevery\s+\d+\s+(?:days?|weeks?|months?|years?)\b",
            message,
            re.IGNORECASE,
        )
        and re.search(
            r"\b(?:stop|end) after \d+ (?:times?|occurrences?)\b",
            message,
            re.IGNORECASE,
        )
    ):
        return [action for action in actions if action is not series_edits[0]]
    return actions


_PAST_COMPLETION_OPEN = re.compile(
    r"^\s*(?:i\s+|we\s+)?(?:already\s+|just\s+)?"
    r"(?:did|finished|completed|wrapped up|knocked out)\b",
    re.IGNORECASE,
)
_COMPLETION_SCOPE_BREAK = re.compile(
    r"\b(?:and|then|but)\s+(?:i\s+|we\s+)?(?:"
    r"will|shall|am|are|was|were|want|need|plan|intend|start|started|"
    r"begin|began|work|worked|working|continue|continued|progressed|try|tried|"
    r"attempt|attempted|do|doing|finish|finishing|complete|completing"
    r")\b|\b(?:next|now)\b",
    re.IGNORECASE,
)


def _share_past_completion_scope(actions: list, message: str) -> list:
    """Recover a coordinated completion that the model split into done + start.

    English verbs such as "hit" have identical present and past forms. Small
    models can therefore read "I did A and hit B" as a completion followed by a
    request to start B. When the sentence opens in explicit past-completion
    tense, contains both model-proposed shapes, and never changes to future,
    ongoing, partial-progress, or imperative intent, the same tense safely
    scopes across "and".
    """
    if (
        not _PAST_COMPLETION_OPEN.search(message)
        or " and " not in message.lower()
        or _COMPLETION_SCOPE_BREAK.search(message)
        or not any(isinstance(action, Complete) for action in actions)
        or not any(isinstance(action, Start) for action in actions)
    ):
        return actions
    return [
        Complete(target=action.target, confidence=action.confidence)
        if isinstance(action, Start)
        else action
        for action in actions
    ]


def reconcile(actions: list, ctx) -> Plan:
    today = date.fromisoformat(ctx.today)
    acknowledgement = zero_completion_ack(ctx)
    if acknowledgement is not None:
        return Plan(acknowledgement=acknowledgement)
    if _is_recent_literal_retraction(ctx):
        actions = [Undo()]
    actions = _fix_everything_but(actions, ctx)
    actions = _drop_redundant_new_recur(actions, ctx.message)
    actions = _recover_new_recurrence(actions, ctx)
    actions = _merge_new_capture_constraints(actions, ctx)
    actions = _share_past_completion_scope(actions, ctx.message)
    low = ctx.message.strip().lower()
    queries = [action for action in actions if isinstance(action, Query)]
    outlook_words = re.search(
        r"\b(?:overloaded|overbooked|capacity|what (?:will|won't|will not) fit|"
        r"can i finish|can everything fit|enough time|fit (?:it|this|everything) "
        r"(?:this week|by))\b",
        low,
    )
    deviation = re.search(
        r"\b(?:replan|got interrupted|was interrupted|meeting ran (?:long|over)|"
        r"lost \d+ (?:minutes?|hours?)|running \d+ (?:minutes?|hours?) late)\b",
        low,
    )
    explicit_item_change = re.search(
        r"\b(?:complete|completed|done|drop|cancel the task|move|push|reschedule|"
        r"snooze)\b",
        low,
    )
    if outlook_words:
        actions = [Query(kind="outlook", constraint=ctx.message)]
    elif deviation and not explicit_item_change:
        actions = [
            next(
                (query for query in queries if query.kind == "plan"),
                Query(kind="plan", constraint=ctx.message),
            )
        ]
    elif re.fullmatch(
        r"(?:what(?:'s| is) on my plan|show (?:me )?my plan|current plan)[?!.]?",
        low,
    ):
        actions = [Query(kind="plan_status")]
    elif queries and re.match(r"^(?:plan|map out)\b", low):
        actions = [
            Query(
                kind="plan",
                when=next((query.when for query in queries if query.when), None),
                constraint=ctx.message,
            )
        ]
    elif re.fullmatch(
        r"(?:use|adopt|accept|lock in|follow) (?:this|that|the) plan[.!]?",
        low,
    ):
        actions = [PlanAction(op="adopt", confidence=1.0)]
    elif re.fullmatch(
        r"(?:replace|update|swap) (?:my|the|today'?s) plan (?:with )?(?:this|that)[.!]?",
        low,
    ):
        actions = [PlanAction(op="replace", confidence=1.0)]
    elif re.fullmatch(
        r"(?:cancel|clear|drop|stop following) (?:my|the|today'?s) plan[.!]?",
        low,
    ):
        actions = [PlanAction(op="cancel", confidence=1.0)]
    if re.search(
        r"\b(waiting on|blocked on|cannot start until|can't start until)\b",
        ctx.message,
        re.IGNORECASE,
    ):
        converted = []
        for action in actions:
            if isinstance(action, Note):
                converted.append(
                    Wait(target=action.target, confidence=action.confidence)
                )
            elif isinstance(action, Capture):
                best, _ = _best_item(_words(ctx.message), ctx.active_items)
                converted.append(
                    Wait(target=best["id"], confidence=1.0)
                    if _strongly_names_item(ctx.message, best)
                    else action
                )
            else:
                converted.append(action)
        actions = converted
    active = {i["id"]: i.get("label", "") for i in ctx.active_items}
    plan = Plan()
    captures = [a for a in actions if isinstance(a, Capture)]
    n_captures = len(captures)
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
        if (
            ctx.focus
            and ctx.focus[0].get("context") == "plan"
            and re.fullmatch(
                r"\s*(?:(?:i(?:'ll| will)|let'?s)\s+)?"
                r"(?:do|start|work on)\s+(?:the\s+)?"
                r"(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)"
                r"(?:\s+one|\s+task|\s+item)?[.!]?\s*",
                ctx.message,
                re.IGNORECASE,
            )
        ):
            actions = [Start(target=by_pos[ordinal], confidence=1.0)]
        elif len(actions) == 1 and isinstance(actions[0], _REFERENCE_ACTIONS):
            actions[0].target = by_pos[ordinal]
            actions[0].confidence = 1.0
    # A date at the START of a multi-task message ("Tomorrow I need to A, B, C")
    # applies to all the tasks; the model attaches it to the first one and leaves
    # the rest with no date. Detect the leading date in the text, then take the
    # actual date from the first task's intent (exact math). A trailing date
    # ("call A and email B tomorrow") is not at the start, so it is not shared.
    shared_date = None
    if n_captures > 1 and dates.leading_date(ctx.message, today) is not None:
        first = dates.resolve_intent(captures[0].when, today)
        shared_date = first.date or dates.leading_date(ctx.message, today)
    for action in actions:
        if isinstance(action, Capture):
            _reconcile_capture(
                action, today, ctx.message, n_captures == 1, shared_date,
                active_due, by_pos, plan,
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
            if action.confidence < CONFIDENCE_THRESHOLD:
                plan.questions.append(
                    f"do you want me to {action.op} the day plan?"
                )
            else:
                plan.plan_action = action.op
        elif isinstance(action, Prioritize):
            _reconcile_prioritize(action, active, by_pos, plan)
        elif isinstance(action, Schedule):
            _reconcile_schedule(action, today, active, by_pos, ctx.message, plan)
        elif isinstance(action, Recur):
            _reconcile_recur(action, today, active, by_pos, plan)
        elif isinstance(action, Setting):
            _reconcile_setting(action, plan)
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
                        f'did you mean "{active[target]}"? reply yes to put it '
                        "back on deck, or no to cancel.",
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
        if re.search(r"\b(did|done|finish|finished|complete|completed)\b", ctx.message.lower()):
            plan.confirm = _confirm_did_you_mean(best, "complete")
        else:
            plan.questions.append(
                f'i found "{best["label"]}", but not the action. say complete, '
                "move, rename, or drop with the task name."
            )
        return
    plan.questions.append("i did not catch a task there. can you rephrase?")
