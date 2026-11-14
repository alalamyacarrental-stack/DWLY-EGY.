-- 0002_catalog_and_identity.sql : identity, shipping zones, catalog, inventory, marketing content

-- ---------- identity ----------
-- Privileges live ONLY here. Rows are created with the service role / SQL editor, never from the client.
create table public.roles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       public.app_role not null,
  granted_at timestamptz not null default now()
);

create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  phone      text check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- shipping zones (one row per Egyptian governorate) ----------
create table public.shipping_zones (
  id                      smallint generated always as identity primary key,
  name_ar                 text not null unique,
  name_en                 text not null unique,
  fee                     numeric(10,2) check (fee is null or fee >= 0),
  free_shipping_threshold numeric(10,2) check (free_shipping_threshold is null or free_shipping_threshold >= 0),
  est_days_min            smallint check (est_days_min is null or est_days_min >= 0),
  est_days_max            smallint check (est_days_max is null or est_days_max >= 0),
  is_available            boolean not null default false,
  constraint shipping_days_order check (est_days_min is null or est_days_max is null or est_days_max >= est_days_min),
  -- a zone cannot be switched on until the owner has set a real fee
  constraint shipping_available_needs_fee check (not is_available or fee is not null)
);

-- Reference data only: names. Fees stay NULL and zones stay unavailable until the owner configures them.
insert into public.shipping_zones (name_ar, name_en) values
('القاهرة','Cairo'),('الجيزة','Giza'),('الإسكندرية','Alexandria'),('الدقهلية','Dakahlia'),
('البحر الأحمر','Red Sea'),('البحيرة','Beheira'),('الفيوم','Fayoum'),('الغربية','Gharbia'),
('الإسماعيلية','Ismailia'),('المنوفية','Menofia'),('المنيا','Minya'),('القليوبية','Qalyubia'),
('الوادي الجديد','New Valley'),('السويس','Suez'),('أسوان','Aswan'),('أسيوط','Assiut'),
('بني سويف','Beni Suef'),('بورسعيد','Port Said'),('دمياط','Damietta'),('الشرقية','Sharqia'),
('جنوب سيناء','South Sinai'),('كفر الشيخ','Kafr El Sheikh'),('مطروح','Matrouh'),('الأقصر','Luxor'),
('قنا','Qena'),('شمال سيناء','North Sinai'),('سوهاج','Sohag');

create table public.addresses (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  label          text,
  recipient_name text not null,
  phone          text not null check (phone ~ '^\+?[0-9]{8,15}$'),
  governorate_id smallint not null references public.shipping_zones(id),
  city           text not null,
  address_line   text not null,
  delivery_notes text,
  is_default     boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index addresses_one_default_per_user on public.addresses (user_id) where is_default;
create index addresses_user_idx on public.addresses (user_id);

-- ---------- catalog ----------
create table public.categories (
  id         uuid primary key default gen_random_uuid(),
  parent_id  uuid references public.categories(id) on delete set null,
  slug       text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name_ar    text not null,
  name_en    text,
  image_path text,
  sort_order integer not null default 0,
  is_active  boolean not null default true,
  is_demo    boolean not null default false
);

create table public.colors (
  id        smallint generated always as identity primary key,
  code      text not null unique check (code ~ '^[a-z0-9_]+$'),
  name_ar   text not null,
  name_en   text,
  hex       text not null check (hex ~ '^#[0-9A-Fa-f]{6}$'),
  is_active boolean not null default true
);

create table public.sizes (
  id         smallint generated always as identity primary key,
  label      text not null unique,
  sort_order integer not null default 0
);

create table public.products (
  id               uuid primary key default gen_random_uuid(),
  slug             text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name_ar          text not null,
  name_en          text,
  description_ar   text,
  description_en   text,
  category_id      uuid references public.categories(id) on delete set null,
  gender           public.product_gender not null default 'unisex',
  base_price       numeric(10,2) not null check (base_price >= 0),
  compare_at_price numeric(10,2) check (compare_at_price is null or compare_at_price > base_price),
  discount_percent smallint generated always as (
    case when compare_at_price is not null and compare_at_price > base_price
         then round((1 - base_price / compare_at_price) * 100)::smallint end
  ) stored,
  status           public.product_status not null default 'draft',
  is_featured      boolean not null default false,
  specs            jsonb not null default '{}'::jsonb,
  meta_title       text,
  meta_description text,
  sales_count      integer not null default 0 check (sales_count >= 0),
  is_demo          boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index products_listing_idx  on public.products (status, gender, category_id);
create index products_newest_idx   on public.products (created_at desc) where status = 'active';
create index products_popular_idx  on public.products (sales_count desc) where status = 'active';
create index products_name_trgm_idx on public.products
  using gin ((name_ar || ' ' || coalesce(name_en, '')) extensions.gin_trgm_ops);

create table public.product_images (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  color_id   smallint references public.colors(id) on delete set null,
  path       text not null,            -- path inside the 'product-images' storage bucket
  alt_ar     text,
  sort_order integer not null default 0,
  is_primary boolean not null default false
);
create index product_images_product_idx on public.product_images (product_id, sort_order);
create unique index product_images_one_primary on public.product_images (product_id) where is_primary;

create table public.product_variants (
  id             uuid primary key default gen_random_uuid(),
  product_id     uuid not null references public.products(id) on delete cascade,
  sku            text not null unique,
  size_id        smallint references public.sizes(id),
  color_id       smallint references public.colors(id),
  price_override numeric(10,2) check (price_override is null or price_override >= 0),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  unique nulls not distinct (product_id, size_id, color_id)
);
create index product_variants_product_idx on public.product_variants (product_id);

create table public.inventory (
  variant_id          uuid primary key references public.product_variants(id) on delete cascade,
  quantity            integer not null default 0 check (quantity >= 0),   -- negative stock is impossible
  low_stock_threshold integer not null default 3 check (low_stock_threshold >= 0),
  updated_at          timestamptz not null default now()
);

create table public.inventory_movements (
  id             bigint generated always as identity primary key,
  variant_id     uuid not null references public.product_variants(id) on delete cascade,
  delta          integer not null check (delta <> 0),
  quantity_after integer not null check (quantity_after >= 0),
  reason         public.movement_reason not null,
  order_id       uuid,                  -- FK added in 0003 (orders is created later)
  note           text,
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index inventory_movements_variant_idx on public.inventory_movements (variant_id, created_at desc);

-- ---------- marketing content ----------
create table public.collections (
  id             uuid primary key default gen_random_uuid(),
  slug           text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title_ar       text not null,
  title_en       text,
  description_ar text,
  image_path     text,
  is_featured    boolean not null default false,
  is_active      boolean not null default true,
  sort_order     integer not null default 0,
  is_demo        boolean not null default false
);
create table public.collection_products (
  collection_id uuid not null references public.collections(id) on delete cascade,
  product_id    uuid not null references public.products(id) on delete cascade,
  sort_order    integer not null default 0,
  primary key (collection_id, product_id)
);
create table public.banners (
  id           uuid primary key default gen_random_uuid(),
  placement    text not null check (placement in ('hero','promo','strip')),
  title_ar     text,
  subtitle_ar  text,
  cta_label_ar text,
  link_url     text,
  image_path   text,
  sort_order   integer not null default 0,
  is_active    boolean not null default true,
  starts_at    timestamptz,
  ends_at      timestamptz,
  is_demo      boolean not null default false
);
