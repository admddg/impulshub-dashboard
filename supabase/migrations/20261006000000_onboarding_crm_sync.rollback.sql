-- Rollback for 20261006000000_onboarding_crm_sync.sql.
-- It removes only synchronization automation and restores the prior CRM read
-- boundary. It intentionally retains crm.tenants, crm.profiles and
-- crm.tenant_memberships backfill rows: deleting them could remove baseline or
-- user-created CRM data, so cleanup must be an separately audited operation.
set local lock_timeout = '5s';

drop trigger if exists crm_sync_membership_after_client_user_change on public.client_users;
drop trigger if exists crm_sync_profile_after_auth_insert on auth.users;
drop trigger if exists crm_sync_tenant_after_client_insert on public.clients_base;

drop function if exists crm.sync_membership_from_client_user();
drop function if exists crm.sync_profile_from_auth_user();
drop function if exists crm.sync_tenant_from_client();

create or replace function crm.is_member(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(
    exists (
      select 1
        from public.client_users cu
       where cu.client_id = p_tenant_id
         and cu.user_id = auth.uid()
         and cu.is_active = true
    ),
    false
  )
$fn$;
revoke all on function crm.is_member(uuid) from public, anon, authenticated;
grant execute on function crm.is_member(uuid) to authenticated, service_role;
