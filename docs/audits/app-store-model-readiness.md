<!-- SPDX-License-Identifier: MIT -->
# App Store model-readiness audit

Date: 2026-07-11. Parent: PR #9.

## Result

Setup and Settings can run a privacy-safe generation probe before clearing the
Apple model blocker. The built-in probe contains no task, message, or Calendar
data. A 30-second deadline and bounded protocol cover missing, unavailable,
timed-out, malformed, and mismatched responses.

## Covered

- Visible checking progress and retry
- Successful generation as the readiness condition
- Versioned response with random request correlation
- 100,000-byte output cap and one active probe
- Embedded command tool with sandbox inheritance and stable signing ID
- Separate missing-tool, timeout, unavailable, and invalid-response states
- Text labels for status and progress

## Open gates

1. Test a distribution-signed build on eligible and ineligible hardware.
2. Verify archived entitlements and sandbox inheritance.
3. Document supported languages and locales.
4. Run Apple model output through the shared task corpus.
5. Complete accessibility, sleep/wake, update, and helper lifecycle tests.
