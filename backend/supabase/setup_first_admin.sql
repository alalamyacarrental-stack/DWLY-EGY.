-- DWLY EGY — Assign the first store administrator.
-- Run this manually in Supabase SQL Editor AFTER creating and email-confirming
-- the owner's account through the storefront. Replace the email below.
-- This script does not expose or use a service-role key in the frontend.

do $$
declare
  v_email text := lower(btrim('REPLACE_WITH_YOUR_LOGIN_EMAIL'));
  v_user_id uuid;
begin
  if v_email = '' or v_email = 'replace_with_your_login_email' then
    raise exception 'Replace REPLACE_WITH_YOUR_LOGIN_EMAIL with the confirmed account email first.';
  end if;

  select u.id into v_user_id
  from auth.users u
  where lower(u.email) = v_email
  limit 1;

  if v_user_id is null then
    raise exception 'No Auth user found for %. Create the account and confirm its email first.', v_email;
  end if;

  insert into public.roles (user_id, role)
  values (v_user_id, 'admin')
  on conflict (user_id) do update set role = 'admin';
end $$;

-- Verify the assignment. This returns only the email and role.
select u.email, r.role
from public.roles r
join auth.users u on u.id = r.user_id
where lower(u.email) = lower('REPLACE_WITH_YOUR_LOGIN_EMAIL');
