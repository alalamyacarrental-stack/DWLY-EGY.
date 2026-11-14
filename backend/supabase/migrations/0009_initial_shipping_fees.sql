-- 0009_initial_shipping_fees.sql
-- Initial owner-approved delivery fees. Existing custom fees are preserved.
-- These rows remain editable by admins through the existing shipping_zones RLS policy.
update public.shipping_zones
   set fee = coalesce(fee, case name_en when 'Cairo' then 60 when 'Giza' then 75 end),
       is_available = true
 where name_en in ('Cairo', 'Giza');
