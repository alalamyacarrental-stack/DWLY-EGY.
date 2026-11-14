-- purge_demo.sql : removes ALL demo data. Run once before adding real products.
-- Safe: order_items.variant_id is ON DELETE RESTRICT, so this fails loudly if a demo product was ever ordered.
begin;
delete from public.discount_codes where is_demo;
delete from public.banners        where is_demo;
delete from public.collections    where is_demo;   -- cascades collection_products
delete from public.products       where is_demo;   -- cascades variants, inventory, images, movements
delete from public.categories     where is_demo;
commit;
