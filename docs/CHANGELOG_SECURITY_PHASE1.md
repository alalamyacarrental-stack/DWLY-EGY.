# Changelog — Security Phase 1

## Added
- `0006_refunds.sql`: first-class refund request/completion flow from the supplemental SQL archive.
- `0007_order_idempotency.sql`: private order fingerprint table, canonical SHA-256 helper, historical backfill, advisory lock serialization, cart snapshot comparison, and hardened `place_order`.
- `0008_commerce_hardening.sql`: discount row locking and validation, refund state guards, and safe payment webhook transitions.
- pgTAP cases for changed payloads, quantity/size/color changes, rollback after an injected stock-update failure, and sequential last-unit sale.
- Two-session concurrency test script for the final inventory unit.

## Security behavior changes
- Reusing an idempotency key with changed checkout details is rejected.
- Reusing a key with a changed cart variant/quantity set is rejected.
- A retry with the original payload returns the original order, including after the successful checkout emptied the cart.
- Concurrent requests with the same key are serialized; inventory rows are locked in stable order for different-key checkout races.
- Stock updates now include a defensive `quantity >= requested_quantity` predicate and raise if no row was updated.
- Refunds cannot be marked complete through generic order/payment status RPCs.
- Late provider failure events cannot downgrade paid/refunded payment states.

## Preserved
- Migrations `0001`–`0005` remain unchanged.
- Original HTML asset and its SHA-256 remain unchanged.
- Supabase/PostgreSQL architecture remains in place.
- Existing RPC signatures for `place_order` remain unchanged.

## Verification
- Static analyzer: 219 passed, 0 failed.
- PostgreSQL / pgTAP / concurrent DB tests: not run in this environment; local DB tooling is unavailable.
