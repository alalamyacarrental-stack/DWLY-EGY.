-- 0005_security.sql : Row Level Security, least-privilege grants, storage.
-- Model: everything is denied unless a policy AND a grant allow it.
--   customer = any signed-in user without a row in public.roles
--   staff    = roles.role in (admin, staff): catalog, inventory, orders, banners, collections
--   admin    = roles.role = admin: + settings, shipping zones, discount codes, customer status

-- ---------- 1) RLS on every table ----------
alter table public.roles                  enable row level security;
alter table public.profiles               enable row level security;
alter table public.shipping_zones         enable row level security;
alter table public.addresses              enable row level security;
alter table public.categories             enable row level security;
alter table public.colors                 enable row level security;
alter table public.sizes                  enable row level security;
alter table public.products               enable row level security;
alter table public.product_images         enable row level security;
alter table public.product_variants       enable row level security;
alter table public.inventory              enable row level security;
alter table public.inventory_movements    enable row level security;
alter table public.collections            enable row level security;
alter table public.collection_products    enable row level security;
alter table public.banners                enable row level security;
alter table public.carts                  enable row level security;
alter table public.cart_items             enable row level security;
alter table public.discount_codes         enable row level security;
alter table public.orders                 enable row level security;
alter table public.order_items            enable row level security;
alter table public.order_status_history   enable row level security;
alter table public.discount_redemptions   enable row level security;
alter table public.payments               enable row level security;
alter table public.payment_transactions   enable row level security;
alter table public.reviews                enable row level security;
alter table public.store_settings         enable row level security;
alter table public.newsletter_subscribers enable row level security;

-- ---------- 2) reset default grants, then grant the minimum ----------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public  from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
alter default privileges in schema public  revoke all on tables    from anon, authenticated;
alter default privileges in schema public  revoke all on sequences from anon, authenticated;
alter default privileges in schema public  revoke execute on functions from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated;

-- helpers that policies / triggers call (run as the invoking role)
grant execute on function private.is_staff()                                   to anon, authenticated;
grant execute on function private.is_admin()                                   to anon, authenticated;
grant execute on function private.owns_order(uuid)                             to anon, authenticated;
grant execute on function private.normalize_phone(text)                        to anon, authenticated;
grant execute on function private.allowed_transition(public.order_status, public.order_status) to authenticated;

-- public reads (rows still filtered by policies below)
grant select on public.shipping_zones, public.categories, public.colors, public.sizes, public.products,
                public.product_images, public.product_variants, public.collections, public.collection_products,
                public.banners, public.store_settings, public.reviews, public.variant_stock
  to anon, authenticated;
grant insert on public.newsletter_subscribers to anon, authenticated;

-- signed-in reads
grant select on public.roles, public.profiles, public.addresses, public.carts, public.cart_items, public.orders,
                public.order_items, public.order_status_history, public.payments, public.payment_transactions,
                public.discount_codes, public.discount_redemptions, public.inventory, public.inventory_movements,
                public.newsletter_subscribers
  to authenticated;

-- signed-in writes (each one is further restricted by RLS)
grant insert, update, delete on public.addresses to authenticated;
grant delete on public.cart_items to authenticated;                       -- cart writes go through cart_set_item()
grant update (full_name, phone) on public.profiles to authenticated;      -- is_active / email can never be self-edited
grant insert on public.reviews to authenticated;
grant update (rating, title, body, status) on public.reviews to authenticated;
grant delete on public.reviews to authenticated;
grant insert, update, delete on public.categories, public.colors, public.sizes, public.products, public.product_images,
                                public.product_variants, public.collections, public.collection_products, public.banners
  to authenticated;                                                       -- staff only, enforced by policies
grant update on public.shipping_zones to authenticated;                   -- admin only
grant insert, update, delete on public.store_settings, public.discount_codes to authenticated;  -- admin only
grant delete on public.newsletter_subscribers to authenticated;           -- admin only
-- orders, order_items, order_status_history, payments, inventory*, payment_transactions: NO client writes at all.

-- RPC surface
grant execute on function public.cart_set_item(uuid, integer)                           to authenticated;
grant execute on function public.quote_cart(smallint, text)                              to authenticated;
grant execute on function public.place_order(text, text, smallint, text, text, text, public.payment_method, text, boolean, text) to authenticated;
grant execute on function public.customer_cancel_order(uuid)                             to authenticated;
grant execute on function public.admin_set_order_status(uuid, public.order_status, text) to authenticated;
grant execute on function public.admin_set_payment_status(uuid, public.payment_status)   to authenticated;
grant execute on function public.admin_adjust_inventory(uuid, integer, public.movement_reason, text) to authenticated;
grant execute on function public.admin_set_account_status(uuid, boolean)                 to authenticated;
grant execute on function public.admin_dashboard_stats(timestamptz, timestamptz)         to authenticated;
-- webhook processing: service role only (called by the edge function after signature verification)
grant execute on function public.record_payment_event(text, text, text, text, numeric, text, boolean, jsonb) to service_role;

-- ---------- 3) policies ----------
-- identity
create policy roles_select on public.roles for select to authenticated
  using (user_id = (select auth.uid()) or private.is_admin());
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or private.is_staff());
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy addresses_own on public.addresses for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- reference data
create policy shipping_zones_read  on public.shipping_zones for select to anon, authenticated using (true);
create policy shipping_zones_admin on public.shipping_zones for update to authenticated
  using (private.is_admin()) with check (private.is_admin());
create policy colors_read  on public.colors for select to anon, authenticated using (true);
create policy colors_write on public.colors for all to authenticated using (private.is_staff()) with check (private.is_staff());
create policy sizes_read   on public.sizes  for select to anon, authenticated using (true);
create policy sizes_write  on public.sizes  for all to authenticated using (private.is_staff()) with check (private.is_staff());

-- catalog
create policy categories_read  on public.categories for select to anon, authenticated using (is_active or private.is_staff());
create policy categories_write on public.categories for all to authenticated using (private.is_staff()) with check (private.is_staff());
create policy products_read    on public.products for select to anon, authenticated using (status = 'active' or private.is_staff());
create policy products_write   on public.products for all to authenticated using (private.is_staff()) with check (private.is_staff());
create policy product_images_read on public.product_images for select to anon, authenticated
  using (exists (select 1 from public.products p where p.id = product_id and p.status = 'active') or private.is_staff());
create policy product_images_write on public.product_images for all to authenticated using (private.is_staff()) with check (private.is_staff());
create policy variants_read on public.product_variants for select to anon, authenticated
  using ((is_active and exists (select 1 from public.products p where p.id = product_id and p.status = 'active')) or private.is_staff());
create policy variants_write on public.product_variants for all to authenticated using (private.is_staff()) with check (private.is_staff());

-- inventory: staff read only; changes only through admin_adjust_inventory / order functions
create policy inventory_staff_read on public.inventory           for select to authenticated using (private.is_staff());
create policy movements_staff_read on public.inventory_movements for select to authenticated using (private.is_staff());

-- marketing content
create policy collections_read  on public.collections for select to anon, authenticated using (is_active or private.is_staff());
create policy collections_write on public.collections for all to authenticated using (private.is_staff()) with check (private.is_staff());
create policy collection_products_read on public.collection_products for select to anon, authenticated
  using (exists (select 1 from public.collections c where c.id = collection_id and c.is_active) or private.is_staff());
create policy collection_products_write on public.collection_products for all to authenticated using (private.is_staff()) with check (private.is_staff());
create policy banners_read on public.banners for select to anon, authenticated
  using ((is_active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now())) or private.is_staff());
create policy banners_write on public.banners for all to authenticated using (private.is_staff()) with check (private.is_staff());

-- cart (read/delete own; writes via cart_set_item)
create policy carts_own on public.carts for select to authenticated using (user_id = (select auth.uid()));
create policy cart_items_select on public.cart_items for select to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid())));
create policy cart_items_delete on public.cart_items for delete to authenticated
  using (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid())));

-- orders & payments: read own or staff; no direct client writes
create policy orders_select on public.orders for select to authenticated
  using (user_id = (select auth.uid()) or private.is_staff());
create policy order_items_select on public.order_items for select to authenticated
  using (private.owns_order(order_id) or private.is_staff());
create policy order_history_select on public.order_status_history for select to authenticated
  using (private.owns_order(order_id) or private.is_staff());
create policy payments_select on public.payments for select to authenticated
  using (private.owns_order(order_id) or private.is_staff());
create policy payment_tx_staff_read on public.payment_transactions for select to authenticated using (private.is_staff());

-- marketing / settings (admin)
create policy discount_codes_admin on public.discount_codes for all to authenticated
  using (private.is_admin()) with check (private.is_admin());
create policy redemptions_staff_read on public.discount_redemptions for select to authenticated using (private.is_staff());
create policy settings_read on public.store_settings for select to anon, authenticated using (is_public or private.is_admin());
create policy settings_write on public.store_settings for all to authenticated
  using (private.is_admin()) with check (private.is_admin());

-- reviews: only verified buyers (delivered order) can write; they start as 'pending'
create policy reviews_read on public.reviews for select to anon, authenticated
  using (status = 'approved' or user_id = (select auth.uid()) or private.is_staff());
create policy reviews_insert_verified on public.reviews for insert to authenticated
  with check (
    user_id = (select auth.uid()) and status = 'pending'
    and exists (select 1 from public.order_items oi join public.orders o on o.id = oi.order_id
                 where oi.id = order_item_id and oi.product_id = reviews.product_id
                   and o.user_id = (select auth.uid()) and o.status = 'delivered')
  );
create policy reviews_update_own on public.reviews for update to authenticated
  using (user_id = (select auth.uid()) and status = 'pending')
  with check (user_id = (select auth.uid()) and status = 'pending');
create policy reviews_moderate on public.reviews for update to authenticated
  using (private.is_staff()) with check (private.is_staff());
create policy reviews_delete on public.reviews for delete to authenticated
  using (user_id = (select auth.uid()) or private.is_staff());

-- newsletter: anyone may subscribe (format is enforced by a CHECK); only admin reads/deletes.
-- Add CAPTCHA / rate limiting at the edge before launch (see docs).
create policy newsletter_subscribe on public.newsletter_subscribers for insert to anon, authenticated with check (true);
create policy newsletter_admin_read on public.newsletter_subscribers for select to authenticated using (private.is_admin());
create policy newsletter_admin_delete on public.newsletter_subscribers for delete to authenticated using (private.is_admin());

-- ---------- 4) storage: public read, staff-only write ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 5242880, array['image/jpeg','image/png','image/webp','image/avif'])
on conflict (id) do nothing;

create policy product_images_storage_read on storage.objects for select to anon, authenticated
  using (bucket_id = 'product-images');
create policy product_images_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and private.is_staff());
create policy product_images_storage_update on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and private.is_staff()) with check (bucket_id = 'product-images' and private.is_staff());
create policy product_images_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and private.is_staff());
