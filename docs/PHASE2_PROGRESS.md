# DWLY EGY — Phase 2 Progress

## Increment 2.1 — Storefront foundation
- React + TypeScript + Vite storefront, original visual identity retained.
- Public catalog query filters active, non-demo products.
- Product details, sizes/colors, search/sort, email/password auth, and cart draft foundation.
- Checkout, address book, order history, and admin dashboard remain pending.

## Increment 2.2 — Catalog integration audit
- Reconciled frontend reads with migrations 0002–0005: `products`, `categories`, `product_variants`, `sizes`, `colors`, `product_images`, `variant_stock`, `carts`, `cart_items`, and `cart_set_item`.
- Confirmed `variant_stock` is an existing public-safe view, not a table; it exposes `variant_id`, `product_id`, capped `available`, and `in_stock`. Frontend reads only the boolean.
- Fixed stock-read failure handling to fail closed, missing stock rows are unavailable, and missing Supabase configuration no longer appears as a genuinely empty catalog.
- Added image-load fallback behavior and migration 0010 to exclude demo merchandise from public stock availability and public catalog RLS reads; staff retains QA access.
- Documented public Storage bucket semantics and setup instructions.

## Test status
- Static database/repository checks: 219 passed, 0 failed.
- Supabase source/schema contract audit: 29 passed, 0 failed.
- Shell syntax check for the existing concurrency test: passed.
- npm install: attempted; timed out contacting npm registry.
- npm run build: attempted; failed because dependencies are absent (npm install could not complete). No successful production build is claimed.
- No live Supabase, RLS, Storage, browser, or Postgres integration tests were run.

See `docs/INCREMENT_2_2_REPORT.md` for the schema reconciliation, exact setup steps, and limitations.
