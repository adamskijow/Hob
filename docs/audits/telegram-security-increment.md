# Telegram security increment audit

Audit date: 2026-08-15
Baseline: Hob 0.9.12

## Outcome

This increment closes the first three findings from the read-only security
audit without weakening Hob's durable owner-message path.

| Criterion | Result |
| --- | --- |
| Security | Messages, captions, unsupported media, reactions, and callbacks share one owner/private-chat gate. Message references use `(chat_id, message_id)`, missing reaction identities fail closed, and callbacks cannot rebind proactive delivery. |
| User onboarding | First contact no longer claims Hob. An unpaired private `/start` shows the sender's ID and exact `scripts/hobctl pair ID` command; the locally authorized owner's next `/start` enters the existing resumable setup. Existing paired databases require no action. |
| Customer experience | Unauthorized traffic is silent instead of creating noisy denial loops. Owner media retains its accessible fallback. The menu-bar health summary points toward secure local pairing. |
| Bugs | Schema 11 migrates existing reply anchors under the stored owner chat. Cross-chat collisions, anonymous reactions, group callbacks, repeated unpaired starts, and owner-chat rebinding have regression coverage. |
| Robustness | Unauthorized and service updates advance Telegram's offset without storing content. Authorized work remains durable and retryable. Completed inbox/outbox rows and reply anchors have a 30-day and 1,000-row ceiling; pending work is never pruned. |
| LLM differentiation | No semantic phrase matching or model behavior changed. Authorization remains a deterministic transport concern; every authorized natural-language request still reaches the existing model-owned interpretation path. |

## Remaining usability gap

Open Local pairing still requires one Terminal command. A no-Terminal pairing
control in the Mac app remains a 1.0 onboarding requirement; this increment
chooses a secure, self-explanatory intermediate journey over first-contact
trust.
