<!-- SPDX-License-Identifier: MIT -->
# Hob handoff

Picking up development? Read [CLAUDE.md](CLAUDE.md) first (conventions, the
model-proposes/core-disposes doctrine, the dev loop, and ops), then
[docs/architecture.md](docs/architecture.md). This file is just the current-state
snapshot.

## Where it stands

- **Live and in daily use.** Runs as a `launchd` daemon on macOS, with
  [Hearth](https://github.com/adamskijow/Hearth) keeping Ollama alive. Model:
  `qwen2.5:14b-instruct` (7b works; 14b is more reliable on dense messages).
- **Released:** v0.2.0. Schema version 7.
- **Green:** `uv run pytest` (233 passing) and the real-model eval
  (`HOB_MODEL=qwen2.5:14b-instruct uv run python evals/interpreter_eval.py`,
  51/51).

## What is built

The full loop (capture, morning digest, reply-to-correct, EOD recap) plus:
natural-language everything (complete/drop/reschedule/amend/bulk, queries and
search, history, undo); typed-intent date resolution with day-word backstops;
priorities, project tags, recurring tasks, notes, waiting-on; timed reminders
with a lead time, snooze, and reply-to-act; conversational focus and edited-
message sync; Telegram-native forward-to-capture, react-to-complete, and a
pinned digest; stale-task nudges; chat-settable wake/recap times; the kettle bot
avatar; a `doctor` preflight and `scripts/setup.sh`. Details in
[docs/features.md](docs/features.md).

## How development goes here

Screenshots of live misbehavior are the usual input. Reproduce against the real
model with a throwaway scratchpad probe, fix correctness deterministically in the
core (not the prompt), add a test and an eval case, then restart the daemon
(`launchctl kill SIGTERM gui/$(id -u)/com.local.hob`) and confirm live. See
CLAUDE.md for the full loop and the established deterministic backstops.
