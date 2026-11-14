-- 0010_public_catalog_hardening.sql
-- Keep demo merchandise out of the public availability view.
-- Preserve the existing safe projection: capped availability + boolean only,
-- never exact inventory quantities or inventory movement history.
create or replace view public.variant_stock
with (security_invoker = false) as
  select v.id as variant_id,
         v.product_id,
         least(i.quantity, 10) as available,
         (i.quantity > 0) as in_stock
    from public.product_variants v
    join public.products p
      on p.id = v.product_id
     and p.status = 'active'
     and p.is_demo = false
    join public.inventory i on i.variant_id = v.id
   where v.is_active = true;

comment on view public.variant_stock is
  'Public-safe stock projection for active non-demo catalog variants; exposes capped availability and in_stock only.';

-- The view remains readable through the grants established in migration 0005.
-- No direct client access is granted to public.inventory by this migration.

-- Hide sample/demo rows at the database boundary as well as in the storefront.
-- Staff retains access for QA and catalog maintenance.
drop policy if exists categories_read on public.categories;
create policy categories_read on public.categories for select to anon, authenticated
  using ((is_active and not is_demo) or private.is_staff());

drop policy if exists products_read on public.products;
create policy products_read on public.products for select to anon, authenticated
  using ((status = 'active' and not is_demo) or private.is_staff());

drop policy if exists product_images_read on public.product_images;
create policy product_images_read on public.product_images for select to anon, authenticated
  using (
    exists (
      select 1 from public.products p
       where p.id = product_id and p.status = 'active' and not p.is_demo
    ) or private.is_staff()
  );

drop policy if exists variants_read on public.product_variants;
create policy variants_read on public.product_variants for select to anon, authenticated
  using (
    (is_active and exists (
      select 1 from public.products p
       where p.id = product_id and p.status = 'active' and not p.is_demo
    )) or private.is_staff()
  );

drop policy if exists collections_read on public.collections;
create policy collections_read on public.collections for select to anon, authenticated
  using ((is_active and not is_demo) or private.is_staff());

drop policy if exists collection_products_read on public.collection_products;
create policy collection_products_read on public.collection_products for select to anon, authenticated
  using (
    exists (
      select 1 from public.collections c
       where c.id = collection_id and c.is_active and not c.is_demo
    ) or private.is_staff()
  );

drop policy if exists banners_read on public.banners;
create policy banners_read on public.banners for select to anon, authenticated
  using (
    (is_active and not is_demo
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at > now()))
    or private.is_staff()
  );
