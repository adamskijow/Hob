<!-- SPDX-License-Identifier: MIT -->
# Telegram security audit

Date: 2026-08-15. Baseline: v0.9.12.

## Result

- Messages, captions, unsupported media, reactions, and callbacks share one
  private-owner gate.
- Fresh installs pair locally. `/start` shows the sender ID and exact
  `scripts/hobctl pair ID` command.
- Existing paired owners require no action.
- Unauthorized traffic stays silent and never reaches content storage.
- Reply references use `(chat_id, message_id)`.
- Missing reaction actors, cross-chat collisions, group callbacks, repeated
  unpaired starts, and owner-chat rebinding have regressions.
- Authorized updates remain durable and retryable.
- Completed inbox, outbox, and reply-reference rows expire after 30 days and cap
  at 1,000 rows per table. Pending work is exempt.

## Onboarding gap

Open Local pairing requires one Terminal command. The Store edition needs a
no-Terminal owner flow before release.
