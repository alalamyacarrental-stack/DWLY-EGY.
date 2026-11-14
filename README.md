# DWLY EGY — V2 (متجر dwly.eg)

منصة تجارة إلكترونية للملابس الشبابية والبناتية. هذا المستودع هو **V2**؛ النسخة الأصلية محفوظة بدون أي تعديل في `original/DWLY_EGY_V1.html`.

## حالة المشروع

| المرحلة | الحالة |
|---|---|
| 1. قاعدة البيانات + RLS + الدوال + بيانات تجريبية | **مكتوبة، وفُحصت ساكنًا (static)** — لم تُشغَّل على Postgres بعد |
| 2. واجهة المتجر (React + Vite + TS) | **الأساس + كتالوج Supabase + تسجيل الدخول + مسودة السلة** — جاري التنفيذ |
| 3. المصادقة وحساب العميل | الأساس في قاعدة البيانات جاهز؛ الواجهة لم تبدأ |
| 4. السلة والـ checkout | الدوال جاهزة في قاعدة البيانات؛ الواجهة لم تبدأ |
| 5. الدفع عند الاستلام | منطق قاعدة البيانات جاهز |
| 6. الدفع الإلكتروني | دالة تسجيل أحداث الدفع جاهزة؛ الـ Edge Function ينتظر حساب تاجر |
| 7. لوحة الإدارة | دوال الإدارة جاهزة؛ الواجهة لم تبدأ |

## الهيكل

```
DWLY_EGY/
  original/DWLY_EGY_V1.html     النسخة الأصلية (للقراءة فقط، SHA-256 في docs/V1.sha256)
  backend/
    supabase/migrations/        0001..0010 (الأساس، الجداول، التجارة، الدوال، الأمان، الاسترداد، بصمة الطلب، تقوية التجارة، رسوم القاهرة والجيزة، إخفاء مخزون منتجات Demo)
    supabase/seed.sql           بيانات تجريبية (محلي فقط)
    supabase/purge_demo.sql     يحذف كل البيانات التجريبية
    supabase/tests/database/    اختبارات pgTAP (لم تُشغَّل بعد)
    supabase/functions/         Edge Functions (المرحلة 6)
    scripts/static_check.py     فحص ساكن للـ migrations والمستودع
  frontend/                     React + Vite storefront (Phase 2)
  docs/                         قرارات وتقارير
  .env.example                  أسماء المتغيرات فقط (بدون مفاتيح)
```

## التشغيل المحلي (بعد تثبيت Docker و Supabase CLI)

```bash
cd backend
supabase init            # ينشئ config.toml فقط؛ لا يمس migrations (أجب بـ No عن إعدادات المحرر)
supabase start
supabase db reset        # يطبّق migrations ثم seed.sql
supabase test db         # يشغّل اختبارات pgTAP
python3 scripts/static_check.py
# بعد تشغيل قاعدة البيانات، من جذر المشروع:
cd ..
./backend/scripts/test_concurrent_last_unit.sh
```

## تشغيل الواجهة محليًا

```bash
cd frontend
cp .env.example .env
# املأ VITE_SUPABASE_URL و VITE_SUPABASE_ANON_KEY من إعدادات مشروعك
npm install
npm run dev
```

لا تضع `service_role` أو أي مفتاح سري في متغير يبدأ بـ `VITE_`. الكتالوج يستبعد كل صف `is_demo = true` ولا يعرض بيانات seed التجريبية كمنتجات حقيقية.

## ربط حساب Supabase (لاحقًا)

1. أنشئ مشروعًا على الخطة المجانية.
2. `supabase link --project-ref <ref>` ثم `supabase db push` (يطبّق migrations فقط، **بدون** seed).
3. من SQL Editor: سجّل حسابك من الموقع أولًا، ثم أعطِ نفسك صلاحية الإدارة (لا توجد واجهة لذلك عمدًا):
   ```sql
   insert into public.roles (user_id, role)
   select id, 'admin' from auth.users where email = 'YOUR_EMAIL';
   ```
4. فعّل تأكيد البريد الإلكتروني من إعدادات Auth.
5. رسوم القاهرة 60 جنيهًا والجيزة 75 جنيهًا تُضبط بواسطة migration 0009. المحافظات الأخرى تظل **غير متاحة** حتى يحدد المدير رسومها.

## تحديث المرحلة الأمنية الأولى

- `0006_refunds.sql`: مسار استرداد منفصل مع تسجيل طلب الاسترداد وإتمامه والتحقق من المبلغ.
- `0007_order_idempotency.sql`: بصمة SHA-256 خادمية محفوظة في `private.order_request_fingerprints`، مع قفل معاملات لكل `(user_id, idempotency_key)` ورفض إعادة استخدام المفتاح بمحتوى مختلف.
- `0008_commerce_hardening.sql`: قفل صف الخصم قبل التحقق من حدود الاستخدام، ومنع تجاوز مسار الاسترداد، وحماية حالات الدفع من إشعارات مزود الدفع المتأخرة.
- اختبارات pgTAP واختبار التزامن أُضيفت لكن **لم تُشغّل بعد** لعدم توفر PostgreSQL/Docker/Supabase CLI في بيئة التطوير الحالية.

## قرارات التصميم الأساسية

- **الأسعار لا تُخزَّن في السلة ولا تأتي من المتصفح.** `place_order` تقرأ السلة والأسعار والمخزون والشحن من قاعدة البيانات داخل معاملة واحدة.
- **لا كتابة مباشرة من العميل** على الطلبات أو المدفوعات أو المخزون. كل التغييرات عبر دوال محددة.
- **المخزون لا يقل عن صفر** (قيد CHECK) ويُقفل أثناء الطلب. الإلغاء يرجّع المخزون مرة واحدة فقط.
- **منع تكرار الطلب:** مفتاح `idempotency_key` فريد لكل عميل، مع SHA-256 خادمي لبصمة الطلب وقفل advisory على مستوى المعاملة. لا يرسل المتصفح الأسعار أو بصمة موثوقة.
- **الـ webhook:** `record_payment_event` متاحة لـ `service_role` فقط، وتتجاهل الأحداث المكررة، وترفض أي مبلغ غير مطابق.
- **الأدوار:** `staff` للكتالوج والمخزون والطلبات، و`admin` يضيف الإعدادات والشحن وأكواد الخصم وحالة الحسابات. الدور لا يُقرأ أبدًا من بيانات المستخدم.
- **لا بيانات مخترعة:** رسوم الشحن الأولية للقاهرة والجيزة فقط محددة في migration 0009؛ صور المنتجات والمراجعات والمخزون الحقيقي ليست في migrations. كل محتوى `seed.sql` موسوم `is_demo`.

## ملاحظات حدود معروفة

- إعدادات الضريبة موجودة في `store_settings` لكن **غير مطبّقة** في حساب الطلب (الأسعار تُعامل كشاملة).
- اشتراك النشرة البريدية مفتوح للزوار؛ أضف CAPTCHA أو rate limit قبل الإطلاق.
- حذف حساب عميل لديه طلبات ممنوع بقيد قاعدة البيانات (`on delete restrict`)؛ استخدم تعطيل الحساب.
- تغيير البريد في Auth لا يُزامَن تلقائيًا إلى `profiles.email` بعد.


## Phase 2 progress

راجع `docs/PHASE2_PROGRESS.md` و`docs/INCREMENT_2_2_REPORT.md` لمعرفة ما تم في الواجهة وما لم يُختبر بعد. Migration `0009_initial_shipping_fees.sql` تضبط القاهرة 60 جنيهًا والجيزة 75 جنيهًا مع الحفاظ على أي رسوم مخصصة. Migration `0010_public_catalog_hardening.sql` تحافظ على عرض توافر المخزون بشكل عام دون كشف الكمية الدقيقة، وتستبعد منتجات Demo.

## Increment 3.0 — Store & Checkout

The storefront now includes authenticated checkout using the existing database RPCs:

- `quote_cart(p_governorate_id, p_discount_code)` for server-calculated totals.
- `place_order(...)` for the authoritative order write, inventory decrement, discount redemption, cart clearing, and idempotent retry handling.
- Cash on delivery only (`cod`). No online payment provider is configured.
- Customer order history reads are scoped to the signed-in user's own rows by the existing RLS policies.
- Customer delivery addresses are read and written through the existing owner-scoped `addresses` policy.

No new SQL migration was introduced in Increment 3.0. Existing migrations `0001`–`0010` are retained unchanged. Apply pending migrations to a hosted project only after inspecting its current schema/migration history; do not run `supabase db reset` against production.

### Frontend environment

Create `frontend/.env.local` (never commit this file):

```dotenv
VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_KEY
VITE_SITE_URL=http://localhost:5173
```

Only the Supabase publishable/anon key belongs in the browser. Never use the service-role/secret key in `VITE_*` variables.

### Run locally

```bash
cd frontend
npm install
npm run build
npm run dev
```

Checkout requires a confirmed email because the existing `place_order` RPC enforces `EMAIL_NOT_VERIFIED`. The checkout keeps the same idempotency key in browser storage after a failed/uncertain RPC response and clears it only after a successful response. The database remains the authority for price, stock, shipping, discounts, and order creation.

## Admin dashboard (DWLY EGY)

The storefront now includes a protected in-app admin view opened from the **الإدارة** button after sign-in. It reuses the existing Supabase Auth session and verifies staff access by calling the existing `admin_dashboard_stats` RPC; it does not trust a browser-side role flag.

### First administrator setup

1. Start the storefront and create the owner's account from **حسابي** using the email address that will own the store.
2. Confirm the email using the message sent by Supabase, then sign in.
3. Open `backend/supabase/setup_first_admin.sql` and replace `REPLACE_WITH_YOUR_LOGIN_EMAIL` in both places with the confirmed account email.
4. Run that script once in the intended Supabase project's SQL Editor. It grants the `admin` role to that existing Auth user; it does not create an account or change any other user's role.
5. Return to the storefront, sign out and sign in again, then open **الإدارة**.

Never add a service-role key to any `VITE_` variable or frontend file. The first-admin SQL is intentionally a manual owner-only action in Supabase SQL Editor.

### Dashboard modules

- Overview: sales/order summary and low-stock alerts through the existing staff-only RPC.
- Products: create/edit products, draft/publish/archive, and category assignment. Products are never created as demo records.
- Variants: add SKU, size, color, optional price override, and opening stock. The existing variant trigger creates the inventory row; the existing `admin_adjust_inventory` RPC records opening stock.
- Product images: upload public catalog images to the existing `product-images` bucket and link them to `product_images`. Accepted formats: JPG, PNG, WEBP, AVIF; max 5 MB per image.
- Categories: add main/subcategories and activate/deactivate categories.
- Inventory: view staff inventory and adjust quantities only through `admin_adjust_inventory` (with movement logging and no negative stock).
- Orders: view recent orders and use the existing `admin_set_order_status` transition RPC; invalid transitions remain blocked by the database.
- Customers: view customer profiles under the existing staff RLS policy.

The dashboard does not bypass existing RLS or change database migrations. Shipping settings, discounts, collections/banners, and deeper reporting remain follow-up admin modules. Live Supabase operations and a full Vite production build must still be verified in the owner's configured environment before launch.
