<!-- SPDX-License-Identifier: MIT -->
# App Store runtime-contract audit

Date: 2026-07-11. Parent: PR #10.

## Result

The first Swift task slice shares fixtures with Python. Model actions remain
typed proposals. Swift resolves dates, validates targets and confidence,
applies one atomic turn, and records bounded undo.

## Covered behavior

1. Capture with tomorrow resolution.
2. Multiple captures and repeated batch undo.
3. Atomic complete, drop, and reschedule by exact ID.
4. Next-weekday resolution.
5. Ambiguous-date clarification.
6. Low-confidence confirmation.
7. Missing-target clarification.

Requests carry protocol version, correlation ID, original message, bounded
actions, timezone, and time formats. Invalid versions, actions, dates, targets,
or mixed undo change no state.

## Open gates at this increment

- Durable App Group state and restart recovery
- Model and Telegram connections
- Recurrence, constraints, reminders, queries, settings, planning, Calendar,
  confirmation resume, and delivery parity
- Fuzzy references and customer-facing copy
- Accessibility and background lifecycle evidence

Background activation remained locked.
