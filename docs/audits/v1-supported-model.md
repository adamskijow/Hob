<!-- SPDX-License-Identifier: MIT -->
# 1.0 supported-model increment audit

Audit baseline: stacked durable-install draft PR #5. Hob documented and pulled
7B by default while every release-quality corpus run used 14B. That made first
install cheaper but silently assigned new owners a materially weaker product.

Release status: implemented on a stacked branch. It cannot merge, release, or
deploy ahead of its five parents. CI, clean-install, VoiceOver, and
representative-hardware latency gates remain.

## Decision evidence

- `qwen2.5:14b-instruct` passes the complete 75/75 release corpus.
- `qwen2.5:7b-instruct` passes 53/75 on the same prompt, schema, deterministic
  core, fixture, date, Ollama runtime, and Mac.
- The 22 failures are broad and safety-relevant. They include completion,
  ordinal reference, bulk completion, planning, undo, priority, deadline,
  duration, reminder, tagging, setting, focus, note, negation, and typo cases.
  Many become captures, which can acknowledge the wrong state.
- The official Ollama Q4_K_M 14B artifact is 9.0 GB. Exact corpus evidence was
  collected on Apple M5 Max with 128 GiB physical memory.

## Product decision

Hob 1.0 supports one model: `qwen2.5:14b-instruct`. It becomes the config,
setup, and documentation default. Alternate models remain available to
developers but are not silently accepted by doctor or durable install. The
owner must set `HOB_ALLOW_EXPERIMENTAL_MODEL=true`, which produces explicit
unsupported wording. Service status reads the installed plist and labels its
actual model as supported or experimental.

Hob recommends 24 GiB physical memory for the 9.0 GB model plus macOS, context,
and resident-runtime headroom. This is deliberately labeled a conservative Hob
recommendation, not an Ollama minimum or a measured latency guarantee. Lower
memory may work, but 1.0 will not promise it without a representative rehearsal.

## Automated evidence

- 396 deterministic tests and compile pass locally.
- The complete exact-head 14B corpus passes 75/75; the same 7B probe passes
  53/75 with the 22 named failures summarized above.
- Both plist lints, shell syntax, and the signed EventKit bridge build pass.
- Read-only live status reports the installed released daemon's actual 14B model
  as supported and identifies the different candidate checkout without restart.
- The runtime default, setup default, generated plist, doctor, status, README,
  development guide, handoff, and acceptance audit agree on the contract.

## Increment audit

| Criterion | Finding and implementation | Evidence before release |
| --- | --- | --- |
| User onboarding | A first owner should not unknowingly install the 53/75 tier. Setup now pulls 14B and doctor states support, memory, and experimental status before service installation. | Clean setup with default; unsupported override refusal; acknowledged experimental path; disk and memory failure wording. |
| User experience | The supported path is one default, not a model-selection quiz. Advanced override remains possible with one explicit risk acknowledgement. | Setup transcript and doctor output on supported, missing, and experimental models. |
| Customer experience | Larger download and memory cost are visible before the owner expects a working bot. Quality failures are not externalized as mysterious task mistakes. | Download-time wording, disk-space failure, cold-load timing, steady reply latency, and retry guidance. |
| LLM-native differentiation | Model classification quality is part of the product contract because natural correction and planning distinguish Hob from a form scheduler. The deterministic core cannot compensate for every wrong intent family. | Exact full corpus on every supported model and named failure review for rejected candidates. |
| Bugs and robustness | A syntactically valid JSON-capable model is not automatically supported. Doctor gates model identity separately from installation/presence and reports physical memory without crashing when unavailable. | Config/default, unsupported, acknowledged override, memory-known, memory-unknown, and model-missing tests. |
| Privacy and safety | All evaluation remains local. Output records model names, aggregate hardware, and case outcomes, never owner prompts or live task data. | Log/status/privacy review and fixture-only corpus inspection. |
| Consent and reversibility | Existing explicit overrides still work after acknowledgement; reverting to the supported model is an environment change plus service reinstall and does not mutate tasks. | Override, reinstall, status, restart, and task-state equality checks. |
| Failure states | Low memory, missing pull, Ollama outage, bad model name, and experimental selection must produce distinct next actions. | Inject every preflight state and check exit code plus secret-free text. |
| Accessibility | Model and memory status are plain text with `OK`, `WARN`, or `FAIL` words, not color-only output. | VoiceOver doctor/setup pass. |
| Operations | The 9.0 GB artifact and exact test hardware are disclosed. 24 GiB is labeled a recommendation pending broader measurements. | 24 GiB representative Mac rehearsal, cold/warm latency, sleep/reload, and seven-day resident operation. |

## Release gates

- Defaults, doctor, setup, plist generation, docs, and tests agree on 14B.
- Complete 75/75 corpus passes again on the exact increment head.
- Deterministic, compile, native, plist, Ubuntu, and macOS gates pass.
- Clean install shows download/resource expectations before pulling or loading.
- Representative 24 GiB hardware completes setup and a defined cold/warm
  latency rehearsal, or the recommendation is raised to the lowest proven tier.
