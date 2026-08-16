<!-- SPDX-License-Identifier: MIT -->
# ADR 0001: one behavior, two macOS editions

Status: superseded by [ADR 0003](0003-universal-apple-app.md), 2026-08-16.

## Decision

Hob supports two macOS editions with shared behavior and portable data:

1. **Open Local:** Python, Ollama, Hearth, Telegram, SQLite, EventKit bridge,
   and user LaunchAgents.
2. **Mac App Store:** sandboxed Xcode bundle, Apple Foundation Models, bundled
   login helper, App Group storage, EventKit, and Telegram.

Python `core/` is the reference implementation. Privacy-safe fixtures execute
against Python and Swift and block release on divergence. Native migration uses
small vertical behavior slices.

The Store runtime carries the original message beside typed model actions. Code
resolves dates, validates targets and confidence, applies changes atomically,
and records undo. Invalid protocols, input bounds, dates, targets, state, or
storage paths reject the turn.

Store state uses a bounded, versioned App Group document with atomic writes and
a verified previous copy. Background activation waits for the complete behavior
corpus and durable delivery pipeline.

## Store boundaries

- Main app and helpers ship sandboxed and signed together.
- Background operation uses `SMAppService` after explicit consent and can be
  disabled in Hob.
- `HobAgent.app` lives in `Contents/Library/LoginItems`.
- App and agent share `group.com.josephadamski.hob` only.
- The app opens outbound connections and exposes no local server.
- EventKit output contains opaque busy ranges without titles.
- Import and export use user-selected security-scoped URLs.
- Every executable dependency ships inside the bundle.
- Model readiness requires Apple Intelligence eligibility and a successful
  bounded generation probe.
- The Foundation Models tool carries sandbox inheritance entitlements, a stable
  identifier, bounded I/O, a correlation ID, and a 30-second deadline.
- Onboarding and Store privacy details disclose Telegram transit.

## Implementation choice

A daemon wrapper would retain Terminal-era setup and conflict with sandbox
distribution. A separate Swift rewrite would duplicate date, recurrence,
planning, recovery, and undo logic. Shared fixtures and incremental native
slices preserve one behavior authority.

## Release policy

Open Local may reach 1.0 before Store review. The Store edition earns the same
version after behavior parity, onboarding, accessibility, migration/export,
background delivery, sandbox, privacy, archive, and App Review gates pass.

## Rejected alternatives

- Require or download Ollama for the Store edition.
- Use a cloud model by default.
- Rewrite the full core in Swift before parity fixtures exist.
