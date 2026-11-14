# DWLY EGY — deployment readiness update (2026-11-14)

## Supabase
- Existing project only: `xuqxkyblqjajpwlopnlt`.
- Migration `0011_boolean_only_variant_availability.sql` adds an RLS-protected boolean projection and replaces `variant_stock` with a `security_invoker=true` view.
- Public data contains `variant_id`, `product_id`, and `in_stock` only. Raw `inventory` remains inaccessible to `anon`.
- The frontend reads `in_stock` and fails closed if availability cannot be read.

## Vercel
- Vite deployment config is in `frontend/vercel.json`.
- Set Vercel Root Directory to `frontend`.
- Required environment variables: `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` (the Supabase publishable key; never use service_role in the browser).
- `npm ci --include=optional`; `npm run build`; output `dist`.

## Not yet verified
- No GitHub repository has been authorized/connected, so this source archive has not been pushed to a repository.
- No Vercel project has been authorized/connected, so no Vercel environment variables or deployment have been created.
- No real Auth customer/admin accounts were created. Current Supabase integration tools expose SQL/project management but no Auth Admin user-creation action.
- No real browser end-to-end checkout has been performed.
- Local typecheck and static contract checks pass; local production build is blocked by missing Linux Rollup optional dependency in the preloaded node_modules. The configured install command reinstalls optional dependencies in Vercel's connected build environment.
