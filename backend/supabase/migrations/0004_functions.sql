-- 0004_functions.sql : helpers, triggers and the RPCs that are the ONLY way clients change orders/stock/cart.
-- Every SECURITY DEFINER function pins search_path. Client-facing RPCs read auth.uid() themselves.

-- ---------- helpers used by RLS policies ----------
create or replace function private.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.roles r where r.user_id = (select auth.uid()) and r.role in ('admin','staff'));
$$;

create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.roles r where r.user_id = (select auth.uid()) and r.role = 'admin');
$$;

create or replace function private.owns_order(p_order_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.orders o where o.id = p_order_id and o.user_id = (select auth.uid()));
$$;

-- Arabic-Indic / Persian digits -> ASCII, strips spaces, dashes, dots, brackets.
create or replace function private.normalize_phone(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(regexp_replace(
           translate(coalesce(p, ''), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789'),
           '[\s\-().]', '', 'g'), '');
$$;

create or replace function private.allowed_transition(p_from public.order_status, p_to public.order_status) returns boolean
language sql immutable set search_path = '' as $$
  select case p_from
    when 'pending'          then p_to in ('confirmed','cancelled')
    when 'confirmed'        then p_to in ('processing','cancelled')
    when 'processing'       then p_to in ('shipped','cancelled')
    when 'shipped'          then p_to in ('out_for_delivery','delivered')
    when 'out_for_delivery' then p_to in ('delivered','cancelled')
    when 'delivered'        then p_to in ('refunded')
    else false end;
$$;

-- ---------- trigger functions ----------
create or replace function private.set_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

create or replace function private.trg_normalize_phone() returns trigger
language plpgsql set search_path = '' as $$
begin new.phone := private.normalize_phone(new.phone); return new; end $$;

create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_phone text := private.normalize_phone(new.raw_user_meta_data ->> 'phone');
begin
  -- role is NEVER read from user metadata (client-controlled)
  insert into public.profiles (id, email, full_name, phone)
  values (new.id, new.email, nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
          case when v_phone ~ '^\+?[0-9]{8,15}$' then v_phone end)
  on conflict (id) do nothing;
  return new;
end $$;

create or replace function private.create_inventory_row() returns trigger
language plpgsql security definer set search_path = '' as $$
begin insert into public.inventory (variant_id) values (new.id) on conflict do nothing; return new; end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();
create trigger variant_creates_inventory after insert on public.product_variants
  for each row execute function private.create_inventory_row();

create trigger profiles_updated  before update on public.profiles  for each row execute function private.set_updated_at();
create trigger addresses_updated before update on public.addresses for each row execute function private.set_updated_at();
create trigger products_updated  before update on public.products  for each row execute function private.set_updated_at();
create trigger orders_updated    before update on public.orders    for each row execute function private.set_updated_at();
create trigger payments_updated  before update on public.payments  for each row execute function private.set_updated_at();
create trigger profiles_phone    before insert or update on public.profiles  for each row execute function private.trg_normalize_phone();
create trigger addresses_phone   before insert or update on public.addresses for each row execute function private.trg_normalize_phone();

-- ---------- cart ----------
create or replace function public.cart_set_item(p_variant_id uuid, p_quantity integer) returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_cart uuid; v_avail integer;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED' using errcode = '28000'; end if;
  if p_quantity is null or p_quantity < 0 or p_quantity > 20 then raise exception 'INVALID_QUANTITY'; end if;
  insert into public.carts (user_id) values (v_uid)
    on conflict (user_id) do update set updated_at = now() returning id into v_cart;
  if p_quantity = 0 then
    delete from public.cart_items where cart_id = v_cart and variant_id = p_variant_id;
    return;
  end if;
  select i.quantity into v_avail
    from public.product_variants v
    join public.products  p on p.id = v.product_id
    join public.inventory i on i.variant_id = v.id
   where v.id = p_variant_id and v.is_active and p.status = 'active';
  if v_avail is null then raise exception 'VARIANT_UNAVAILABLE'; end if;
  if p_quantity > v_avail then raise exception 'INSUFFICIENT_STOCK'; end if;
  insert into public.cart_items (cart_id, variant_id, quantity) values (v_cart, p_variant_id, p_quantity)
    on conflict (cart_id, variant_id) do update set quantity = excluded.quantity;
end $$;

-- ---------- server-side pricing (single source of truth for quote + order) ----------
-- Takes a uid, so it is NOT granted to clients; only other definer functions call it.
create or replace function private.price_cart(p_uid uuid, p_governorate_id smallint, p_discount_code text, p_lock boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r record; v_cart uuid; v_lines jsonb := '[]'::jsonb;
  v_subtotal numeric(10,2) := 0; v_unit numeric(10,2);
  v_zone public.shipping_zones; v_ship numeric(10,2);
  v_disc public.discount_codes; v_disc_id uuid; v_disc_code text; v_disc_amt numeric(10,2) := 0; v_used integer;
begin
  select id into v_cart from public.carts where user_id = p_uid;
  if v_cart is null or not exists (select 1 from public.cart_items where cart_id = v_cart) then
    raise exception 'CART_EMPTY';
  end if;
  if p_lock then  -- consistent lock order avoids deadlocks between concurrent checkouts
    perform 1 from public.inventory
     where variant_id in (select variant_id from public.cart_items where cart_id = v_cart)
     order by variant_id for update;
  end if;

  for r in
    select ci.variant_id, ci.quantity, v.sku, v.is_active as v_active, v.price_override,
           p.id as product_id, p.name_ar, p.base_price, p.status,
           s.label as size_label, c.name_ar as color_name, inv.quantity as stock,
           (select pi.path from public.product_images pi where pi.product_id = p.id
             order by pi.is_primary desc, pi.sort_order limit 1) as image_path
      from public.cart_items ci
      join public.product_variants v on v.id = ci.variant_id
      join public.products  p   on p.id = v.product_id
      join public.inventory inv on inv.variant_id = v.id
      left join public.sizes  s on s.id = v.size_id
      left join public.colors c on c.id = v.color_id
     where ci.cart_id = v_cart
     order by ci.variant_id
  loop
    if not r.v_active or r.status <> 'active' then raise exception 'VARIANT_UNAVAILABLE:%', r.sku; end if;
    if r.quantity > r.stock then raise exception 'INSUFFICIENT_STOCK:%', r.sku; end if;
    v_unit := coalesce(r.price_override, r.base_price);
    v_subtotal := v_subtotal + v_unit * r.quantity;
    v_lines := v_lines || jsonb_build_object(
      'variant_id', r.variant_id, 'product_id', r.product_id, 'sku', r.sku, 'name', r.name_ar,
      'size', r.size_label, 'color', r.color_name, 'unit_price', v_unit,
      'quantity', r.quantity, 'line_total', v_unit * r.quantity, 'image_path', r.image_path);
  end loop;

  select * into v_zone from public.shipping_zones where id = p_governorate_id;
  if not found or not v_zone.is_available or v_zone.fee is null then raise exception 'SHIPPING_UNAVAILABLE'; end if;
  v_ship := case when v_zone.free_shipping_threshold is not null and v_subtotal >= v_zone.free_shipping_threshold
                 then 0 else v_zone.fee end;

  if p_discount_code is not null and btrim(p_discount_code) <> '' then
    select * into v_disc from public.discount_codes
     where lower(code) = lower(btrim(p_discount_code)) and is_active
       and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now());
    if not found then raise exception 'INVALID_DISCOUNT'; end if;   -- one generic error: codes cannot be probed
    if p_lock then perform 1 from public.discount_codes where id = v_disc.id for update; end if;
    select used_count into v_used from public.discount_codes where id = v_disc.id;
    if v_disc.usage_limit is not null and v_used >= v_disc.usage_limit then raise exception 'INVALID_DISCOUNT'; end if;
    if v_subtotal < v_disc.min_order_amount then raise exception 'INVALID_DISCOUNT'; end if;
    if (select count(*) from public.discount_redemptions where discount_id = v_disc.id and user_id = p_uid) >= v_disc.per_user_limit then
      raise exception 'INVALID_DISCOUNT';
    end if;
    v_disc_amt := case when v_disc.type = 'percent' then round(v_subtotal * v_disc.value / 100, 2) else v_disc.value end;
    if v_disc.max_discount_amount is not null then v_disc_amt := least(v_disc_amt, v_disc.max_discount_amount); end if;
    v_disc_amt := least(v_disc_amt, v_subtotal);
    v_disc_id := v_disc.id; v_disc_code := v_disc.code;
  end if;

  return jsonb_build_object('lines', v_lines, 'subtotal', v_subtotal, 'shipping_fee', v_ship,
    'discount_amount', v_disc_amt, 'total', v_subtotal + v_ship - v_disc_amt,
    'discount_id', v_disc_id, 'discount_code', v_disc_code);
end $$;

create or replace function public.quote_cart(p_governorate_id smallint, p_discount_code text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode = '28000'; end if;
  return private.price_cart(auth.uid(), p_governorate_id, p_discount_code, false);
end $$;

-- ---------- place order ----------
create or replace function public.place_order(
  p_customer_name text, p_phone text, p_governorate_id smallint, p_city text, p_address_line text,
  p_delivery_notes text, p_payment_method public.payment_method, p_discount_code text,
  p_terms_accepted boolean, p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_existing public.orders; v_order public.orders; v_q jsonb; v_line jsonb;
  v_phone text; v_email text; v_verified boolean; v_active boolean; v_gov text; v_after integer; v_qty integer;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED' using errcode = '28000'; end if;
  if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 100 then raise exception 'INVALID_IDEMPOTENCY_KEY'; end if;

  select * into v_existing from public.orders where user_id = v_uid and idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('order_id', v_existing.id, 'order_number', v_existing.order_number,
      'total', v_existing.total, 'payment_method', v_existing.payment_method, 'duplicate', true);
  end if;

  select (u.email_confirmed_at is not null), u.email into v_verified, v_email from auth.users u where u.id = v_uid;
  if not coalesce(v_verified, false) then raise exception 'EMAIL_NOT_VERIFIED'; end if;
  select is_active into v_active from public.profiles where id = v_uid;
  if not coalesce(v_active, false) then raise exception 'ACCOUNT_DISABLED'; end if;
  if not coalesce(p_terms_accepted, false) then raise exception 'TERMS_NOT_ACCEPTED'; end if;
  if btrim(coalesce(p_customer_name,'')) = '' or btrim(coalesce(p_city,'')) = '' or btrim(coalesce(p_address_line,'')) = '' then
    raise exception 'INVALID_ADDRESS';
  end if;
  v_phone := private.normalize_phone(p_phone);
  if v_phone is null or v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'INVALID_PHONE'; end if;

  v_q := private.price_cart(v_uid, p_governorate_id, p_discount_code, true);
  select name_ar into v_gov from public.shipping_zones where id = p_governorate_id;

  begin
    insert into public.orders (user_id, payment_method, payment_status, customer_name, phone, email,
      governorate_id, governorate_name, city, address_line, delivery_notes,
      subtotal, shipping_fee, discount_amount, total, discount_code, terms_accepted_at, idempotency_key)
    values (v_uid, p_payment_method, case when p_payment_method = 'cod' then 'unpaid'::public.payment_status else 'pending'::public.payment_status end,
      btrim(p_customer_name), v_phone, v_email, p_governorate_id, v_gov, btrim(p_city), btrim(p_address_line), nullif(btrim(p_delivery_notes), ''),
      (v_q ->> 'subtotal')::numeric, (v_q ->> 'shipping_fee')::numeric, (v_q ->> 'discount_amount')::numeric,
      (v_q ->> 'total')::numeric, v_q ->> 'discount_code', now(), p_idempotency_key)
    returning * into v_order;
  exception when unique_violation then   -- concurrent duplicate submit
    select * into v_existing from public.orders where user_id = v_uid and idempotency_key = p_idempotency_key;
    return jsonb_build_object('order_id', v_existing.id, 'order_number', v_existing.order_number,
      'total', v_existing.total, 'payment_method', v_existing.payment_method, 'duplicate', true);
  end;

  for v_line in select value from jsonb_array_elements(v_q -> 'lines') loop
    v_qty := (v_line ->> 'quantity')::integer;
    insert into public.order_items (order_id, variant_id, product_id, product_name, sku, size_label, color_name,
                                    unit_price, quantity, line_total, image_path)
    values (v_order.id, (v_line ->> 'variant_id')::uuid, (v_line ->> 'product_id')::uuid, v_line ->> 'name', v_line ->> 'sku',
            v_line ->> 'size', v_line ->> 'color', (v_line ->> 'unit_price')::numeric, v_qty,
            (v_line ->> 'line_total')::numeric, v_line ->> 'image_path');
    update public.inventory set quantity = quantity - v_qty, updated_at = now()
     where variant_id = (v_line ->> 'variant_id')::uuid returning quantity into v_after;   -- CHECK (quantity >= 0) is the last guard
    insert into public.inventory_movements (variant_id, delta, quantity_after, reason, order_id, created_by)
    values ((v_line ->> 'variant_id')::uuid, -v_qty, v_after, 'sale', v_order.id, v_uid);
  end loop;

  if v_q ->> 'discount_id' is not null then
    insert into public.discount_redemptions (discount_id, user_id, order_id, amount)
    values ((v_q ->> 'discount_id')::uuid, v_uid, v_order.id, (v_q ->> 'discount_amount')::numeric);
    update public.discount_codes set used_count = used_count + 1 where id = (v_q ->> 'discount_id')::uuid;
  end if;

  insert into public.order_status_history (order_id, from_status, to_status, note, changed_by)
  values (v_order.id, null, 'pending', 'order placed', v_uid);
  insert into public.payments (order_id, method, status, amount)
  values (v_order.id, p_payment_method, v_order.payment_status, v_order.total);
  delete from public.cart_items where cart_id in (select id from public.carts where user_id = v_uid);

  return jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number,
    'total', v_order.total, 'payment_method', v_order.payment_method, 'duplicate', false);
end $$;

-- ---------- cancel / restock ----------
create or replace function private.restock_order(p_order_id uuid, p_reason public.movement_reason, p_actor uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; v_after integer; v_done boolean;
begin
  select stock_restored into v_done from public.orders where id = p_order_id for update;
  if v_done then return; end if;                      -- never restock twice
  for r in select variant_id, quantity from public.order_items where order_id = p_order_id order by variant_id loop
    update public.inventory set quantity = quantity + r.quantity, updated_at = now()
     where variant_id = r.variant_id returning quantity into v_after;
    insert into public.inventory_movements (variant_id, delta, quantity_after, reason, order_id, created_by)
    values (r.variant_id, r.quantity, v_after, p_reason, p_order_id, p_actor);
  end loop;
  update public.orders set stock_restored = true where id = p_order_id;
  with d as (delete from public.discount_redemptions where order_id = p_order_id returning discount_id)
  update public.discount_codes c set used_count = greatest(c.used_count - 1, 0) from d where c.id = d.discount_id;
end $$;

create or replace function public.customer_cancel_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_o public.orders; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED' using errcode = '28000'; end if;
  select * into v_o from public.orders where id = p_order_id and user_id = v_uid for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_o.status <> 'pending' or v_o.payment_status = 'paid' then raise exception 'CANCEL_NOT_ALLOWED'; end if;
  update public.orders set status = 'cancelled' where id = p_order_id;
  update public.payments set status = 'failed' where order_id = p_order_id and status = 'pending';
  insert into public.order_status_history (order_id, from_status, to_status, note, changed_by)
  values (p_order_id, v_o.status, 'cancelled', 'cancelled by customer', v_uid);
  perform private.restock_order(p_order_id, 'cancellation', v_uid);
end $$;

-- ---------- staff / admin operations ----------
create or replace function public.admin_set_order_status(p_order_id uuid, p_status public.order_status, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_o public.orders;
begin
  if not private.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_o from public.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if not private.allowed_transition(v_o.status, p_status) then
    raise exception 'INVALID_TRANSITION:% -> %', v_o.status, p_status;
  end if;
  update public.orders set status = p_status where id = p_order_id;
  insert into public.order_status_history (order_id, from_status, to_status, note, changed_by)
  values (p_order_id, v_o.status, p_status, p_note, auth.uid());
  if p_status = 'cancelled' then perform private.restock_order(p_order_id, 'cancellation', auth.uid()); end if;
  if p_status = 'delivered' then
    update public.products pr set sales_count = pr.sales_count + s.q
      from (select product_id, sum(quantity)::integer as q from public.order_items where order_id = p_order_id group by product_id) s
     where pr.id = s.product_id;
  end if;
end $$;

create or replace function public.admin_set_payment_status(p_order_id uuid, p_status public.payment_status) returns void
language plpgsql security definer set search_path = '' as $$
declare v_o public.orders;
begin
  if not private.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_o from public.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_o.payment_method = 'online' and p_status in ('paid','failed') then
    raise exception 'ONLINE_PAYMENT_MANAGED_BY_PROVIDER';     -- only the verified webhook can mark these
  end if;
  update public.orders set payment_status = p_status where id = p_order_id;
  update public.payments set status = p_status where order_id = p_order_id;
end $$;

create or replace function public.admin_adjust_inventory(p_variant_id uuid, p_delta integer, p_reason public.movement_reason, p_note text default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_q integer;
begin
  if not private.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_delta is null or p_delta = 0 then raise exception 'INVALID_DELTA'; end if;
  if p_reason in ('sale','cancellation') then raise exception 'REASON_RESERVED_FOR_ORDERS'; end if;
  select quantity into v_q from public.inventory where variant_id = p_variant_id for update;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  if v_q + p_delta < 0 then raise exception 'NEGATIVE_STOCK'; end if;
  update public.inventory set quantity = v_q + p_delta, updated_at = now() where variant_id = p_variant_id;
  insert into public.inventory_movements (variant_id, delta, quantity_after, reason, note, created_by)
  values (p_variant_id, p_delta, v_q + p_delta, p_reason, p_note, auth.uid());
  return v_q + p_delta;
end $$;

create or replace function public.admin_set_account_status(p_user_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.profiles set is_active = p_active where id = p_user_id;
end $$;

create or replace function public.admin_dashboard_stats(p_from timestamptz default now() - interval '30 days', p_to timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if not private.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select jsonb_build_object(
    'total_sales',    coalesce(sum(total) filter (where status not in ('cancelled','refunded')), 0),
    'total_orders',   count(*),
    'pending_orders', count(*) filter (where status = 'pending'),
    'completed_orders', count(*) filter (where status = 'delivered'),
    'by_status', coalesce((select jsonb_object_agg(s, c) from (select status::text as s, count(*) as c from public.orders where created_at between p_from and p_to group by status) x), '{}'::jsonb),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'orders', n, 'sales', t) order by d)
                from (select (created_at at time zone 'Africa/Cairo')::date as d, count(*) as n,
                             sum(total) filter (where status not in ('cancelled','refunded')) as t
                        from public.orders where created_at between p_from and p_to group by 1) y), '[]'::jsonb),
    'low_stock_variants', (select count(*) from public.inventory where quantity <= low_stock_threshold)
  ) into v from public.orders where created_at between p_from and p_to;
  return v;
end $$;

-- ---------- payment provider events (service role / edge function only) ----------
create or replace function public.record_payment_event(
  p_provider text, p_provider_txn_id text, p_event_type text, p_provider_order_ref text,
  p_amount numeric, p_status text, p_signature_verified boolean, p_raw jsonb default '{}'::jsonb
) returns text language plpgsql security definer set search_path = '' as $$
declare v_pay public.payments; v_tx uuid; v_o public.orders;
begin
  if not coalesce(p_signature_verified, false) then raise exception 'SIGNATURE_NOT_VERIFIED'; end if;
  if p_status not in ('success','failed','refunded') then raise exception 'INVALID_STATUS'; end if;
  select * into v_pay from public.payments where provider = p_provider and provider_order_ref = p_provider_order_ref for update;
  if not found then raise exception 'PAYMENT_NOT_FOUND'; end if;

  insert into public.payment_transactions (payment_id, provider, provider_txn_id, event_type, amount, status, signature_verified, raw_payload)
  values (v_pay.id, p_provider, p_provider_txn_id, p_event_type, p_amount, p_status, true, coalesce(p_raw, '{}'::jsonb))
  on conflict (provider, provider_txn_id, event_type) do nothing returning id into v_tx;
  if v_tx is null then return 'duplicate'; end if;     -- already processed: safe to ACK the webhook again

  select * into v_o from public.orders where id = v_pay.order_id for update;
  if p_status = 'success' then
    if p_amount is distinct from v_pay.amount then raise exception 'AMOUNT_MISMATCH'; end if;   -- rolls back, nothing is marked paid
    update public.payments set status = 'paid' where id = v_pay.id;
    update public.orders set payment_status = 'paid' where id = v_o.id;
    if v_o.status = 'pending' then
      update public.orders set status = 'confirmed' where id = v_o.id;
      insert into public.order_status_history (order_id, from_status, to_status, note)
      values (v_o.id, 'pending', 'confirmed', 'online payment confirmed');
    end if;   -- a paid-but-cancelled order stays visible to staff as "cancelled + paid" => refund needed
  elsif p_status = 'failed' then
    update public.payments set status = 'failed' where id = v_pay.id and status <> 'paid';
    update public.orders set payment_status = 'failed' where id = v_o.id and payment_status <> 'paid';
  else
    update public.payments set status = 'refunded' where id = v_pay.id;
    update public.orders set payment_status = 'refunded' where id = v_o.id;
  end if;
  return 'processed';
end $$;
