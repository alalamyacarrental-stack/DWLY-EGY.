#!/usr/bin/env python3
"""Small source/schema contract audit for the Increment 2.2 storefront."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
MIG = ROOT / 'backend/supabase/migrations'
APP = ROOT / 'frontend/src/App.tsx'
SUPABASE = ROOT / 'frontend/src/lib/supabase.ts'
app = APP.read_text(encoding='utf-8')
all_sql = '\n'.join(p.read_text(encoding='utf-8') for p in sorted(MIG.glob('*.sql')))
commerce = (MIG / '0003_commerce.sql').read_text(encoding='utf-8')
security = (MIG / '0005_security.sql').read_text(encoding='utf-8')
checks = []
def check(name, condition):
    checks.append((name, bool(condition)))

for table in ('products', 'categories', 'product_variants', 'sizes', 'colors', 'product_images', 'variant_stock', 'carts', 'cart_items'):
    check(f'frontend table/view exists: {table}', bool(re.search(rf'create\s+(?:table|view)\s+public\.{table}\b', all_sql, re.I)))
for column in ('status', 'is_demo', 'base_price', 'compare_at_price', 'discount_percent', 'is_featured', 'created_at'):
    check(f'products column exists: {column}', bool(re.search(rf'create\s+table\s+public\.products\s*\([\s\S]*?\b{column}\b', all_sql, re.I)))
availability = (MIG / '0011_boolean_only_variant_availability.sql').read_text(encoding='utf-8')
check('stock view exposes boolean-only availability', bool(re.search(r'create view public\.variant_stock with \(security_invoker = true\) as[\s\S]*?select variant_id, product_id, in_stock from public\.variant_availability', availability, re.I)))
check('public stock projection contains no quantity field', 'quantity' not in re.search(r'create table public\.variant_availability \(([\s\S]*?)\);', availability, re.I).group(1).lower())
migration_0010 = (MIG / '0010_public_catalog_hardening.sql').read_text(encoding='utf-8')
check('stock view excludes demo after migration 0010', 'p.is_demo = false' in migration_0010)
check('public products RLS hides demo rows', "status = 'active' and not is_demo" in migration_0010)
check('public product variants and images RLS hide demo parents', migration_0010.count('not p.is_demo') >= 2)
check('inventory is staff-only under RLS', 'create policy inventory_staff_read' in security and 'using (private.is_staff())' in security)
check('Storage bucket name matches frontend helper', "from('product-images')" in SUPABASE.read_text(encoding='utf-8') and "'product-images'" in security)
check('frontend filters non-demo products', ".eq('is_demo', false)" in app)
check('frontend reads only public availability boolean', ".select('variant_id,product_id,in_stock')" in app)
check('stock query error fails closed', 'تعذر التحقق من توافر المقاسات والمخزون' in app)
check('missing stock rows fail closed', 'stockByVariant.get(variant.id) === true' in app)
check('cart write uses existing RPC', "rpc('cart_set_item'" in app and 'create or replace function public.cart_set_item(p_variant_id uuid, p_quantity integer)' in all_sql)
check('no service role key in frontend', not re.search(r'service[_-]?role|SUPABASE_SERVICE_ROLE', '\n'.join(p.read_text(encoding='utf-8', errors='ignore') for folder in (ROOT/'frontend/src', ROOT/'frontend') for p in folder.glob('.env.example') if p.is_file()) + app + SUPABASE.read_text(encoding='utf-8'), re.I))

for name, ok in checks:
    print(('PASS' if ok else 'FAIL') + ' ' + name)
print(f'\n{sum(ok for _, ok in checks)} passed, {sum(not ok for _, ok in checks)} failed')
raise SystemExit(0 if all(ok for _, ok in checks) else 1)
