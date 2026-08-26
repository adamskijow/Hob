<!-- SPDX-License-Identifier: MIT -->
# Foundation Models interpreter

One `@Generable` response describes the whole message as compact actions:
intent, task, saved-task target, detail, and subtype. Hob then derives dates,
clocks, effort, priority, and recurrence from the original words.

The validator rejects ungrounded targets, invented constraints, mixed
read/write responses, duplicates, unsupported completion, and oversized action
sets. One fresh-session repair may correct a rejected parse. A small fallback
handles only explicit cases such as a failed `nada` generation or a grounded
relative date.

Live regressions combine production failures, the retired Ollama interpreter
evals, and reminder/calendar utterance shapes from TOPv2 and SMCalFlow. The
corpus runs twice to expose model variance. It covers slang, multi-task
completion, coordinated appointments, recurrence, relative dates, queries,
focused edits, and false recurrence.

References:

- Apple, [Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
- [TOPv2](https://arxiv.org/abs/2012.12604)
- [SMCalFlow](https://aclanthology.org/2020.emnlp-main.365/)
