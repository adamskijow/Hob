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

The native foundation now has both a tested Swift package and an Xcode-owned
application shell. It is still not an App Store archive:

- `HobAppCore` holds edition-neutral setup/readiness types.
- `HobMacShell` is the initial menu-bar/settings experience.
- `HobFoundationBridge` is a versioned, bounded stdin/stdout adapter. It reports
  reported model availability, verifies real generation with a separate probe,
  and accepts generation requests without logging prompts.
- `AppStore/` records the minimum sandbox, outbound network, Calendar, bundle,
  and permission-description boundary that the Xcode target must consume.
- `native/HobMacApp/HobMacApp.xcodeproj` builds a real `Hob.app` menu-bar bundle
  targeting macOS 26. CI builds it without signing so project drift fails before
  signing credentials or App Store Connect are involved.
- The Xcode app now embeds `HobAgent.app` in `Contents/Library/LoginItems` and
  owns its explicit `SMAppService` register, approval, disable, and recovery
  experience. Both targets resolve storage only through the protected App Group.
  Registration stays locked while the helper is health-only, so this foundation
  cannot falsely claim background delivery.
- `HobAgent.app` embeds the signed `HobFoundationBridge` command tool. The tool
  has only Apple's sandbox-inheritance entitlements, is signed with a stable
  identifier, and is launched by the sandboxed app. Setup calls its bounded
  built-in generation probe only after the owner chooses Check On-Device Model.
  Reported framework availability alone never marks setup ready.
- `HobAppCore.TaskRuntime` is the first native deterministic runtime slice. A
  versioned, correlated, bounded turn request carries the original message and
  typed model actions. The core owns date resolution, exact target validation,
  confidence holds, atomic application, and undo. The same synthetic golden
  fixture runs through the released Python behavior and Swift implementation.
  Xcode compiles this core into both the app and agent, but activation remains
  locked until the complete behavior corpus and delivery edges exist.
- The agent now opens a versioned task-state store only inside the App Group.
  Applied turns and undo history are written atomically with private file modes,
  a 10 MB bound, schema and content validation, symlink refusal, and a verified
  previous-state copy. A failed write leaves the candidate turn uncommitted, so
  no edge can acknowledge a task that was not durably stored. Corrupt data never
  silently becomes an empty list, and recovery from the previous copy is an
  explicit operation.
- State schema v2 adds a durable typed-turn inbox and compact reply outbox. A
  request receipt is stored before deterministic mutation; mutation, completed
  receipt, and pending reply are then replaced atomically. Restart replay,
  repeated request ids, ordering, bounded retry metadata, explicit poison-turn
  quarantine, and v1 migration are tested. The outbox stores no second copy of
  chat or task text. Setup and Storage settings show content-free queue health
  and offer confirmed restore only when the previous local copy verifies.
  Telegram transport is not connected, so registration remains locked.

The Store targets intentionally contain no Ollama, uv, Homebrew, launchctl,
shell installer, inbound network server, or arbitrary filesystem entitlement.

## Delivery increments

### A. Submission skeleton

- Create the Xcode app, helper, and test targets with stable bundle identities.
- Embed the native package and all runtime resources in one signed bundle.
- Register the helper with `SMAppService` after explicit consent.
- Add container/App Group storage and a visible helper-health switch.
- Add privacy manifest, App Store privacy worksheet, signing, archive, sandbox,
  and notarized development-export checks.

The app and helper targets, bundle placement, consent UI, App Group resolver,
embedded model tool, real-generation readiness UI, and unsigned CI packaging
gate now exist. Developer-account registration,
distribution signing, runtime embedding, and lifecycle rehearsals remain open.

### B. First-run success

- Explain Apple Intelligence eligibility before asking for other credentials.
- Require a privacy-safe generation probe before calling the model ready; a
  framework availability flag alone is insufficient. The bounded, correlated,
  30-second probe and actionable unavailable, timeout, missing-tool, and invalid
  response states now exist. A distribution-signed device rehearsal remains.
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

The first shared fixture now covers basic capture, tomorrow and weekday math,
multi-action correction, complete, drop, reschedule, clarification, confidence
confirmation, missing targets, and repeated undo. This is a contract seed, not
parity proof. Recurrence, constraints, planning, queries, settings, durable
inbox/outbox transactions, pending confirmations, reminders, Calendar,
migration beyond the new v1-to-v2 state step, and every literal correctness
backstop remain release gates. The typed-turn inbox/outbox now proves local
mutation idempotency and ordered retry, but Telegram update receipt and reply
rendering remain unimplemented.

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
