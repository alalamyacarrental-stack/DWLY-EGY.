-- 0003_commerce.sql : carts, discounts, orders, payments, reviews, settings
-- Prices are NEVER stored in the cart: they are always read from the catalog at order time.

create table public.carts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null unique references auth.users(id) on delete cascade,
  updated_at timestamptz not null default now()
);
create table public.cart_items (
  id         uuid primary key default gen_random_uuid(),
  cart_id    uuid not null references public.carts(id) on delete cascade,
  variant_id uuid not null references public.product_variants(id) on delete cascade,
  quantity   integer not null check (quantity between 1 and 20),
  unique (cart_id, variant_id)
);
create index cart_items_cart_idx on public.cart_items (cart_id);

create table public.discount_codes (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null check (code = upper(btrim(code)) and length(code) between 3 and 32),
  type                public.discount_type not null,
  value               numeric(10,2) not null check (value > 0),
  min_order_amount    numeric(10,2) not null default 0 check (min_order_amount >= 0),
  max_discount_amount numeric(10,2) check (max_discount_amount is null or max_discount_amount > 0),
  starts_at           timestamptz,
  ends_at             timestamptz,
  usage_limit         integer check (usage_limit is null or usage_limit > 0),
  per_user_limit      integer not null default 1 check (per_user_limit > 0),
  used_count          integer not null default 0 check (used_count >= 0),
  is_active           boolean not null default true,
  is_demo             boolean not null default false,
  created_at          timestamptz not null default now(),
  constraint discount_percent_max check (type <> 'percent' or value <= 100)
);
create unique index discount_codes_code_uq on public.discount_codes (lower(code));

create sequence public.order_number_seq start 1;

create table public.orders (
  id               uuid primary key default gen_random_uuid(),
  order_number     text not null unique default (
    'DW-' || to_char(now() at time zone 'Africa/Cairo', 'YYMMDD') || '-' || lpad(nextval('public.order_number_seq')::text, 5, '0')
  ),
  user_id          uuid not null references auth.users(id) on delete restrict,
  status           public.order_status not null default 'pending',
  payment_method   public.payment_method not null,
  payment_status   public.payment_status not null default 'unpaid',
  customer_name    text not null,
  phone            text not null check (phone ~ '^\+?[0-9]{8,15}$'),
  email            text,
  governorate_id   smallint not null references public.shipping_zones(id),
  governorate_name text not null,
  city             text not null,
  address_line     text not null,
  delivery_notes   text,
  subtotal         numeric(10,2) not null check (subtotal >= 0),
  shipping_fee     numeric(10,2) not null check (shipping_fee >= 0),
  discount_amount  numeric(10,2) not null default 0 check (discount_amount >= 0),
  total            numeric(10,2) not null check (total >= 0),
  currency         char(3) not null default 'EGP' check (currency = 'EGP'),
  discount_code    text,
  stock_restored   boolean not null default false,
  terms_accepted_at timestamptz not null,
  idempotency_key  text not null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint orders_total_matches check (total = subtotal + shipping_fee - discount_amount),
  constraint orders_discount_le_subtotal check (discount_amount <= subtotal),
  unique (user_id, idempotency_key)            -- double-click / retry cannot create two orders
);
create index orders_user_idx   on public.orders (user_id, created_at desc);
create index orders_status_idx on public.orders (status, created_at desc);

alter table public.inventory_movements
  add constraint inventory_movements_order_fk foreign key (order_id) references public.orders(id) on delete set null;

create table public.order_items (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.orders(id) on delete cascade,
  variant_id   uuid not null references public.product_variants(id) on delete restrict,
  product_id   uuid not null references public.products(id) on delete restrict,
  product_name text not null,           -- snapshots: history survives later catalog edits
  sku          text not null,
  size_label   text,
  color_name   text,
  unit_price   numeric(10,2) not null check (unit_price >= 0),
  quantity     integer not null check (quantity > 0),
  line_total   numeric(10,2) not null check (line_total = unit_price * quantity),
  image_path   text
);
create index order_items_order_idx on public.order_items (order_id);

create table public.order_status_history (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references public.orders(id) on delete cascade,
  from_status public.order_status,
  to_status   public.order_status not null,
  note        text,
  changed_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index order_status_history_order_idx on public.order_status_history (order_id, created_at);

create table public.discount_redemptions (
  id          uuid primary key default gen_random_uuid(),
  discount_id uuid not null references public.discount_codes(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  order_id    uuid not null unique references public.orders(id) on delete cascade,
  amount      numeric(10,2) not null check (amount >= 0),
  created_at  timestamptz not null default now()
);
create index discount_redemptions_lookup_idx on public.discount_redemptions (discount_id, user_id);

create table public.payments (
  id                 uuid primary key default gen_random_uuid(),
  order_id           uuid not null references public.orders(id) on delete cascade,
  method             public.payment_method not null,
  status             public.payment_status not null,
  amount             numeric(10,2) not null check (amount >= 0),
  currency           char(3) not null default 'EGP' check (currency = 'EGP'),
  provider           text,
  provider_order_ref text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (provider, provider_order_ref)
);
create index payments_order_idx on public.payments (order_id);

-- One row per provider event. The unique key makes webhook re-delivery idempotent.
-- Never store card numbers / CVV; the edge function must strip them from raw_payload.
create table public.payment_transactions (
  id                 uuid primary key default gen_random_uuid(),
  payment_id         uuid not null references public.payments(id) on delete cascade,
  provider           text not null,
  provider_txn_id    text not null,
  event_type         text not null,
  amount             numeric(10,2) check (amount is null or amount >= 0),
  status             text not null,
  signature_verified boolean not null,
  raw_payload        jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now(),
  unique (provider, provider_txn_id, event_type)
);

create table public.reviews (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references public.products(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  order_item_id uuid not null unique references public.order_items(id) on delete cascade,  -- verified purchase
  rating        smallint not null check (rating between 1 and 5),
  title         text,
  body          text check (body is null or length(body) <= 2000),
  status        public.review_status not null default 'pending',
  created_at    timestamptz not null default now()
);
create index reviews_product_idx on public.reviews (product_id, status);

create table public.store_settings (
  key        text primary key,
  value      jsonb not null,
  is_public  boolean not null default false,
  updated_at timestamptz not null default now()
);
-- Only facts already provided by the owner. Everything else is configured from the admin dashboard.
insert into public.store_settings (key, value, is_public) values
  ('store_name', '"DWLY EGY"', true),
  ('currency',   '"EGP"',      true),
  ('tax',        '{"enabled": false, "rate_percent": null}', false);

create table public.newsletter_subscribers (
  id         uuid primary key default gen_random_uuid(),
  email      text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),
  created_at timestamptz not null default now()
);
create unique index newsletter_email_uq on public.newsletter_subscribers (lower(email));

-- Safe public stock view: exposes only availability (capped at 10), never exact stock or movements.
create view public.variant_stock with (security_invoker = false) as
  select v.id as variant_id, v.product_id,
         least(i.quantity, 10) as available,
         (i.quantity > 0)      as in_stock
  from public.product_variants v
  join public.products  p on p.id = v.product_id and p.status = 'active'
  join public.inventory i on i.variant_id = v.id
  where v.is_active;
