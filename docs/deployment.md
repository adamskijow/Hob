<!-- SPDX-License-Identifier: MIT -->
# Deployment

## Current local deployment

- iPhone: signed development build on the paired phone
- Mac: signed development build at `/Applications/Hob.app`
- Distribution: no TestFlight or Store upload

Build from `main`, verify both test suites, install on the local devices, and
confirm the exact commit before daily use. Signing details stay local.

The Mac app is the intended login item and menu-bar surface. Rehearse reboot and
login before calling startup complete.

## Retired Open Local deployment

The old `com.local.hob` and `com.local.hob.menu` LaunchAgents are disabled. Their
property lists are archived under:

```text
~/Library/Application Support/Hob/retired-open-local-20260821/
```

Hob's downloaded Ollama model was removed. Do not run `scripts/setup.sh`,
`scripts/install_macos.sh`, or enable those agents unless the user explicitly
asks to restore the legacy edition.

Historical Open Local deployment and recovery behavior remains in the `v0.9.x`
audit records.
