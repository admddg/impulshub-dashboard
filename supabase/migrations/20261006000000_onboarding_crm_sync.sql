-- Incremental bridge from onboarding's public source-of-truth into the CRM.
--
-- This migration is deliberately additive: public.client_users remains the
-- authority for product roles and CRM membership is a synchronized projection.
-- All writes are idempotent and run in the same transaction as the source write.
set local lock_timeout = '5s';

-- Fail closed before any backfill if a role vocabulary drifted.
do $guard$
begin
  if exists (
    select 1
      from public.client_users cu
     where pg_catalog.lower(cu.role) not in
       ('owner', 'admin', 'manager', 'integration', 'attendant', 'viewer', 'agency')
  ) then
    raise exception 'unsupported public.client_users role for CRM onboarding sync';
  end if;
end
$guard$;

-- Existing clients: reconcile by the source primary key, never insert a second
-- tenant for an already-known client.
insert into crm.tenants (id, slug, name, status, created_at)
select
  cb.id,
  coalesce(
    nullif(pg_catalog.lower(pg_catalog.btrim(cb.client_slug)), ''),
    'client-' || cb.id::text
  ),
  pg_catalog.btrim(cb.client_name),
  case pg_catalog.lower(cb.status)
    when 'active' then 'active'
    when 'paused' then 'paused'
    when 'archived' then 'archived'
    else 'paused'
  end,
  coalesce(cb.created_at, pg_catalog.now())
from public.clients_base cb
where pg_catalog.btrim(coalesce(cb.client_name, '')) <> ''
on conflict (id) do update
set slug = excluded.slug,
    name = excluded.name,
    status = excluded.status;

-- All current Auth identities receive a CRM profile. Metadata is only a display
-- convenience; authorization never depends on it.
insert into crm.profiles (id, display_name, created_at)
select
  u.id,
  coalesce(
    nullif(pg_catalog.btrim(u.raw_user_meta_data ->> 'full_name'), ''),
    nullif(pg_catalog.btrim(u.raw_user_meta_data ->> 'name'), ''),
    nullif(pg_catalog.btrim(u.email), '')
  ),
  coalesce(u.created_at, pg_catalog.now())
from auth.users u
on conflict (id) do update
set display_name = coalesce(crm.profiles.display_name, excluded.display_name);

-- Existing onboarding memberships, with the legacy agency alias mapped to the
-- CRM's compatible admin role. No public.client_users role is rewritten.
insert into crm.tenant_memberships (id, tenant_id, profile_id, role, status, created_at)
select
  cu.id,
  cu.client_id,
  cu.user_id,
  case pg_catalog.lower(cu.role)
    when 'owner' then 'owner'
    when 'admin' then 'admin'
    when 'manager' then 'manager'
    when 'integration' then 'integration'
    when 'attendant' then 'attendant'
    when 'viewer' then 'viewer'
    when 'agency' then 'admin'
  end,
  case when cu.is_active then 'active' else 'suspended' end,
  coalesce(cu.created_at, pg_catalog.now())
from public.client_users cu
join crm.tenants t on t.id = cu.client_id
join crm.profiles p on p.id = cu.user_id
on conflict (tenant_id, profile_id) do update
set role = excluded.role,
    status = excluded.status;

create or replace function crm.sync_tenant_from_client()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  insert into crm.tenants (id, slug, name, status, created_at)
  values (
    new.id,
    coalesce(
      nullif(pg_catalog.lower(pg_catalog.btrim(new.client_slug)), ''),
      'client-' || new.id::text
    ),
    pg_catalog.btrim(new.client_name),
    case pg_catalog.lower(new.status)
      when 'active' then 'active'
      when 'paused' then 'paused'
      when 'archived' then 'archived'
      else 'paused'
    end,
    coalesce(new.created_at, pg_catalog.now())
  )
  on conflict (id) do update
  set slug = excluded.slug,
      name = excluded.name,
      status = excluded.status;
  return new;
end
$fn$;

create or replace function crm.sync_profile_from_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  insert into crm.profiles (id, display_name, created_at)
  values (
    new.id,
    coalesce(
      nullif(pg_catalog.btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(pg_catalog.btrim(new.raw_user_meta_data ->> 'name'), ''),
      nullif(pg_catalog.btrim(new.email), '')
    ),
    coalesce(new.created_at, pg_catalog.now())
  )
  on conflict (id) do update
  set display_name = coalesce(crm.profiles.display_name, excluded.display_name);
  return new;
end
$fn$;

create or replace function crm.sync_membership_from_client_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  mapped_role text;
begin
  if tg_op = 'DELETE' then
    delete from crm.tenant_memberships
     where tenant_id = old.client_id
       and profile_id = old.user_id;
    return old;
  end if;

  if tg_op = 'UPDATE'
     and (old.client_id is distinct from new.client_id
          or old.user_id is distinct from new.user_id) then
    delete from crm.tenant_memberships
     where tenant_id = old.client_id
       and profile_id = old.user_id;
  end if;

  mapped_role := case pg_catalog.lower(new.role)
    when 'owner' then 'owner'
    when 'admin' then 'admin'
    when 'manager' then 'manager'
    when 'integration' then 'integration'
    when 'attendant' then 'attendant'
    when 'viewer' then 'viewer'
    when 'agency' then 'admin'
  end;
  if mapped_role is null then
    raise exception 'unsupported public.client_users role for CRM membership sync';
  end if;

  insert into crm.tenants (id, slug, name, status, created_at)
  select cb.id,
         coalesce(
    nullif(pg_catalog.lower(pg_catalog.btrim(cb.client_slug)), ''),
    'client-' || cb.id::text
  ),
         pg_catalog.btrim(cb.client_name),
         case pg_catalog.lower(cb.status)
           when 'active' then 'active'
           when 'paused' then 'paused'
           when 'archived' then 'archived'
           else 'paused'
         end,
         coalesce(cb.created_at, pg_catalog.now())
    from public.clients_base cb
   where cb.id = new.client_id
  on conflict (id) do nothing;

  insert into crm.profiles (id, display_name, created_at)
  select u.id,
         coalesce(
           nullif(pg_catalog.btrim(u.raw_user_meta_data ->> 'full_name'), ''),
           nullif(pg_catalog.btrim(u.raw_user_meta_data ->> 'name'), ''),
           nullif(pg_catalog.btrim(u.email), '')
         ),
         coalesce(u.created_at, pg_catalog.now())
    from auth.users u
   where u.id = new.user_id
  on conflict (id) do nothing;

  insert into crm.tenant_memberships (id, tenant_id, profile_id, role, status, created_at)
  values (
    new.id,
    new.client_id,
    new.user_id,
    mapped_role,
    case when new.is_active then 'active' else 'suspended' end,
    coalesce(new.created_at, pg_catalog.now())
  )
  on conflict (tenant_id, profile_id) do update
  set role = excluded.role,
      status = excluded.status;
  return new;
end
$fn$;

revoke all on function crm.sync_tenant_from_client() from public, anon, authenticated;
revoke all on function crm.sync_profile_from_auth_user() from public, anon, authenticated;
revoke all on function crm.sync_membership_from_client_user() from public, anon, authenticated;

drop trigger if exists crm_sync_tenant_after_client_insert on public.clients_base;
create trigger crm_sync_tenant_after_client_insert
after insert or update of client_slug, client_name, status on public.clients_base
for each row execute function crm.sync_tenant_from_client();

drop trigger if exists crm_sync_profile_after_auth_insert on auth.users;
create trigger crm_sync_profile_after_auth_insert
after insert on auth.users
for each row execute function crm.sync_profile_from_auth_user();

drop trigger if exists crm_sync_membership_after_client_user_change on public.client_users;
create trigger crm_sync_membership_after_client_user_change
after insert or update of client_id, user_id, role, is_active or delete on public.client_users
for each row execute function crm.sync_membership_from_client_user();

-- The legacy viewer is intentionally not a CRM data reader. This is the
-- smallest compatible boundary: client_users stays authoritative, attendants
-- remain eligible for operational CRM reads, and existing public financial
-- contracts are untouched.
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
         and pg_catalog.lower(cu.role) <> 'viewer'
    ),
    false
  )
$fn$;
revoke all on function crm.is_member(uuid) from public, anon, authenticated;
grant execute on function crm.is_member(uuid) to authenticated, service_role;
