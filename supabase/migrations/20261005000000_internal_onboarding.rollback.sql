-- Rollback for internal onboarding v1. Existing client records are preserved.
set local lock_timeout = '5s';
drop function if exists public.create_internal_onboarding(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,jsonb);
drop table if exists public.internal_onboarding_users;
drop table if exists public.internal_onboardings;
alter table public.clients_base alter column ghl_location_id set not null;
