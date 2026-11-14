-- seed.sql : LOCAL / STAGING ONLY. Runs on `supabase db reset`. Do NOT run on production.
-- Everything marked is_demo = true (and every SKU starting with DEMO-) is fake sample data.
-- Remove it all with supabase/purge_demo.sql before importing real products.
-- Stock quantities below are demo numbers, not real inventory. No product photos are seeded.

-- starter reference data (editable from the admin dashboard)
insert into public.sizes (label, sort_order) values ('S',1),('M',2),('L',3),('XL',4),('XXL',5)
on conflict (label) do nothing;

insert into public.colors (code, name_ar, name_en, hex) values
  ('black','أسود','Black','#111111'),
  ('white','أبيض','White','#FFFFFF'),
  ('gray','رمادي','Gray','#9A9A9A'),
  ('lime','ليموني','Lime','#C8FF00')
on conflict (code) do nothing;

insert into public.categories (slug, name_ar, name_en, sort_order, is_demo) values
  ('hoodies','هوديز وسويتشيرت','Hoodies & Sweatshirts',1,true),
  ('tees','تيشيرتات','T-Shirts',2,true),
  ('pants','بناطيل','Pants',3,true),
  ('jackets','جاكيتات','Jackets',4,true),
  ('dresses','فساتين','Dresses',5,true),
  ('tops','بلوزات','Tops',6,true),
  ('skirts','تنانير','Skirts',7,true),
  ('knitwear','كنزات','Knitwear',8,true)
on conflict (slug) do nothing;

insert into public.products (slug, name_ar, name_en, category_id, gender, base_price, compare_at_price, status, is_featured, is_demo)
select v.slug, v.name_ar, v.name_en, c.id, v.gender::public.product_gender, v.price, v.old_price,
       'active'::public.product_status, v.featured, true
from (values
  ('demo-oversized-hoodie','[تجريبي] هودي أوفرسايز','[Demo] Oversized hoodie','hoodies','men',650::numeric,null::numeric,true),
  ('demo-cotton-tee','[تجريبي] تيشيرت قطن','[Demo] Cotton tee','tees','men',280,350,false),
  ('demo-wide-jeans','[تجريبي] جينز واسع','[Demo] Wide jeans','pants','men',720,null,false),
  ('demo-bomber-jacket','[تجريبي] جاكيت بومبر','[Demo] Bomber jacket','jackets','men',980,null,true),
  ('demo-summer-dress','[تجريبي] فستان صيفي','[Demo] Summer dress','dresses','women',540,null,true),
  ('demo-crop-top','[تجريبي] بلوزة كروب','[Demo] Crop top','tops','women',260,320,false),
  ('demo-pleated-skirt','[تجريبي] تنورة بليسيه','[Demo] Pleated skirt','skirts','women',430,null,false),
  ('demo-knit-cardigan','[تجريبي] كارديجان صوف','[Demo] Knit cardigan','knitwear','women',590,null,false)
) as v(slug, name_ar, name_en, cat, gender, price, old_price, featured)
join public.categories c on c.slug = v.cat
on conflict (slug) do nothing;

insert into public.product_variants (product_id, sku, size_id, color_id)
select p.id, 'DEMO-' || upper(replace(p.slug, 'demo-', '')) || '-' || s.label || '-' || upper(c.code), s.id, c.id
from public.products p
cross join public.sizes s
cross join public.colors c
where p.is_demo and s.label in ('S','M','L','XL') and c.code in ('black','white')
on conflict do nothing;

update public.inventory i set quantity = case when s.label = 'XL' then 0 else 10 end   -- XL = out of stock, to exercise the UI
  from public.product_variants v
  join public.sizes s on s.id = v.size_id
  join public.products p on p.id = v.product_id
 where i.variant_id = v.id and p.is_demo;

insert into public.inventory_movements (variant_id, delta, quantity_after, reason, note)
select i.variant_id, i.quantity, i.quantity, 'initial'::public.movement_reason, 'demo seed'
  from public.inventory i
  join public.product_variants v on v.id = i.variant_id
  join public.products p on p.id = v.product_id
 where p.is_demo and i.quantity > 0;

insert into public.discount_codes (code, type, value, min_order_amount, is_demo)
values ('DEMO10', 'percent', 10, 0, true)
on conflict do nothing;
