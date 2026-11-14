-- 0008_commerce_hardening.sql
-- Merge the safe supplemental 0004_functions.sql fixes without rewriting history.

create or replace function private.price_cart(
  p_uid uuid, p_governorate_id smallint, p_discount_code text, p_lock boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_cart uuid;
  v_lines jsonb := '[]'::jsonb;
  v_subtotal numeric(10,2) := 0;
  v_unit numeric(10,2);
  v_zone public.shipping_zones;
  v_ship numeric(10,2);
  v_disc public.discount_codes;
  v_disc_id uuid;
  v_disc_code text;
  v_disc_amt numeric(10,2) := 0;
begin
  select id into v_cart from public.carts where user_id = p_uid;
  if v_cart is null or not exists (select 1 from public.cart_items where cart_id = v_cart) then
    raise exception 'CART_EMPTY';
  end if;

  if p_lock then
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
      join public.products p on p.id = v.product_id
      join public.inventory inv on inv.variant_id = v.id
      left join public.sizes s on s.id = v.size_id
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
    select id into v_disc_id from public.discount_codes where lower(code) = lower(btrim(p_discount_code));
    if v_disc_id is null then raise exception 'INVALID_DISCOUNT'; end if;

    -- Lock first, then validate the locked row. This avoids stale usage_limit/active/date reads.
    if p_lock then
      select * into v_disc from public.discount_codes where id = v_disc_id for update;
    else
      select * into v_disc from public.discount_codes where id = v_disc_id;
    end if;
    if not found or lower(v_disc.code) <> lower(btrim(p_discount_code))
       or not v_disc.is_active
       or (v_disc.starts_at is not null and v_disc.starts_at > now())
       or (v_disc.ends_at is not null and v_disc.ends_at <= now()) then
      raise exception 'INVALID_DISCOUNT';
    end if;
    if v_disc.usage_limit is not null and v_disc.used_count >= v_disc.usage_limit then raise exception 'INVALID_DISCOUNT'; end if;
    if v_subtotal < v_disc.min_order_amount then raise exception 'INVALID_DISCOUNT'; end if;
    if (select count(*) from public.discount_redemptions where discount_id = v_disc.id and user_id = p_uid) >= v_disc.per_user_limit then
      raise exception 'INVALID_DISCOUNT';
    end if;
    v_disc_amt := case when v_disc.type = 'percent' then round(v_subtotal * v_disc.value / 100, 2) else v_disc.value end;
    if v_disc.max_discount_amount is not null then v_disc_amt := least(v_disc_amt, v_disc.max_discount_amount); end if;
    v_disc_amt := least(v_disc_amt, v_subtotal);
    v_disc_id := v_disc.id;
    v_disc_code := v_disc.code;
  end if;

  return jsonb_build_object('lines', v_lines, 'subtotal', v_subtotal, 'shipping_fee', v_ship,
    'discount_amount', v_disc_amt, 'total', v_subtotal + v_ship - v_disc_amt,
    'discount_id', v_disc_id, 'discount_code', v_disc_code);
end $$;

create or replace function private.allowed_transition(
  p_from public.order_status, p_to public.order_status
) returns boolean language sql immutable set search_path = '' as $$
  select case p_from
    when 'pending'          then p_to in ('confirmed','cancelled')
    when 'confirmed'        then p_to in ('processing','cancelled')
    when 'processing'       then p_to in ('shipped','cancelled')
    when 'shipped'          then p_to in ('out_for_delivery','delivered')
    when 'out_for_delivery' then p_to in ('delivered','cancelled')
    else false end;
$$;

create or replace function public.admin_set_order_status(
  p_order_id uuid, p_status public.order_status, p_note text default null
) returns void language plpgsql security definer set search_path = '' as $$
declare v_o public.orders;
begin
  if not private.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_status = 'refunded' then raise exception 'USE_REFUND_FLOW'; end if;
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

create or replace function public.admin_set_payment_status(
  p_order_id uuid, p_status public.payment_status
) returns void language plpgsql security definer set search_path = '' as $$
declare v_o public.orders;
begin
  if not private.is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_status in ('refunded','partially_refunded') then raise exception 'USE_REFUND_FLOW'; end if;
  select * into v_o from public.orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_o.payment_method = 'online' and p_status in ('paid','failed') then
    raise exception 'ONLINE_PAYMENT_MANAGED_BY_PROVIDER';
  end if;
  update public.orders set payment_status = p_status where id = p_order_id;
  update public.payments set status = p_status where order_id = p_order_id;
end $$;

create or replace function public.record_payment_event(
  p_provider text, p_provider_txn_id text, p_event_type text, p_provider_order_ref text,
  p_amount numeric, p_status text, p_signature_verified boolean, p_raw jsonb default '{}'::jsonb
) returns text language plpgsql security definer set search_path = '' as $$
declare v_pay public.payments; v_tx uuid; v_o public.orders;
begin
  if not coalesce(p_signature_verified, false) then raise exception 'SIGNATURE_NOT_VERIFIED'; end if;
  if p_status not in ('success','failed') then raise exception 'INVALID_STATUS'; end if;
  select * into v_pay from public.payments
   where provider = p_provider and provider_order_ref = p_provider_order_ref for update;
  if not found then raise exception 'PAYMENT_NOT_FOUND'; end if;

  insert into public.payment_transactions (payment_id, provider, provider_txn_id, event_type, amount, status, signature_verified, raw_payload)
  values (v_pay.id, p_provider, p_provider_txn_id, p_event_type, p_amount, p_status, true, coalesce(p_raw, '{}'::jsonb))
  on conflict (provider, provider_txn_id, event_type) do nothing returning id into v_tx;
  if v_tx is null then return 'duplicate'; end if;

  select * into v_o from public.orders where id = v_pay.order_id for update;
  if p_status = 'success' then
    -- A late success cannot overwrite a settled or refunded payment state.
    if v_pay.status in ('paid','refunded','partially_refunded') then return 'ignored_already_settled'; end if;
    if p_amount is distinct from v_pay.amount then raise exception 'AMOUNT_MISMATCH'; end if;
    update public.payments set status = 'paid' where id = v_pay.id;
    update public.orders set payment_status = 'paid' where id = v_o.id;
    if v_o.status = 'pending' then
      update public.orders set status = 'confirmed' where id = v_o.id;
      insert into public.order_status_history (order_id, from_status, to_status, note)
      values (v_o.id, 'pending', 'confirmed', 'online payment confirmed');
    end if;
  else
    -- Late failure notifications must never downgrade a paid/refunded payment.
    update public.payments set status = 'failed' where id = v_pay.id and status in ('pending','unpaid','failed');
    update public.orders set payment_status = 'failed' where id = v_o.id and payment_status in ('pending','unpaid','failed');
  end if;
  return 'processed';
end $$;

-- Reassert least privilege for newly created/replaced RPCs and private helpers.
revoke execute on function private.price_cart(uuid, smallint, text, boolean) from public, anon, authenticated;
revoke execute on function public.admin_set_order_status(uuid, public.order_status, text) from public, anon;
revoke execute on function public.admin_set_payment_status(uuid, public.payment_status) from public, anon;
revoke execute on function public.record_payment_event(text, text, text, text, numeric, text, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_order_status(uuid, public.order_status, text) to authenticated;
grant execute on function public.admin_set_payment_status(uuid, public.payment_status) to authenticated;
grant execute on function public.record_payment_event(text, text, text, text, numeric, text, boolean, jsonb) to service_role;
