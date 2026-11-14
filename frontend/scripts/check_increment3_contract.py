#!/usr/bin/env python3
"""Static checks for Increment 3.0 checkout wiring against the existing SQL contract."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[2]
APP = (ROOT / 'frontend/src/App.tsx').read_text(encoding='utf-8')
MIG = ROOT / 'backend/supabase/migrations'
SQL = '\n'.join(p.read_text(encoding='utf-8') for p in sorted(MIG.glob('*.sql')))
checks = []
def check(label, ok): checks.append((label, bool(ok)))

check('quote_cart exists with governorate and discount parameters', bool(re.search(r'function\s+public\.quote_cart\s*\(p_governorate_id\s+smallint,\s*p_discount_code\s+text', SQL, re.I)))
check('place_order exists with ten expected parameters', bool(re.search(r'function\s+public\.place_order\s*\(\s*p_customer_name\s+text,\s*p_phone\s+text,\s*p_governorate_id\s+smallint,\s*p_city\s+text,\s*p_address_line\s+text,\s*p_delivery_notes\s+text,\s*p_payment_method\s+public\.payment_method,\s*p_discount_code\s+text,\s*p_terms_accepted\s+boolean,\s*p_idempotency_key\s+text', SQL, re.I)))
check('checkout invokes quote_cart with exact argument names', "rpc('quote_cart',{p_governorate_id:Number(zoneId),p_discount_code:discount.trim()||null})" in APP)
check('checkout invokes place_order with exact argument names', all(x in APP for x in ['p_customer_name:name.trim()', 'p_governorate_id:Number(zoneId)', "p_payment_method:'cod'", 'p_idempotency_key:keyRef.current']))
check('checkout is COD only; no online payment integration', "p_payment_method:'cod'" in APP and 'stripe' not in APP.lower() and 'paypal' not in APP.lower())
check('idempotency key persisted across retries', 'localStorage.getItem(storageKey)' in APP and 'localStorage.setItem(storageKey,keyRef.current)' in APP)
check('idempotency key cleared only after RPC success', APP.index('localStorage.removeItem(storageKey)') > APP.index("rpc('place_order'"))
check('quote totals displayed from server response', all(x in APP for x in ['quote.subtotal','quote.shipping_fee','quote.discount_amount','quote.total']))
check('shipping zones loaded from database', "from('shipping_zones').select('id,name_ar,fee,is_available')" in APP)
check('saved addresses are scoped to authenticated user', "from('addresses').select('id,recipient_name,phone,governorate_id,city,address_line,delivery_notes').eq('user_id',session.user.id)" in APP)
check('orders history is scoped to authenticated user', "from('orders').select('id,order_number,status,total,created_at').eq('user_id', props.session.user.id)" in APP)
check('order status labels cover lifecycle', all(x in APP for x in ['pending:','confirmed:','processing:','shipped:','out_for_delivery:','delivered:','cancelled:']))
check('customer order reads protected by existing RLS', bool(re.search(r'create\s+policy\s+orders_select\s+on\s+public\.orders[\s\S]{0,180}user_id\s*=\s*\(select\s+auth\.uid\(\)\)', SQL, re.I)))
check('address RLS policy scopes to own account', bool(re.search(r'create\s+policy\s+addresses_own\s+on\s+public\.addresses[\s\S]{0,220}user_id\s*=\s*\(select\s+auth\.uid\(\)\)', SQL, re.I)))
check('frontend has no service role key', not re.search(r'SUPABASE_SERVICE_ROLE|service_role', APP, re.I))
check('0011 security projection is separate from the 0001-0010 commerce baseline', len(list(MIG.glob('*.sql'))) == 11 and (MIG / '0011_boolean_only_variant_availability.sql').exists())
for label, ok in checks: print(('PASS ' if ok else 'FAIL ') + label)
print(f'\n{sum(ok for _,ok in checks)} passed, {sum(not ok for _,ok in checks)} failed')
raise SystemExit(0 if all(ok for _,ok in checks) else 1)
