<!-- SPDX-License-Identifier: MIT -->
# 1.0 grounded-explanation increment audit

Audit baseline: stacked queue-recovery draft PR #3. The 1.0 acceptance audit
identifies a product gap after Hob computes a feasible plan or outlook: the
owner can see the result but cannot naturally ask why a task was placed,
deferred, or marked at risk, or what explicit input could make it fit.

Release status: implemented on a stacked local branch. This branch is stacked
on three unreleased increments and cannot merge, release, or deploy ahead of
them. CI, accessibility, and live dogfood gates remain.

## Implementation evidence

- A versioned, bounded local artifact records the latest plan/outlook's exact
  blocks, partial/deferred/risk outcomes, remaining effort, deterministic reason,
  parsed preferences, and aggregate Calendar coverage.
- Model target hints require a validated id, exact full label, or strong
  multiword match. Literal user wording can identify a unique label; ambiguous
  matches ask. A model-only single word cannot select a target.
- Literal explanation questions retain a narrow read-only route during model
  outage. Ordinary model-dependent requests keep the existing retry behavior.
- Explanations create no action batch, plan run, setting, task mutation, or
  adoption. A combined explanation/setting response is deterministically reduced
  to explanation only.
- 384 deterministic tests, compile, the signed native build, and both plist
  checks pass locally. The complete 14B real-model corpus passes 75/75 after
  deterministic recovery of every failure found in two preliminary runs.
  Ubuntu/macOS CI remains.

## Defects found during implementation

- Planner backstops initially could not run after the interpreter's model-outage
  sentinel. The safe detector now runs at the edge only for this read-only intent.
- Split work was initially flattened to “scheduled” even when effort remained.
  The artifact now preserves placed blocks and a deterministic partial reason.
- “What would make it fit?” initially implied that exactly the remaining minutes
  guaranteed success. Options now include visible buffers and do not overpromise
  around fragmentation.
- A model-supplied single-word target could initially select a task the user had
  not named. Target hints are now confidence-bounded as described above.
- The expanded real-model run exposed a legacy target emitted as explanatory
  prose containing `item id:1`. The core now accepts only that explicit displayed
  position marker, while the prompt requires the actual stored id token.
- A second full run exposed two more legacy model-shape failures: `[70]` for the
  documented `[60, 10]` reminder grammar, and a new recurrence aimed at an
  unrelated existing item. Literal offsets now own the first case; the second
  requires strong task-name support before any existing series can be edited and
  otherwise recovers the new recurrence plus its stop count. Both pass exact
  model probes and the final 75/75 corpus.
- End-to-end outlook review found that fully allocated late work was described
  as partly scheduled with zero minutes remaining. Lateness risk now states the
  recorded blocks and deadline without implying unfinished effort.
- Transcript review found a proposal could defer work against a 40-minute
  what-if budget and then say 450 minutes remained open because physical profile
  capacity and requested budget were conflated. Plans now state both quantities,
  and repair wording says the budget must cover task effort plus visible buffers.

## Product decision

The model may classify a natural follow-up as an explanation request and help
identify which displayed task the owner means. It may not invent an explanation
or alter scheduling facts. Hob will persist a typed snapshot of the last daily
plan or weekly outlook, validate any target against that snapshot, and render
the answer from deterministic facts only.

“What would make it fit?” returns explicit options derived from the recorded
reason, such as adding capacity inside the relevant window, reducing a visible
estimate, resolving a named prerequisite, allowing splitting, or changing a
planning day. It does not change a task, setting, plan, reminder, or Calendar.
The owner must state a concrete correction through the existing inspectable,
undoable setting/task path or request a new proposal.

## Increment audit

| Criterion | Finding and design requirement | Evidence before release |
| --- | --- | --- |
| User onboarding and discoverability | First-plan coaching and help should teach one short follow-up: “why did this not fit?” The no-context response must point to “plan my day” or `/outlook`, not expose an internal term such as snapshot. | Fresh-owner journey from first task to plan, explanation, explicit correction, new proposal, and adoption. Returning-owner help/settings path must remain compact. |
| User experience | Answers lead with the requested task and concrete reason, then the smallest relevant assumption and next safe action. Ordinals and displayed labels work; ambiguous targets ask rather than guess. Generic “why this plan?” summarizes the governing window, capacity, defaults, and Calendar coverage. | Exact wording tests for scheduled, deferred, risk, unplaced, inferred-duration, prerequisite, no-context, ambiguous, stale-item, and generic questions. |
| Customer experience | The loop should reduce the work of reverse-engineering a generated schedule and make disagreement repairable in chat. It must distinguish explaining the last result from generating a new result. | Dogfood at least five real disagreements; record whether the answer identified the actual assumption and whether one follow-up produced a useful new proposal. |
| LLM-native differentiation | Natural reference and intent classification are valuable, but all claims come from a deterministic decision artifact. The model never sees Calendar titles and never decides capacity. This conversational repair loop is the primary differentiation from a form-based scheduler. | Real-model cases for “why the second one,” paraphrased labels, “what would make it fit,” generic tradeoff questions, and adversarial requests to invent or silently change assumptions. |
| Bugs and correctness | A decision snapshot is versioned, bounded, and replaced only after a completed plan/outlook computation. Targets are validated against it. Explanation uses facts at generation time rather than mutable current task state. Malformed or old snapshot data fails to a clear regeneration prompt. | Pure snapshot/parser/renderer tests, edge integration tests, corruption/restart/export tests, complete suite, and exact-head real-model corpus. |
| Privacy and safety | Snapshot data stays in the existing local SQLite store. It includes task labels already shown in the result, opaque capacity facts, and aggregate Calendar status, never event titles/ids, message transport ids, or hidden behavior-derived traits. No explanation payload enters status or logs. | Secret-bearing Calendar adapter test, export review, log review, unauthorized-user path, and prompt inspection. |
| Consent and reversibility | Explanation is read-only. Suggested options are not settings or mutations. A correction must use the existing explicit setting/task edit or new-proposal path; adoption remains a separate explicit action. | Before/after state equality around every explanation, no action-log batch, no new plan run, and explicit correction/undo/adoption integration tests. |
| Failure states and robustness | Model outage can still use literal explanation backstops and deterministic target matching. Unknown/ambiguous targets never inherit a nearby task. Missing/corrupt snapshots do not crash. Restart retains the last explanation context, while a new plan/outlook replaces it atomically. | Model-down, malformed model output, corrupt JSON, no matching target, tied target, restart, rapid successive result, and transaction rollback tests. |
| Accessibility | Text carries every fact and action. Answers do not rely on block position alone, emoji, color, buttons, or a visual chart; exact dates/times accompany human language where relevant. | VoiceOver Telegram pass, text-only follow-up pass, long-label wrapping, and ordinal plus label restatement checks. |

## Deliberate scope

- Explain the latest daily proposal or weekly outlook, including scheduled,
  deferred, at-risk, and outside-horizon work.
- Support a generic explanation and one validated displayed-task target.
- Offer deterministic, non-mutating ways to change the relevant constraint.
- Preserve the exact decision-time assumptions and aggregate Calendar coverage.
- Add help/onboarding discovery without expanding the five-step setup flow.

## Exclusions

- No free-form model-authored causal story.
- No automatic preference learning, estimate correction, task edit, adoption,
  Calendar write, or hidden memory.
- No counterfactual optimization across arbitrary combinations in this
  increment. A stated new constraint creates a new normal proposal/outlook.
- No explanation of private Calendar event identity or content.

## Release gates

- Every explanation claim maps to a field in the versioned decision snapshot.
- The latest-result target is unambiguous or Hob asks; it never substitutes a
  different task because the words are similar.
- Explanation and option generation are state-equality proven read-only.
- Deterministic, real-model, native, plist, Ubuntu, and macOS gates pass.
- Fresh-owner discovery, five-disagreement dogfood, VoiceOver, model-outage,
  restart, privacy, and malformed-snapshot rehearsals pass.
