-- pgTAP tests for RLS, grants and the order/stock/payment functions.
-- Run with:  supabase test db        (needs the local stack: supabase start)
-- STATUS: execution requires `supabase start` and `supabase test db`.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ---------- fixtures (rolled back at the end) ----------
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1','a@test.dwly', now()),
  ('00000000-0000-0000-0000-0000000000b2','b@test.dwly', now()),
  ('00000000-0000-0000-0000-0000000000c3','c@test.dwly', null),
  ('00000000-0000-0000-0000-0000000000ad','admin@test.dwly', now());
insert into public.roles (user_id, role) values ('00000000-0000-0000-0000-0000000000ad','admin');

insert into public.shipping_zones (name_ar, name_en, fee, is_available) values ('اختبار','TestZone', 50, true);
insert into public.sizes (label) values ('TST'), ('TST-L');
insert into public.colors (code, name_ar, hex) values ('test_red', 'أحمر اختبار', '#AA0000');
insert into public.products (id, slug, name_ar, base_price, status, is_demo)
  values ('11111111-1111-1111-1111-111111111111','test-product','منتج اختبار',100,'active',true);
insert into public.product_variants (id, product_id, sku, size_id)
  select '22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','TEST-SKU', id from public.sizes where label = 'TST';
update public.inventory set quantity = 2 where variant_id = '22222222-2222-2222-2222-222222222222';
insert into public.product_variants (id, product_id, sku, size_id)
  select '33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','TEST-SKU-L', id from public.sizes where label = 'TST-L';
update public.inventory set quantity = 1 where variant_id = '33333333-3333-3333-3333-333333333333';
insert into public.product_variants (id, product_id, sku, size_id, color_id)
  select '44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111','TEST-SKU-RED', sz.id, c.id
    from public.sizes sz cross join public.colors c where sz.label = 'TST' and c.code = 'test_red';
update public.inventory set quantity = 1 where variant_id = '44444444-4444-4444-4444-444444444444';
insert into public.shipping_zones (name_ar, name_en, fee, is_available) values ('اختبار 2','TestZone2', 75, true);

-- ---------- anon ----------
set local role anon;
select throws_ok($$select * from public.orders$$, '42501', null, 'anon cannot read orders');
select throws_ok($$select * from public.inventory$$, '42501', null, 'anon cannot read inventory');
select is((select count(*)::int from public.products where status <> 'active'), 0, 'anon sees only active products');
reset role;

-- ---------- customer A ----------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select is((select count(*)::int from public.profiles), 1, 'A sees only own profile');
select throws_ok($$insert into public.roles (user_id, role) values ('00000000-0000-0000-0000-0000000000a1','admin')$$, '42501', null, 'A cannot grant self a role');
select throws_ok($$update public.profiles set is_active = false$$, '42501', null, 'A cannot edit protected profile columns');
select is((select count(*)::int from public.inventory), 0, 'A cannot see inventory rows');
select throws_ok($$update public.orders set total = 0$$, '42501', null, 'A cannot update orders');
select throws_like($$select public.cart_set_item('22222222-2222-2222-2222-222222222222', 3)$$, 'INSUFFICIENT_STOCK%', 'cart refuses quantity above stock');
select lives_ok($$select public.cart_set_item('22222222-2222-2222-2222-222222222222', 2)$$, 'cart accepts valid quantity');
select is((public.quote_cart((select id from public.shipping_zones where name_en = 'TestZone'))->>'total')::numeric, 250::numeric, 'quote = 2x100 + 50 shipping, computed server-side');
select throws_like($$select public.admin_set_order_status(gen_random_uuid(), 'confirmed')$$, 'FORBIDDEN%', 'A cannot use admin RPCs');
select throws_like($$select public.record_payment_event('p','t','e','r',1,'success',true)$$, '%permission denied%', 'A cannot call the webhook function');

select lives_ok($$select public.place_order('أحمد','٠١٠١٢٣٤٥٦٧٨',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1',null,'cod',null,true,'key-12345678')$$, 'A places a COD order (Arabic digits phone accepted)');
select is((select (public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1',null,'cod',null,true,'key-12345678')->>'duplicate')::boolean), true, 'same idempotency key and same payload returns the same order');
select throws_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع مختلف',null,'cod',null,true,'key-12345678')$$,
  'P0001', 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST', 'same key with changed address is rejected');
select throws_ok($$select public.place_order('أحمد','01099999999',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1',null,'cod',null,true,'key-12345678')$$,
  'P0001', 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST', 'same key with changed phone is rejected');
select throws_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone2'),'مدينة','شارع 1',null,'cod',null,true,'key-12345678')$$,
  'P0001', 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST', 'same key with changed governorate is rejected');
select throws_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة أخرى','شارع 1',null,'cod',null,true,'key-12345678')$$,
  'P0001', 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST', 'same key with changed city is rejected');
select throws_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1','اتركه عند الباب','cod',null,true,'key-12345678')$$,
  'P0001', 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST', 'same key with changed delivery notes is rejected');
select throws_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1',null,'online',null,true,'key-12345678')$$,
  'P0001', 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST', 'same key with changed payment method is rejected');
select throws_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1',null,'cod','NOT-A-COUPON',true,'key-12345678')$$,
  'P0001', 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST', 'same key with changed discount code is rejected');
select throws_like($$select fingerprint from private.order_request_fingerprints limit 1$$, '%permission denied%', 'customer cannot read the private server fingerprint');
select is((select count(*)::int from public.orders), 1, 'exactly one order exists for A');
select is((select phone from public.orders limit 1), '01012345678', 'phone normalised to ASCII digits');
select throws_like($$select public.cart_set_item('22222222-2222-2222-2222-222222222222', 1)$$, 'INSUFFICIENT_STOCK%', 'stock is 0 after the order; cannot add more');

-- ---------- customer B / unverified C ----------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
select is((select count(*)::int from public.orders), 0, 'B cannot see As order');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated"}', true);
select throws_ok($$select public.place_order('c','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'x','y',null,'cod',null,true,'key-cccccccc')$$, 'P0001', 'EMAIL_NOT_VERIFIED', 'unverified email cannot place an order');
reset role;

-- ---------- admin ----------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000ad","role":"authenticated"}', true);
select is((select quantity from public.inventory where variant_id = '22222222-2222-2222-2222-222222222222'), 0, 'last unit leaves stock at zero');
select throws_like($$select public.admin_set_order_status((select id from public.orders limit 1), 'delivered')$$, 'INVALID_TRANSITION%', 'pending -> delivered is rejected');
select lives_ok($$select public.admin_set_order_status((select id from public.orders limit 1), 'cancelled', 'test')$$, 'admin cancels a pending order');
select is((select quantity from public.inventory where variant_id = '22222222-2222-2222-2222-222222222222'), 2, 'cancellation restocked exactly once');
select throws_like($$select public.admin_set_order_status((select id from public.orders limit 1), 'refunded')$$, 'USE_REFUND_FLOW%', 'refund status cannot bypass the refund workflow');
reset role;

-- ---------- cart mutation with the already-used key ----------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select lives_ok($$select public.cart_set_item('22222222-2222-2222-2222-222222222222', 1)$$, 'A can add a changed quantity after the previous order was cancelled');
select throws_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1',null,'cod',null,true,'key-12345678')$$,
  'P0001', 'IDEMPOTENCY_CART_MISMATCH', 'same key with changed cart quantity is rejected');
select lives_ok($$select public.cart_set_item('22222222-2222-2222-2222-222222222222', 0)$$, 'changed cart item can be removed');
select lives_ok($$select public.cart_set_item('33333333-3333-3333-3333-333333333333', 1)$$, 'A can select a different size variant');
select throws_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1',null,'cod',null,true,'key-12345678')$$,
  'P0001', 'IDEMPOTENCY_CART_MISMATCH', 'same key with changed size/variant is rejected');
select lives_ok($$select public.cart_set_item('33333333-3333-3333-3333-333333333333', 0)$$, 'different size variant can be removed');
select lives_ok($$select public.cart_set_item('44444444-4444-4444-4444-444444444444', 1)$$, 'A can select a different color variant');
select throws_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1',null,'cod',null,true,'key-12345678')$$,
  'P0001', 'IDEMPOTENCY_CART_MISMATCH', 'same key with changed color variant is rejected');
select lives_ok($$select public.cart_set_item('44444444-4444-4444-4444-444444444444', 0)$$, 'different color variant can be removed');
reset role;

-- Inject a failure after order and line-item insertion but during stock mutation.
create or replace function public.test_fail_inventory_update() returns trigger language plpgsql as $$
begin
  raise exception 'INJECTED_INVENTORY_FAILURE';
end $$;
create trigger test_fail_inventory_update before update on public.inventory
  for each row when (new.variant_id = '22222222-2222-2222-2222-222222222222')
  execute function public.test_fail_inventory_update();
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select lives_ok($$select public.cart_set_item('22222222-2222-2222-2222-222222222222', 1)$$, 'A prepares cart for rollback test');
select throws_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1',null,'cod',null,true,'key-rollback-01')$$,
  'P0001', 'INJECTED_INVENTORY_FAILURE', 'injected stock failure aborts the whole checkout');
reset role;
drop trigger test_fail_inventory_update on public.inventory;
drop function public.test_fail_inventory_update();
select is((select count(*)::int from public.orders), 1, 'failed checkout did not leave a partial order');
select is((select quantity from public.inventory where variant_id = '22222222-2222-2222-2222-222222222222'), 2, 'failed checkout did not decrement stock');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select lives_ok($$select public.place_order('أحمد','01012345678',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع 1',null,'cod',null,true,'key-after-rollback')$$,
  'checkout succeeds after injected failure is removed');

-- User B attempts to consume the remaining single unit.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true);
select lives_ok($$select public.cart_set_item('22222222-2222-2222-2222-222222222222', 1)$$, 'B adds the final unit');
select lives_ok($$select public.place_order('B','01022222222',(select id from public.shipping_zones where name_en='TestZone'),'مدينة','شارع B',null,'cod',null,true,'key-last-unit')$$,
  'B can buy the final unit exactly once');
select throws_like($$select public.cart_set_item('22222222-2222-2222-2222-222222222222', 1)$$, 'INSUFFICIENT_STOCK%', 'no buyer can add more than the remaining stock');
reset role;

-- ---------- admin ----------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000ad","role":"authenticated"}', true);
select is((select quantity from public.inventory where variant_id = '22222222-2222-2222-2222-222222222222'), 0, 'last unit leaves stock at zero');
select throws_like($$select public.admin_set_order_status((select id from public.orders limit 1), 'confirmed')$$, 'INVALID_TRANSITION%', 'a cancelled order cannot be reopened');
reset role;

select * from finish();
rollback;
