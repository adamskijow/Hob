<!-- SPDX-License-Identifier: MIT -->
# 1.0 time-correctness increment audit

Baseline: v0.9 draft PR #1, stacked without changing released v0.8 or the live
daemon. This increment addresses the highest-risk onboarding defect found by
the 1.0 acceptance matrix: a successful fresh setup could still run in UTC or
silently invent a local time during a daylight-saving transition.

## Audit criteria

| Area | Finding | Increment response |
| --- | --- | --- |
| User onboarding | Default UTC makes a polished setup misleading when the operator omits `HOB_TIMEZONE`. | Discover the system IANA timezone on a real install, retain explicit override and UTC fallback, show the active zone at every setup start, and remove the New York plist placeholder. |
| End-to-end customer experience | A digest or reminder at a skipped/repeated hour has surprising semantics. | Catch up a skipped digest once, send repeated-hour digest once, and explain reminder behavior in the message. |
| LLM-native differentiation | The model cannot safely decide whether a wall time exists. | Keep timezone/DST classification deterministic and outside the model. No prompt or intent change is required. |
| Bugs and robustness | `datetime(..., tzinfo=ZoneInfo(...))` accepts nonexistent and ambiguous wall times without an error. | Round-trip through UTC to classify valid, nonexistent, and ambiguous readings. Defer fixed work in either unsafe case rather than moving or guessing it. |
| Privacy and safety | Location inference can expose more than needed if sent remotely. | Read only the local `TZ`, `/etc/localtime`, or `/etc/timezone` configuration. Persist and transmit no inferred location; only the IANA zone already visible in `/settings` is shown. |
| Operational reliability | Plist templates hard-code a region that an operator can forget to edit. | Omit the timezone variable by default so the daemon uses the Mac setting; doctor and setup expose the chosen value. Existing explicit configurations remain authoritative. |
| Accessibility | Silent temporal normalization is difficult to detect, especially through a text-only interface. | Use plain-language conflict and reminder text; do not rely on offsets, icons, or Calendar UI to communicate the DST decision. |

## Deterministic policy

- Ordinary local times are unchanged.
- A fixed task at a spring-forward time that does not exist is not planned or
  moved. Hob explains that the clock skipped it and asks for clarification.
- A fixed task at a fall-back time that occurs twice is not assigned to either
  occurrence silently. Hob explains the ambiguity and asks for clarification.
- A reminder for a skipped time catches up at the first later check and says the
  clock skipped the requested time. Durable reminder state keeps it once-only.
- A reminder for a repeated time uses the first occurrence, says so explicitly,
  and is marked before the second occurrence.
- Digest and EOD scheduling continue to use once-per-local-date state. A skipped
  wake time catches up; a repeated wake time cannot send twice.
- Calendar periods and adopted sessions retain their explicit ISO offsets.

## Scope

1. System IANA timezone discovery for real installs, with explicit environment
   override and UTC fallback.
2. Setup-time visibility of the active timezone.
3. Pure wall-time classification.
4. Fixed-plan gap/repeat refusal and explanation.
5. Reminder and digest gap/repeat policies with deterministic tests.
6. Documentation and deployment-template correction.

## Deliberate exclusions

- No chat-time timezone mutation because the daemon clock, scheduler, and model
  context must change atomically on restart rather than through partial meta.
- No location lookup, network geocoding, or behavior inference.
- No Calendar writes or alteration of offset-bearing EventKit periods.
- No release, deployment, or live restart before v0.9 has passed its own dogfood
  gate and this stacked increment is reviewed independently.

## Release gates

- System discovery precedence and UTC fallback pass on deterministic fixtures.
- Explicit `HOB_TIMEZONE` behavior remains unchanged.
- Setup and doctor make the active timezone visible.
- Spring gap, fall repeat, ordinary time, fixed planning, reminders, and digest
  once-only behavior have regressions.
- Full Python suite and compile check pass.
- The unchanged interpreter passes the complete real-model corpus on the exact
  commit.
- Signed EventKit build and Ubuntu/macOS CI pass on the stacked draft PR.
- Clean-install and manual macOS timezone/EventKit transition checks remain
  required before the finding can be marked complete for 1.0.

## Evidence

The complete Python suite passes 350 tests and compileall succeeds. The complete
72-case real-model corpus passes on `qwen2.5:14b-instruct`. Both plist files
validate, and the signed EventKit bridge builds locally on macOS. Draft PR #2
targets the v0.9 branch; GitHub Actions run `29158009704` passes on Ubuntu and
macOS, including the native build. On the development Mac, system discovery
returns `America/New_York`, matching `/etc/localtime`. Manual clean-install,
system-zone-change, and EventKit transition evidence remain pending.
