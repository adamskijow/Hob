<!-- SPDX-License-Identifier: MIT -->
# ADR 0001: one Hob core, two macOS editions

Status: accepted for implementation, 2026-07-11.

## Decision

Hob will support two macOS distribution editions with the same behavior and
portable data contract:

1. **Open Local edition.** The current source distribution uses Ollama, Hearth,
   Telegram, SQLite, a signed EventKit bridge, and a user LaunchAgent. It remains
   the configurable edition for owners who choose their own local model.
2. **Mac App Store edition.** An Xcode-owned, sandboxed application bundle uses
   Apple's on-device Foundation Models, a consented bundled background helper,
   container or App Group storage, EventKit, and the existing Telegram service.
   It never installs or depends on Homebrew, uv, Ollama, Hearth, or code outside
   its signed bundle.

The Python `core/` behavior remains the reference implementation. The App Store
bundle may embed a pinned Python runtime and dependencies if submission
rehearsals prove that path reviewable, self-contained, sandbox-correct, and
maintainable. If they do not, deterministic core behavior will move behind a
portable native library rather than being independently reimplemented. Golden
fixtures must make divergence between editions a release-blocking failure.

The first native package in `native/HobAppFoundation` establishes three seams:

- a small SwiftUI menu-bar and settings surface for setup, privacy, and health;
- typed readiness rules that never call an edition ready while model, owner, or
  background-service consent is missing;
- a bounded JSON bridge to Apple Foundation Models so existing validated Hob
  prompts can be evaluated without giving the model mutation authority.

The bridge returns model text only. Existing schema validation, deterministic
date math, planning, confirmation, action-log, and undo rules remain the trust
boundary. Foundation Models is an interpreter adapter, not a scheduler.

## Why

A wrapper around the released daemon would retain the hardest setup work and
would not satisfy the App Store's self-contained or sandbox expectations. A
full independent Swift rewrite would create two correctness implementations for
dates, recurrence, undo, planning, and recovery. The chosen path builds a native
product and distribution boundary while preserving one behavioral authority.

## Non-negotiable App Store boundaries

- The main app and every executable helper are sandboxed and signed together.
- Background operation is registered with `SMAppService` only after a clear
  owner action, remains visible in the UI, and can be disabled there.
- The app opens outbound connections only; it never exposes a local server.
- Calendar access uses EventKit with an honest full-access explanation because
  Apple offers no read-only authorization tier. Hob still emits only opaque busy
  ranges to its planner and never event titles.
- Tasks and plans live in the container or App Group. Import and export outside
  it use user-selected security-scoped URLs.
- The Store bundle contains every executable dependency. It never downloads or
  launches Ollama, Python packages, installers, or feature code.
- Apple Intelligence availability is checked before setup promises completion.
  A harmless generation probe must also pass because the framework's reported
  availability can precede required model-service assets. Unsupported hardware,
  disabled Apple Intelligence, and unavailable assets get an actionable state,
  not a broken chat loop.
- Telegram transit is disclosed during onboarding and in Store privacy details.
  “Local” never implies that Telegram messages remain on the Mac.

## Release and parity policy

The Open Local edition can reach 1.0 before App Store review, but the Store
edition cannot use the 1.0 version until it passes the same behavioral corpus,
onboarding and accessibility journeys, data migration/export compatibility,
background delivery rehearsal, sandbox audit, privacy disclosure review, and
App Review submission build. A missing Store feature must be labeled as such;
the editions may not quietly disagree about task or plan semantics.

## Rejected alternatives

- **Require an existing Ollama install.** This violates the one-click product
  goal and is in direct tension with the Store's self-contained requirement.
- **Download Ollama after install.** The Store edition will not download or
  install executable functionality.
- **Cloud model by default.** This weakens Hob's privacy position and adds a
  service dependency. It can be reconsidered only as an explicit separate
  product decision.
- **Immediate independent Swift rewrite.** It creates unacceptable semantic
  drift before portable fixtures and parity gates exist.
