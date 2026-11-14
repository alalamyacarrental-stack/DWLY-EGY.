#!/usr/bin/env bash
# True two-session race test for the last inventory unit.
# Usage: DATABASE_URL=postgresql://... ./backend/scripts/test_concurrent_last_unit.sh
set -euo pipefail
: "${DATABASE_URL:?Set DATABASE_URL to the local Supabase PostgreSQL connection string}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
USER_A='f1000000-0000-4000-8000-000000000001'
USER_B='f1000000-0000-4000-8000-000000000002'
PRODUCT='f1000000-0000-4000-8000-000000000010'
VARIANT='f1000000-0000-4000-8000-000000000011'
ZONE='ConcurrencyTestZone'
cleanup() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null 2>&1 || true
 delete from public.orders where user_id in ('$USER_A'::uuid, '$USER_B'::uuid);
 delete from public.carts where user_id in ('$USER_A'::uuid, '$USER_B'::uuid);
 delete from auth.users where id in ('$USER_A'::uuid, '$USER_B'::uuid);
 delete from public.products where id = '$PRODUCT'::uuid;
 delete from public.shipping_zones where name_en = '$ZONE';
 delete from public.sizes where label = 'CONC-TEST';
SQL
  rm -rf "$TMP"
}
trap cleanup EXIT

# Isolated fixture with exactly one sellable unit.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
 delete from public.orders where user_id in ('$USER_A'::uuid, '$USER_B'::uuid);
 delete from public.carts where user_id in ('$USER_A'::uuid, '$USER_B'::uuid);
 delete from auth.users where id in ('$USER_A'::uuid, '$USER_B'::uuid);
 delete from public.products where id = '$PRODUCT'::uuid;
 delete from public.shipping_zones where name_en = '$ZONE';
 delete from public.sizes where label = 'CONC-TEST';
 insert into auth.users (id,email,email_confirmed_at) values
   ('$USER_A','concurrency-a@dwly.test',now()), ('$USER_B','concurrency-b@dwly.test',now());
 insert into public.shipping_zones (name_ar,name_en,fee,is_available) values ('اختبار تزامن','$ZONE',1,true);
 insert into public.sizes (label) values ('CONC-TEST');
 insert into public.products (id,slug,name_ar,base_price,status,is_demo)
   values ('$PRODUCT','concurrency-test-product','Concurrency Test',10,'active',true);
 insert into public.product_variants (id,product_id,sku,size_id)
   select '$VARIANT','$PRODUCT','CONC-TEST-SKU',id from public.sizes where label='CONC-TEST';
 update public.inventory set quantity=1 where variant_id='$VARIANT';
SQL

# Both customers add the same final unit before either checkout starts.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
 set role authenticated;
 select set_config('request.jwt.claims','{"sub":"$USER_A","role":"authenticated"}',false);
 select public.cart_set_item('$VARIANT',1);
SQL
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
 set role authenticated;
 select set_config('request.jwt.claims','{"sub":"$USER_B","role":"authenticated"}',false);
 select public.cart_set_item('$VARIANT',1);
SQL

checkout() {
  local user="$1" phone="$2" key="$3" city="$4" file="$5"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q >"$file" 2>&1 <<SQL
 set role authenticated;
 select set_config('request.jwt.claims','{"sub":"$user","role":"authenticated"}',false);
 select public.place_order('Concurrency Buyer','$phone',(select id from public.shipping_zones where name_en='$ZONE'),'Concurrency City','$city',null,'cod',null,true,'$key');
SQL
}
set +e
checkout "$USER_A" '01011111111' 'concurrent-key-a' 'Address A' "$TMP/a.log" & PID_A=$!
checkout "$USER_B" '01022222222' 'concurrent-key-b' 'Address B' "$TMP/b.log" & PID_B=$!
wait "$PID_A"; STATUS_A=$?
wait "$PID_B"; STATUS_B=$?
set -e

SUCCESS_COUNT=0
FAIL_COUNT=0
[[ "$STATUS_A" -eq 0 ]] && SUCCESS_COUNT=$((SUCCESS_COUNT+1)) || FAIL_COUNT=$((FAIL_COUNT+1))
[[ "$STATUS_B" -eq 0 ]] && SUCCESS_COUNT=$((SUCCESS_COUNT+1)) || FAIL_COUNT=$((FAIL_COUNT+1))
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<SQL >"$TMP/assertions"
 select (select count(*) from public.orders where user_id in ('$USER_A'::uuid,'$USER_B'::uuid));
 select quantity from public.inventory where variant_id='$VARIANT';
SQL
ORDER_COUNT="$(sed -n '1p' "$TMP/assertions")"
STOCK="$(sed -n '2p' "$TMP/assertions")"
cat "$TMP/a.log" "$TMP/b.log"
printf '\nConcurrent result: success=%s failure=%s orders=%s stock=%s\n' "$SUCCESS_COUNT" "$FAIL_COUNT" "$ORDER_COUNT" "$STOCK"
if [[ "$SUCCESS_COUNT" -ne 1 || "$FAIL_COUNT" -ne 1 || "$ORDER_COUNT" -ne 1 || "$STOCK" -ne 0 ]]; then
  echo 'FAIL: concurrent last-unit invariant violated' >&2
  exit 1
fi
echo 'PASS: exactly one concurrent checkout committed; no oversell.'

# Second phase: same user + same key + same payload submitted concurrently.
# Both calls must succeed at the RPC level, but only one order and one stock decrement may commit.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
 delete from public.cart_items where cart_id in (select id from public.carts where user_id in ('$USER_A'::uuid,'$USER_B'::uuid));
 update public.inventory set quantity=2 where variant_id='$VARIANT';
SQL
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
 set role authenticated;
 select set_config('request.jwt.claims','{"sub":"$USER_A","role":"authenticated"}',false);
 select public.cart_set_item('$VARIANT',1);
SQL
checkout "$USER_A" '01011111111' 'concurrent-same-key' 'Same Address' "$TMP/same-a.log" & SAME_A=$!
checkout "$USER_A" '01011111111' 'concurrent-same-key' 'Same Address' "$TMP/same-b.log" & SAME_B=$!
wait "$SAME_A"
wait "$SAME_B"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atq <<SQL >"$TMP/same-assertions"
 select count(*) from public.orders where user_id='$USER_A'::uuid and idempotency_key='concurrent-same-key';
 select quantity from public.inventory where variant_id='$VARIANT';
SQL
SAME_ORDERS="$(sed -n '1p' "$TMP/same-assertions")"
SAME_STOCK="$(sed -n '2p' "$TMP/same-assertions")"
cat "$TMP/same-a.log" "$TMP/same-b.log"
printf 'Same-key result: orders=%s stock=%s\n' "$SAME_ORDERS" "$SAME_STOCK"
if [[ "$SAME_ORDERS" -ne 1 || "$SAME_STOCK" -ne 1 ]]; then
  echo 'FAIL: concurrent same-key request was not idempotent' >&2
  exit 1
fi
echo 'PASS: concurrent same-key requests created one order and decremented stock once.'
