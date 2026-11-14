-- Boolean-only, RLS-enforced public stock projection.
-- The public-facing object stores no quantities or stock movement details.
create table public.variant_availability (
  variant_id uuid primary key references public.product_variants(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  in_stock boolean not null
);
alter table public.variant_availability enable row level security;
revoke all on public.variant_availability from public, anon, authenticated;
grant select on public.variant_availability to anon, authenticated;
create policy variant_availability_public_read
  on public.variant_availability for select to anon, authenticated
  using (exists (
    select 1 from public.products p
    where p.id = product_id and p.status = 'active' and not p.is_demo
  ));

create or replace function private.sync_variant_availability(p_variant_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
begin
  delete from public.variant_availability where variant_id = p_variant_id;
  insert into public.variant_availability (variant_id, product_id, in_stock)
  select v.id, v.product_id, (i.quantity > 0)
  from public.product_variants v
  join public.products p on p.id = v.product_id
  join public.inventory i on i.variant_id = v.id
  where v.id = p_variant_id and v.is_active
    and p.status = 'active' and not p.is_demo;
end;
$$;
revoke all on function private.sync_variant_availability(uuid) from public, anon, authenticated;

create or replace function private.trg_sync_inventory_availability()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if tg_op = 'DELETE' then
    perform private.sync_variant_availability(old.variant_id);
    return old;
  end if;
  perform private.sync_variant_availability(new.variant_id);
  if tg_op = 'UPDATE' and old.variant_id is distinct from new.variant_id then
    perform private.sync_variant_availability(old.variant_id);
  end if;
  return new;
end;
$$;
revoke all on function private.trg_sync_inventory_availability() from public, anon, authenticated;

create or replace function private.trg_sync_variant_availability()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if tg_op = 'DELETE' then
    delete from public.variant_availability where variant_id = old.id;
    return old;
  end if;
  perform private.sync_variant_availability(new.id);
  return new;
end;
$$;
revoke all on function private.trg_sync_variant_availability() from public, anon, authenticated;

create or replace function private.trg_sync_product_availability()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_id uuid;
begin
  for v_id in select id from public.product_variants where product_id = new.id loop
    perform private.sync_variant_availability(v_id);
  end loop;
  return new;
end;
$$;
revoke all on function private.trg_sync_product_availability() from public, anon, authenticated;

drop trigger if exists inventory_availability_sync on public.inventory;
drop trigger if exists variant_availability_sync on public.product_variants;
drop trigger if exists product_availability_sync on public.products;

create trigger inventory_availability_sync
  after insert or update of quantity, variant_id or delete on public.inventory
  for each row execute function private.trg_sync_inventory_availability();
create trigger variant_availability_sync
  after insert or update of product_id, is_active or delete on public.product_variants
  for each row execute function private.trg_sync_variant_availability();
create trigger product_availability_sync
  after update of status, is_demo on public.products
  for each row execute function private.trg_sync_product_availability();

insert into public.variant_availability (variant_id, product_id, in_stock)
select v.id, v.product_id, (i.quantity > 0)
from public.product_variants v
join public.products p on p.id = v.product_id
join public.inventory i on i.variant_id = v.id
where v.is_active and p.status = 'active' and not p.is_demo
on conflict (variant_id) do update
set product_id = excluded.product_id, in_stock = excluded.in_stock;

drop view if exists public.variant_stock;
create view public.variant_stock with (security_invoker = true) as
select variant_id, product_id, in_stock from public.variant_availability;
grant select on public.variant_stock to anon, authenticated;
comment on table public.variant_availability is
  'RLS-protected boolean-only projection; deliberately stores no inventory quantities.';
comment on view public.variant_stock is
  'Security-invoker view over RLS-protected boolean-only variant availability.';
