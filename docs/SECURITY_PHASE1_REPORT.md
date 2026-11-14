# DWLY EGY — Security Phase 1 Report

**Scope:** order idempotency, checkout atomicity, inventory locking, discount locking, refund/payment state transitions, and private fingerprint storage.

## Files added

- `backend/supabase/migrations/0006_refunds.sql` — carries forward the supplemental refund workflow as a first-class migration; the supplemental source file is preserved separately in the handover backup.
- `backend/supabase/migrations/0007_order_idempotency.sql` — creates a private fingerprint store, SHA-256 canonical fingerprint function, historical fingerprint backfill, and replaces `public.place_order`.
- `backend/supabase/migrations/0008_commerce_hardening.sql` — merges safe supplemental fixes for discount locking, order/payment state guards, and late payment webhook handling.
- `backend/scripts/test_concurrent_last_unit.sh` — launches two independent PostgreSQL sessions against the same final inventory unit.

## Files updated

- `backend/supabase/tests/database/rls_and_orders.test.sql` — aligns the unverified-email expectation with actual function order and adds key-reuse, changed cart/variant, atomic rollback, and last-unit coverage.

No original migration from `0001` to `0005` was edited or deleted. `original/DWLY_EGY_V1.html` remains unchanged.

## Idempotency design

1. `place_order` derives the authenticated user and reads the cart, product variants, current stock, and prices from PostgreSQL. It accepts no browser-supplied price or line-item snapshot.
2. The server creates a canonical JSONB representation of the checkout inputs, server-priced lines, shipping, discount, payment method, and delivery data, then hashes its UTF-8 representation with SHA-256.
3. The digest is stored only in `private.order_request_fingerprints`; the raw request JSON is not stored in browser storage or a public table.
4. A transaction-scoped advisory lock serializes the same `(user_id, idempotency_key)` pair. The existing unique constraint on `orders(user_id, idempotency_key)` remains as a second guard.
5. On retry, the function rebuilds the fingerprint using the persisted order snapshots. If the cart has been repopulated, its variant/quantity set must match the original order. A changed address, phone, governorate, city, delivery notes, payment method, discount code, quantity, size, or color variant is rejected.
6. For a new order, the cart and cart-item rows are locked, then inventory rows are locked in `variant_id` order. Stock decrement, order header/items, movement log, discount redemption, payment row, history, and cart clearing all occur in the same PostgreSQL transaction.
7. Any exception rolls back the entire function statement, including order creation, fingerprint insertion, stock updates, and cart clearing.

## Supplemental SQL reconciliation

- The supplemental `0006_refunds.sql` is promoted into the ordered migration chain.
- The safe `0004_functions.sql` changes are applied through `0008_commerce_hardening.sql`; the historical `0004` file remains unchanged.
- Discount eligibility and usage-limit checks now use the locked discount row when ordering.
- Staff cannot mark an order/payment refunded through generic status RPCs; refund completion uses the refund workflow.
- Payment webhooks no longer accept a generic `refunded` event, cannot downgrade settled payments, and only mark failures while the payment is pending/unpaid/failed.
- The original test expecting `CART_EMPTY` for an unverified user was corrected to `EMAIL_NOT_VERIFIED`, matching the function's actual validation order.

## Test status

### Executed in this environment

- `python3 backend/scripts/static_check.py --verbose` — **219 passed, 0 failed**.
- Archive integrity and original V1 SHA-256 were verified before this phase; original assets were not modified.
- Static checks validate migration numbering, public-table RLS coverage, policy/grant patterns, SECURITY DEFINER search paths, FK ordering, money constraints, seed hygiene, and secret hygiene.

### Authored but NOT executed

- pgTAP suite `backend/supabase/tests/database/rls_and_orders.test.sql`.
- True concurrent last-unit and same-user/same-key retry tests `backend/scripts/test_concurrent_last_unit.sh`.

The runtime has no `psql`, PostgreSQL server, Docker, Supabase CLI, or pgTAP installation. Network access is unavailable, so these tools could not be installed. **No PostgreSQL or pgTAP test is reported as passed.**

## How to run the database tests

With Docker and Supabase CLI installed locally:

```bash
cd backend
supabase start
supabase db reset
supabase test db
```

For a true concurrent race test after applying migrations to the local Supabase database:

```bash
DATABASE_URL='postgresql://postgres:postgres@127.0.0.1:54322/postgres' \
  ./backend/scripts/test_concurrent_last_unit.sh
```

Expected race invariant: one checkout succeeds, one fails for insufficient stock, exactly one order is committed, and stock is zero.

## Known limitations / follow-up

- Runtime verification remains mandatory before production use.
- The frontend is absent from the supplied archive; no client integration was possible in this phase.
- A deployment owner must run migrations against a staging database and inspect the backfill row counts before production rollout.
- Existing checkout callers must continue passing the same idempotency key for retries. They must not generate a new key on every network retry.
- The current authenticated checkout still requires verified email, as in the original design.
- The fingerprint covers the order fields represented by the existing schema. If new checkout-affecting fields are added later, the fingerprint version and canonical payload must be updated in a new migration.
