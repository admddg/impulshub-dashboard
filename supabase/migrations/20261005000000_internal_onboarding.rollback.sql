-- Rollback for internal onboarding v1. Existing client records are preserved.
set local lock_timeout = '5s';
drop function if exists public.create_internal_onboarding(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,jsonb);
drop function if exists public.link_internal_onboarding_user(uuid, uuid);
drop table if exists public.internal_onboarding_audit;
drop table if exists public.internal_onboarding_users;
drop table if exists public.internal_onboardings;
do $fn$
begin
  if exists (select 1 from public.clients_base where ghl_location_id is null) then
    raise exception 'ROLLBACK_BLOCKED_GHL_LOCATION_NULLS';
  end if;
  alter table public.clients_base alter column ghl_location_id set not null;
end
$fn$;
