# DWLY EGY — Phase 2 / Increment 2.2

## Scope
Audit and harden the Increment 2.1 catalog integration before implementing checkout. No checkout or electronic-payment workflow was added in this increment. Security Phase 1 migrations 0001–0008 were not edited.

## Findings and fixes

1. **Demo products:** the storefront query already filters `products.status = 'active'` and `products.is_demo = false`. No local product fallback or demo product fixture is used by the UI. Migration 0010 additionally excludes demo products from the public stock view and tightens public read policies for products, categories, variants, images, collections, collection items, and banners. Staff retains access to demo rows for QA.
2. **Schema reconciliation:** the catalog uses `products`, `categories`, `product_variants`, `sizes`, `colors`, `product_images`, and `variant_stock`. These names and selected columns were checked against migrations 0002, 0003, and 0005. The stock view is defined in migration 0003 with `variant_id`, `product_id`, `available`, and `in_stock`; `in_stock` is boolean. The cart uses `carts`, `cart_items`, and the existing `cart_set_item(uuid, integer)` RPC.
3. **Inventory privacy:** the UI reads only `variant_stock.in_stock`, not `inventory.quantity`. The underlying `inventory` table remains staff-only under migration 0005. A failed stock-view query now fails the catalog load instead of silently leaving `in_stock` undefined and enabling an unavailable variant. Missing stock rows are treated as unavailable.
4. **Storage:** `product_images.path` stores paths in the `product-images` bucket. Migration 0005 defines this bucket as public for storefront image delivery, with authenticated staff-only insert/update/delete policies. Broken image URLs are hidden instead of showing a browser broken-image glyph. The public bucket is intentionally public: only public catalog imagery should be uploaded there; customer/private documents must never be stored in it.
5. **States:** the storefront distinguishes missing Supabase configuration, loading, query error (with retry), genuinely empty catalog, and empty search results. No demo records are substituted when configuration or requests fail.
6. **Customer data:** the storefront does not query orders, profiles, addresses, or admin data in this increment. Authenticated cart reads are scoped by `user_id` and RLS; cart writes use `cart_set_item`. No service-role key is referenced in frontend code or `.env.example`.

## Database migrations

- `0001`–`0008`: unchanged.
- `0009_initial_shipping_fees.sql`: retained; initializes Cairo EGP 60 and Giza EGP 75 only when no custom fee exists.
- `0010_public_catalog_hardening.sql`: replaces the public `variant_stock` view definition with the same output contract while excluding demo products. It does not grant direct access to `public.inventory` and does not expose exact stock counts.

## Verification performed

- Confirmed migrations 0001–0008 are byte-identical to the accepted Security Phase 1 delivery; original V1 SHA-256 remains unchanged.
- Contract audit `python3 frontend/scripts/check_supabase_contract.py`: 29 passed, 0 failed.

- `python3 backend/scripts/static_check.py --verbose`: see delivered static-check log.
- Source/schema contract audit: checked queried table names and selected columns against migrations 0002–0005; checked the stock view projection and RPC signature.
- `npm install --no-audit --no-fund`: attempted, but timed out while contacting `https://registry.npmjs.org/`.
- `npm run build`: not run successfully because dependencies could not be installed and `node_modules` is absent.
- Live Supabase queries, RLS tests, Storage access tests, and browser tests: not run; no project URL/anon key or connected Supabase database was supplied.

**No live database, browser, or production-build success is claimed.** The next required verification is to apply migrations 0001–0010 to a staging Supabase project, configure the public URL and anon key, then run the frontend build and the catalog/RLS/Storage checks against that project.

## Supabase setup

After applying migrations, the owner can verify the shipping defaults with:

```sql
select name_en, fee, is_available
from public.shipping_zones
where name_en in ('Cairo', 'Giza')
order by name_en;
```

Expected initial values are Cairo `60.00` and Giza `75.00`; pre-existing custom fees are preserved by migration 0009.

1. Install Node.js 20+ and Supabase CLI; Docker is required for local Supabase.
2. From the repository root:
   ```bash
   cd backend
   supabase init   # only if config.toml is absent; preserve migrations
   supabase start
   supabase db reset
   ```
   This applies migrations 0001–0010 and local-only `seed.sql`. Seed records are marked demo and are excluded from public catalog and stock results.
3. For a hosted project, link the intended project and apply migrations without running seed data:
   ```bash
   cd backend
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push
   ```
4. Copy `frontend/.env.example` to `frontend/.env` and set only:
   ```env
   VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
   VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY
   VITE_SITE_URL=http://localhost:5173
   ```
5. Run:
   ```bash
   cd frontend
   npm install
   npm run build
   npm run dev
   ```
6. Never put `service_role` or another privileged secret in a `VITE_` variable or frontend source. The anon/publishable key is public by design; RLS and RPC permissions are the security boundary.

## Remaining before checkout

- Connect to the owner's Supabase project and verify real catalog rows, stock view, image paths, and RLS as anon/customer/staff.
- Implement the address/checkout UI using `quote_cart` and `place_order`, stable idempotency key storage across retries, and server-derived totals.
- Test retry behavior, order ownership, and stock invariants against a real PostgreSQL/Supabase runtime.
