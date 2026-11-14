-- 0006_refunds.sql : refunds are their own flow. Requesting a refund changes NOTHING about the order or payment;
-- only a COMPLETED refund (provider-verified, amount-checked, or manually confirmed for COD) changes payment_status,
-- and a full refund of a delivered order is the only way an order becomes 'refunded'.
create type public.refund_status as enum ('requested', 'completed', 'failed');

create table public.refunds (
  id                  uuid primary key default gen_random_uuid(),
  order_id            uuid not null references public.orders(id) on delete restrict,
  payment_id          uuid not null references public.payments(id) on delete restrict,
  amount              numeric(10,2) not null check (amount > 0),
  reason              text,
  status              public.refund_status not null default 'requested',
  provider_refund_ref text,
  requested_by        uuid references auth.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  completed_at        timestamptz
);
create index refunds_order_idx on public.refunds (order_id);

alter table public.refunds enable row level security;
grant select on public.refunds to authenticated;
create policy refunds_select on public.refunds for select to authenticated
  using (private.owns_order(order_id) or private.is_staff());

create or replace function private.finish_refund(p_refund_id uuid, p_provider_ref text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_r public.refunds; v_pay public.payments; v_o public.orders; v_done numeric(10,2); v_state public.payment_status;
begin
  select * into v_r from public.refunds where id = p_refund_id for update;
  if not found then raise exception 'REFUND_NOT_FOUND'; end if;
  if v_r.status <> 'requested' then raise exception 'REFUND_NOT_PENDING'; end if;
  select * into v_pay from public.payments where id = v_r.payment_id for update;
  select * into v_o   from public.orders   where id = v_r.order_id   for update;
  select coalesce(sum(amount), 0) into v_done from public.refunds where payment_id = v_pay.id and status = 'completed';
  if v_done + v_r.amount > v_pay.amount then raise exception 'REFUND_EXCEEDS_PAYMENT'; end if;
  update public.refunds set status = 'completed', provider_refund_ref = p_provider_ref, completed_at = now() where id = v_r.id;
  v_done := v_done + v_r.amount;
  v_state := case when v_done = v_pay.amount then 'refunded'::public.payment_status else 'partially_refunded'::public.payment_status end;
  update public.payments set status = v_state where id = v_pay.id;
  update public.orders   set payment_status = v_state where id = v_o.id;
  if v_state = 'refunded' and v_o.status = 'delivered' then
    update public.orders set status = 'refunded' where id = v_o.id;
    insert into public.order_status_history (order_id, from_status, to_status, note)
    values (v_o.id, 'delivered', 'refunded', 'full refund completed');
  end if;
end $$;

-- Step 1 (admin): record the intention. Validates the amount against what is still refundable.
create or replace function public.admin_request_refund(p_order_id uuid, p_amount numeric, p_reason text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_pay public.payments; v_committed numeric(10,2); v_id uuid;
begin
  if not private.is_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_pay from public.payments where order_id = p_order_id order by created_at desc limit 1 for update;
  if not found then raise exception 'PAYMENT_NOT_FOUND'; end if;
  if v_pay.status not in ('paid', 'partially_refunded') then raise exception 'PAYMENT_NOT_REFUNDABLE'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then raise exception 'INVALID_AMOUNT'; end if;
  select coalesce(sum(amount), 0) into v_committed from public.refunds where payment_id = v_pay.id and status in ('requested', 'completed');
  if v_committed + p_amount > v_pay.amount then raise exception 'REFUND_EXCEEDS_PAYMENT'; end if;
  insert into public.refunds (order_id, payment_id, amount, reason, requested_by)
  values (p_order_id, v_pay.id, p_amount, nullif(btrim(p_reason), ''), auth.uid()) returning id into v_id;
  return v_id;
end $$;

-- Step 2a (COD only): cash was handed back manually.
create or replace function public.admin_confirm_manual_refund(p_refund_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_method public.payment_method;
begin
  if not private.is_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select p.method into v_method from public.refunds r join public.payments p on p.id = r.payment_id where r.id = p_refund_id;
  if v_method is null then raise exception 'REFUND_NOT_FOUND'; end if;
  if v_method <> 'cod' then raise exception 'ONLINE_REFUND_MUST_GO_THROUGH_PROVIDER'; end if;
  perform private.finish_refund(p_refund_id, coalesce(nullif(btrim(p_note), ''), 'manual'));
end $$;

-- Releases the refundable balance of a request that was abandoned or rejected.
create or replace function public.admin_cancel_refund(p_refund_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.refunds set status = 'failed' where id = p_refund_id and status = 'requested';
  if not found then raise exception 'REFUND_NOT_PENDING'; end if;
end $$;

-- Step 2b (online): provider-confirmed result, delivered by the edge function after signature verification.
create or replace function public.record_refund_event(
  p_provider text, p_provider_txn_id text, p_refund_id uuid, p_amount numeric,
  p_status text, p_signature_verified boolean, p_raw jsonb default '{}'::jsonb
) returns text language plpgsql security definer set search_path = '' as $$
declare v_r public.refunds; v_method public.payment_method; v_tx uuid;
begin
  if not coalesce(p_signature_verified, false) then raise exception 'SIGNATURE_NOT_VERIFIED'; end if;
  if p_status not in ('success', 'failed') then raise exception 'INVALID_STATUS'; end if;
  select * into v_r from public.refunds where id = p_refund_id for update;
  if not found then raise exception 'REFUND_NOT_FOUND'; end if;
  select method into v_method from public.payments where id = v_r.payment_id;
  if v_method <> 'online' then raise exception 'NOT_AN_ONLINE_PAYMENT'; end if;
  insert into public.payment_transactions (payment_id, provider, provider_txn_id, event_type, amount, status, signature_verified, raw_payload)
  values (v_r.payment_id, p_provider, p_provider_txn_id, 'refund', p_amount, p_status, true, coalesce(p_raw, '{}'::jsonb))
  on conflict (provider, provider_txn_id, event_type) do nothing returning id into v_tx;
  if v_tx is null then return 'duplicate'; end if;
  if p_status = 'failed' then
    update public.refunds set status = 'failed' where id = v_r.id and status = 'requested';
    return 'processed';
  end if;
  if p_amount is distinct from v_r.amount then raise exception 'AMOUNT_MISMATCH'; end if;   -- rolls back the transaction row too
  perform private.finish_refund(v_r.id, p_provider_txn_id);
  return 'processed';
end $$;

revoke execute on function private.finish_refund(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_request_refund(uuid, numeric, text)  to authenticated;
grant execute on function public.admin_confirm_manual_refund(uuid, text)    to authenticated;
grant execute on function public.admin_cancel_refund(uuid)                  to authenticated;
grant execute on function public.record_refund_event(text, text, uuid, numeric, text, boolean, jsonb) to service_role;

-- Explicitly lock down the new RPC surface (independent of migration-owner defaults).
revoke execute on function private.finish_refund(uuid, text) from public, anon, authenticated;
revoke execute on function public.admin_request_refund(uuid, numeric, text) from public, anon;
revoke execute on function public.admin_confirm_manual_refund(uuid, text) from public, anon;
revoke execute on function public.admin_cancel_refund(uuid) from public, anon;
revoke execute on function public.record_refund_event(text, text, uuid, numeric, text, boolean, jsonb) from public, anon, authenticated;
