-- 0007_order_idempotency.sql
-- Server-derived SHA-256 request fingerprint and serialized checkout execution.
-- Existing migrations are intentionally immutable; this migration adds a private
-- fingerprint table and replaces only the place_order RPC.

create extension if not exists pgcrypto with schema extensions;
do $$
declare v_extension_schema text;
begin
  select n.nspname into v_extension_schema
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';
  if v_extension_schema is distinct from 'extensions' then
    execute 'alter extension pgcrypto set schema extensions';
  end if;
end $$;

-- Keep the digest outside public.orders: the client may read its own order rows,
-- but must not be able to read or submit the server fingerprint.
create table private.order_request_fingerprints (
  order_id uuid primary key references public.orders(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key text not null,
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  unique (user_id, idempotency_key)
);
revoke all on table private.order_request_fingerprints from public, anon, authenticated;

create or replace function private.make_order_fingerprint(
  p_user_id uuid,
  p_idempotency_key text,
  p_customer_name text,
  p_phone text,
  p_email text,
  p_governorate_id smallint,
  p_governorate_name text,
  p_city text,
  p_address_line text,
  p_delivery_notes text,
  p_payment_method public.payment_method,
  p_discount_code text,
  p_subtotal numeric,
  p_shipping_fee numeric,
  p_discount_amount numeric,
  p_total numeric,
  p_currency char(3),
  p_terms_accepted boolean,
  p_lines jsonb
) returns text
language sql immutable set search_path = '' as $$
  select encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'version', 1,
          'user_id', p_user_id,
          'idempotency_key', p_idempotency_key,
          'customer_name', p_customer_name,
          'phone', p_phone,
          'email', p_email,
          'governorate_id', p_governorate_id,
          'governorate_name', p_governorate_name,
          'city', p_city,
          'address_line', p_address_line,
          'delivery_notes', p_delivery_notes,
          'payment_method', p_payment_method,
          'discount_code', upper(nullif(btrim(p_discount_code), '')),
          'subtotal', p_subtotal,
          'shipping_fee', p_shipping_fee,
          'discount_amount', p_discount_amount,
          'total', p_total,
          'currency', p_currency,
          'terms_accepted', p_terms_accepted,
          'lines', coalesce(p_lines, '[]'::jsonb)
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

-- Backfill historical orders from immutable order-item and order-header snapshots.
insert into private.order_request_fingerprints (order_id, user_id, idempotency_key, fingerprint)
select o.id, o.user_id, o.idempotency_key,
       private.make_order_fingerprint(
         o.user_id, o.idempotency_key, o.customer_name, o.phone, o.email,
         o.governorate_id, o.governorate_name, o.city, o.address_line, o.delivery_notes,
         o.payment_method, o.discount_code, o.subtotal, o.shipping_fee, o.discount_amount,
         o.total, o.currency, true,
         coalesce((
           select jsonb_agg(jsonb_build_object(
             'variant_id', oi.variant_id,
             'product_id', oi.product_id,
             'sku', oi.sku,
             'name', oi.product_name,
             'size', oi.size_label,
             'color', oi.color_name,
             'unit_price', oi.unit_price,
             'quantity', oi.quantity,
             'line_total', oi.line_total,
             'image_path', oi.image_path
           ) order by oi.variant_id)
           from public.order_items oi where oi.order_id = o.id
         ), '[]'::jsonb)
       )
  from public.orders o;

create or replace function public.place_order(
  p_customer_name text, p_phone text, p_governorate_id smallint, p_city text, p_address_line text,
  p_delivery_notes text, p_payment_method public.payment_method, p_discount_code text,
  p_terms_accepted boolean, p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_existing public.orders;
  v_order public.orders;
  v_q jsonb;
  v_line jsonb;
  v_phone text;
  v_email text;
  v_verified boolean;
  v_active boolean;
  v_gov text;
  v_after integer;
  v_qty integer;
  v_cart uuid;
  v_cart_count integer;
  v_order_line_count integer;
  v_lines jsonb;
  v_fingerprint text;
  v_stored_fingerprint text;
  v_normalized_name text;
  v_city text;
  v_address text;
  v_notes text;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED' using errcode = '28000'; end if;
  if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 100 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;

  -- Serialize the same (user,key) before looking up an existing order.
  -- Hash collisions only cause harmless extra serialization; they cannot merge keys.
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || ':' || p_idempotency_key, 0));

  select (u.email_confirmed_at is not null), u.email
    into v_verified, v_email
    from auth.users u where u.id = v_uid;
  if not coalesce(v_verified, false) then raise exception 'EMAIL_NOT_VERIFIED'; end if;
  select is_active into v_active from public.profiles where id = v_uid;
  if not coalesce(v_active, false) then raise exception 'ACCOUNT_DISABLED'; end if;
  if not coalesce(p_terms_accepted, false) then raise exception 'TERMS_NOT_ACCEPTED'; end if;
  if p_payment_method is null then raise exception 'INVALID_PAYMENT_METHOD'; end if;

  v_normalized_name := btrim(coalesce(p_customer_name, ''));
  v_city := btrim(coalesce(p_city, ''));
  v_address := btrim(coalesce(p_address_line, ''));
  v_notes := nullif(btrim(coalesce(p_delivery_notes, '')), '');
  if v_normalized_name = '' or v_city = '' or v_address = '' then raise exception 'INVALID_ADDRESS'; end if;
  v_phone := private.normalize_phone(p_phone);
  if v_phone is null or v_phone !~ '^\+?[0-9]{8,15}$' then raise exception 'INVALID_PHONE'; end if;

  -- Freeze this user's cart while taking its server-side snapshot. cart_set_item
  -- also locks the cart row via its upsert; row locks below protect direct deletes.
  select id into v_cart from public.carts where user_id = v_uid for update;
  if v_cart is not null then
    perform 1 from public.cart_items
     where cart_id = v_cart order by variant_id for update;
  end if;

  select * into v_existing
    from public.orders
   where user_id = v_uid and idempotency_key = p_idempotency_key;

  if found then
    -- A completed checkout clears its cart. An empty cart is therefore a valid retry.
    -- If a cart has since been repopulated, it must be exactly the original variant/qty set.
    select count(*) into v_cart_count from public.cart_items where cart_id = v_cart;
    if v_cart_count > 0 then
      select count(*) into v_order_line_count from public.order_items where order_id = v_existing.id;
      if v_cart_count <> v_order_line_count
         or exists (
           select 1 from public.cart_items ci
            where ci.cart_id = v_cart
              and not exists (
                select 1 from public.order_items oi
                 where oi.order_id = v_existing.id
                   and oi.variant_id = ci.variant_id and oi.quantity = ci.quantity
              )
         )
         or exists (
           select 1 from public.order_items oi
            where oi.order_id = v_existing.id
              and not exists (
                select 1 from public.cart_items ci
                 where ci.cart_id = v_cart
                   and ci.variant_id = oi.variant_id and ci.quantity = oi.quantity
              )
         ) then
        raise exception 'IDEMPOTENCY_CART_MISMATCH';
      end if;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
      'variant_id', oi.variant_id,
      'product_id', oi.product_id,
      'sku', oi.sku,
      'name', oi.product_name,
      'size', oi.size_label,
      'color', oi.color_name,
      'unit_price', oi.unit_price,
      'quantity', oi.quantity,
      'line_total', oi.line_total,
      'image_path', oi.image_path
    ) order by oi.variant_id), '[]'::jsonb)
      into v_lines
      from public.order_items oi where oi.order_id = v_existing.id;

    select fingerprint into v_stored_fingerprint
      from private.order_request_fingerprints where order_id = v_existing.id;
    if not found then raise exception 'IDEMPOTENCY_FINGERPRINT_MISSING'; end if;

    v_fingerprint := private.make_order_fingerprint(
      v_uid, p_idempotency_key, v_normalized_name, v_phone, v_email,
      p_governorate_id, v_existing.governorate_name, v_city, v_address, v_notes,
      p_payment_method, p_discount_code,
      v_existing.subtotal, v_existing.shipping_fee, v_existing.discount_amount,
      v_existing.total, v_existing.currency, true, v_lines
    );

    -- Explicitly compare the immutable location id as well as its stored name.
    if p_governorate_id is distinct from v_existing.governorate_id
       or v_fingerprint is distinct from v_stored_fingerprint then
      raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST';
    end if;

    return jsonb_build_object('order_id', v_existing.id, 'order_number', v_existing.order_number,
      'total', v_existing.total, 'payment_method', v_existing.payment_method, 'duplicate', true);
  end if;

  -- For a new request, all line items and all monetary values are loaded/calculated
  -- by private.price_cart from PostgreSQL rows; no browser price/variant snapshot is trusted.
  v_q := private.price_cart(v_uid, p_governorate_id, p_discount_code, true);
  select name_ar into v_gov from public.shipping_zones where id = p_governorate_id;

  v_fingerprint := private.make_order_fingerprint(
    v_uid, p_idempotency_key, v_normalized_name, v_phone, v_email,
    p_governorate_id, v_gov, v_city, v_address, v_notes,
    p_payment_method, v_q ->> 'discount_code',
    (v_q ->> 'subtotal')::numeric, (v_q ->> 'shipping_fee')::numeric,
    (v_q ->> 'discount_amount')::numeric, (v_q ->> 'total')::numeric,
    'EGP'::char(3), true, v_q -> 'lines'
  );

  insert into public.orders (user_id, payment_method, payment_status, customer_name, phone, email,
    governorate_id, governorate_name, city, address_line, delivery_notes,
    subtotal, shipping_fee, discount_amount, total, discount_code, terms_accepted_at, idempotency_key)
  values (v_uid, p_payment_method,
    case when p_payment_method = 'cod' then 'unpaid'::public.payment_status else 'pending'::public.payment_status end,
    v_normalized_name, v_phone, v_email, p_governorate_id, v_gov, v_city, v_address, v_notes,
    (v_q ->> 'subtotal')::numeric, (v_q ->> 'shipping_fee')::numeric,
    (v_q ->> 'discount_amount')::numeric, (v_q ->> 'total')::numeric,
    v_q ->> 'discount_code', now(), p_idempotency_key)
  returning * into v_order;

  insert into private.order_request_fingerprints (order_id, user_id, idempotency_key, fingerprint)
  values (v_order.id, v_uid, p_idempotency_key, v_fingerprint);

  for v_line in select value from jsonb_array_elements(v_q -> 'lines') loop
    v_qty := (v_line ->> 'quantity')::integer;
    insert into public.order_items (order_id, variant_id, product_id, product_name, sku, size_label, color_name,
                                    unit_price, quantity, line_total, image_path)
    values (v_order.id, (v_line ->> 'variant_id')::uuid, (v_line ->> 'product_id')::uuid,
      v_line ->> 'name', v_line ->> 'sku', v_line ->> 'size', v_line ->> 'color',
      (v_line ->> 'unit_price')::numeric, v_qty, (v_line ->> 'line_total')::numeric, v_line ->> 'image_path');

    update public.inventory set quantity = quantity - v_qty, updated_at = now()
     where variant_id = (v_line ->> 'variant_id')::uuid and quantity >= v_qty
     returning quantity into v_after;
    if not found then raise exception 'INSUFFICIENT_STOCK:%', v_line ->> 'sku'; end if;
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
  delete from public.cart_items where cart_id = v_cart;

  return jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number,
    'total', v_order.total, 'payment_method', v_order.payment_method, 'duplicate', false);
end $$;

revoke execute on function private.make_order_fingerprint(uuid, text, text, text, text, smallint, text, text, text, text, public.payment_method, text, numeric, numeric, numeric, numeric, char(3), boolean, jsonb) from public, anon, authenticated;
revoke execute on function public.place_order(text, text, smallint, text, text, text, public.payment_method, text, boolean, text) from public, anon;
grant execute on function public.place_order(text, text, smallint, text, text, text, public.payment_method, text, boolean, text) to authenticated;
