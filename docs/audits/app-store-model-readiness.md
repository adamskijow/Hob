<!-- SPDX-License-Identifier: MIT -->
# App Store model-readiness increment audit

Date: 2026-07-11. Parent: merged background-service PR #9.

## Customer outcome

An App Store customer can deliberately check whether Apple's on-device model
can complete real generation before Hob implies that setup is ready. The check
uses a built-in phrase and never includes tasks, Telegram messages, or Calendar
data. Failure remains a setup blocker with a human recovery path.

## Increment audit

| Criterion | Evidence | Assessment |
| --- | --- | --- |
| User onboarding | First-run is one continuous scroll rather than stacked scrolling forms. Setup and Settings show one On-Device Intelligence section, current status, what data the check excludes, and Check or Check Again | Clear, explicit, repeatable, and usable at the default window size. It does not run a potentially slow model request without an owner action. |
| Usability | Checking has visible progress. Ready, unavailable, missing-tool, timeout, and invalid-response states have distinct language | No silent spinner, nested-form trap, or raw framework error. The 30-second timeout is stated when it happens. |
| Customer experience | Only successful generation clears the model blocker; reported framework availability cannot create a false-ready moment | Resolves the highest-risk first-run trust defect in this seam. Background delivery and owner pairing remain honestly blocked. |
| Privacy | The probe content is compiled into Hob. The app sends no customer content and the bridge does not log prompts | Appropriate for first-run eligibility. Telegram transit disclosure remains a later onboarding requirement. |
| Bugs and feature robustness | Tool input and output are bounded, responses are protocol-versioned and correlated to a random request id, concurrent button presses are ignored, execution has a deadline, and every non-available bridge status fails closed | Strong foundation. The controller never converts an unknown or malformed response into readiness. |
| Sandbox and packaging | Xcode builds a command tool inside the signed login item. Its entitlement file contains exactly `app-sandbox` and `inherit`; injected base entitlements are disabled and the signing identifier is stable | Matches Apple's embedded sandbox-helper pattern. CI checks bundle placement; local ad hoc signing checks the realized entitlement boundary. |
| Accessibility | Status is text, progress has a label, and the action has a conventional button label. No color, animation, or icon is required to understand readiness | Suitable automated foundation. VoiceOver, keyboard focus order, text scaling, and reduced-motion still need manual RC evidence. |
| Operations | Missing binary, launch failure, timeout, malformed output, and unavailable model all remain non-ready and recoverable through Check Again or reinstall guidance | Safe failure behavior. No task runtime or live Open Local daemon is affected by this increment. |

## Test matrix

| Path | Expected result |
| --- | --- |
| Real generation succeeds | Ready and the model readiness blocker clears |
| Apple Intelligence disabled, unsupported, or assets unavailable | Unavailable with settings/download guidance |
| Bridge absent or not executable | Model tool missing with reinstall guidance |
| Bridge exceeds 30 seconds | Check timed out; readiness remains false |
| Output exceeds 100,000 bytes, is malformed, has the wrong version or request id, or lacks status | Check failed; readiness remains false |
| Any bridge status other than `available` | Unavailable; readiness remains false |
| Check selected while already checking | No duplicate model process starts |

## Remaining release gates

1. Run the distribution-signed app on eligible Apple Intelligence hardware and
   record success, disabled, assets-downloading, and service-failure states.
2. Validate actual App Store distribution entitlements and inheritance after
   archive export, not only ad hoc and unsigned CI builds.
3. Add supported-language and locale guidance before onboarding accepts
   customers whose language the system model cannot serve.
4. Connect generation to the portable deterministic Hob runtime, then run the
   shared interpretation corpus without granting the model mutation authority.
5. Complete VoiceOver, keyboard, text-size, contrast, sleep/wake, update, and
   helper lifecycle rehearsals.

## Decision

Accept this increment as the model eligibility and packaging foundation. Do not
call the Store edition usable or distributable yet. The next highest-value
increment is the portable task-runtime boundary and shared behavioral fixtures,
because a healthy model and helper still cannot capture or schedule a task.
