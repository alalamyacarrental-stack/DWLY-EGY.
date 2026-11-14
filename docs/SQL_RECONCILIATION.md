# SQL Archive Reconciliation — DWLY EGY

The primary project archive and supplemental SQL archive were compared before changes. Neither source archive was modified.

## Decisions

| Supplemental file / change | Action in working copy | Reason |
|---|---|---|
| `0006_refunds.sql` | Promoted to `migrations/0006_refunds.sql` and explicit execute revokes added | Refund flow was present only in the supplemental archive; it belongs in the ordered migration chain. |
| Discount validation in supplemental `0004_functions.sql` | Reimplemented in `0008_commerce_hardening.sql` | The locked discount row is now the row used for active/date/usage checks, preventing stale usage-limit decisions. |
| Remove `delivered -> refunded` from generic transition helper | Reimplemented in `0008_commerce_hardening.sql` | Refund completion must use the dedicated refund workflow. |
| Block generic order/payment `refunded` status updates | Reimplemented in `0008_commerce_hardening.sql` | Prevents bypassing refund amount checks and refund records. |
| Payment event status restricted to `success` / `failed` | Reimplemented in `0008_commerce_hardening.sql` | Refunds are processed through `record_refund_event`, not payment webhooks. |
| Ignore late success after paid/refunded and prevent late failure downgrades | Reimplemented in `0008_commerce_hardening.sql` | Prevents out-of-order provider events from changing settled state. |
| Supplemental test expects `EMAIL_NOT_VERIFIED` | Updated in the working pgTAP suite | `place_order` verifies the account before checking the cart, so this is the actual expected error. |

## Preserved

- `0001_foundation.sql` through `0005_security.sql` remain byte-identical to the original project archive.
- Supplemental `0004_functions.sql` and its test file remain in the separately preserved source archive; no source file was overwritten.
- New behavior is introduced only through migrations `0006`–`0008`.
