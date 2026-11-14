-- 0001_foundation.sql : private schema, extensions, enums
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated, service_role;

create extension if not exists pg_trgm with schema extensions;

create type public.app_role        as enum ('admin', 'staff');
create type public.product_gender  as enum ('men', 'women', 'unisex');
create type public.product_status  as enum ('draft', 'active', 'archived');
create type public.order_status    as enum ('pending','confirmed','processing','shipped','out_for_delivery','delivered','cancelled','refunded');
create type public.payment_method  as enum ('cod', 'online');
create type public.payment_status  as enum ('unpaid','pending','paid','failed','refunded','partially_refunded');
create type public.discount_type   as enum ('percent', 'fixed');
create type public.movement_reason as enum ('initial','purchase','sale','return','adjustment','cancellation','damaged');
create type public.review_status   as enum ('pending', 'approved', 'rejected');
