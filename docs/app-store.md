<!-- SPDX-License-Identifier: MIT -->
# Mac App Store track

The App Store edition is an active product track. It is not yet a distributable
app and must not be represented as one until the archive and review gates below
pass.

## Product promise

Install Hob from the Mac App Store, complete setup without Terminal, understand
what stays local and what transits Telegram, explicitly allow background
delivery, and receive the same safe capture, correction, planning, reminder,
and recovery behavior as the Open Local edition.

The Store edition uses Apple's on-device model. The Open Local edition continues
to use Ollama. Both use deterministic Hob logic for dates, plans, mutation,
confirmation, and undo.

The Store target starts at macOS 26 because installing an edition that cannot
provide its required on-device model would be a broken first-run experience.
Within that OS boundary, hardware eligibility, Apple Intelligence settings, and
model assets are still checked explicitly.

## Current foundation

`native/HobAppFoundation` is a buildable Swift package, not an App Store archive:

- `HobAppCore` holds edition-neutral setup/readiness types.
- `HobMacShell` is the initial menu-bar/settings experience.
- `HobFoundationBridge` is a versioned, bounded stdin/stdout adapter. It reports
  reported model availability, verifies real generation with a separate probe,
  and accepts generation requests without logging prompts.
- `AppStore/` records the minimum sandbox, outbound network, Calendar, bundle,
  and permission-description boundary that the Xcode target must consume.

The package intentionally contains no Ollama, uv, Homebrew, launchctl, shell
installer, inbound network server, or arbitrary filesystem entitlement.

## Delivery increments

### A. Submission skeleton

- Create the Xcode app, helper, and test targets with stable bundle identities.
- Embed the native package and all runtime resources in one signed bundle.
- Register the helper with `SMAppService` after explicit consent.
- Add container/App Group storage and a visible helper-health switch.
- Add privacy manifest, App Store privacy worksheet, signing, archive, sandbox,
  and notarized development-export checks.

### B. First-run success

- Explain Apple Intelligence eligibility before asking for other credentials.
- Require a privacy-safe generation probe before calling the model ready; a
  framework availability flag alone is insufficient.
- Create the Telegram bot/token and owner-pairing journey without Terminal.
- Confirm timezone, schedule, Calendar choice, notification behavior, and
  background operation.
- Include a local demo path for App Review that stores no reviewer secrets and
  demonstrates the full safe mutation loop.

### C. Behavioral parity

- Package the reference core or portable shared core without runtime downloads.
- Run shared golden fixtures for every typed action, date edge, recurrence rule,
  plan, confirmation, undo, queue recovery, and export/import version.
- Run the supported Apple model corpus separately because system model updates
  can change interpretation quality.

### D. Store release

- Complete VoiceOver, keyboard-only, reduced-motion, contrast, and text-size QA.
- Exercise install, update, logout/login, sleep/wake, helper denial/revocation,
  Calendar denial/revocation, Telegram outage, Apple Intelligence unavailable,
  database migration, backup/export, and uninstall/data-retention journeys.
- Archive with the shipping Xcode and macOS SDK, validate in App Store Connect,
  complete review metadata and disclosures, submit, and resolve review findings.

## Definition of done

The App Store edition exists only when a customer can install the reviewed build
from the Store and finish the complete first-value journey without Terminal or
another app. A local Swift build or accepted upload alone is not that outcome.
