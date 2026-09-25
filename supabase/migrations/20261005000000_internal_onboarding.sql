-- Internal onboarding v1: one authenticated agency submit, no secrets.
set local lock_timeout = '5s';

alter table public.clients_base alter column ghl_location_id drop not null;

create table public.internal_onboardings (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  client_id uuid not null unique references public.clients_base(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  legal_name text not null,
  cnpj text not null,
  legal_email text not null,
  legal_phone text,
  address_line text not null,
  address_number text not null,
  address_complement text,
  neighborhood text not null,
  city text not null,
  state text not null check (length(state) = 2),
  postal_code text not null,
  meta_business_id text,
  meta_ad_account_id text,
  meta_page_id text,
  google_manager_customer_id text,
  google_ads_customer_id text,
  ga4_measurement_id text,
  stevo_instance_id text,
  status text not null default 'received' check (status in ('received', 'ready_for_activation', 'activated', 'cancelled')),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now()
);

create table public.internal_onboarding_users (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  onboarding_id uuid not null references public.internal_onboardings(id) on delete cascade,
  name text not null,
  email text not null,
  profile text not null check (profile in ('gestao', 'atendimento')),
  auth_user_id uuid references auth.users(id) on delete set null,
  invite_status text not null default 'pending' check (invite_status in ('linked', 'pending_auth')),
  created_at timestamptz not null default pg_catalog.now(),
  unique (onboarding_id, email)
);

create table public.internal_onboarding_audit (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  onboarding_id uuid not null references public.internal_onboardings(id) on delete cascade,
  client_id uuid not null references public.clients_base(id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  action text not null check (action in ('created', 'invite_sent')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default pg_catalog.now()
);

alter table public.internal_onboardings enable row level security;
alter table public.internal_onboarding_users enable row level security;
alter table public.internal_onboarding_audit enable row level security;
revoke all on table public.internal_onboardings, public.internal_onboarding_users, public.internal_onboarding_audit from public, anon, authenticated;
grant select on table public.internal_onboardings, public.internal_onboarding_users, public.internal_onboarding_audit to authenticated;
create policy internal_onboardings_agency_select on public.internal_onboardings
  for select to authenticated using (exists (select 1 from public.client_users cu where cu.user_id = (select auth.uid()) and cu.role = 'agency' and cu.is_active));
create policy internal_onboarding_users_agency_select on public.internal_onboarding_users
  for select to authenticated using (exists (select 1 from public.client_users cu where cu.user_id = (select auth.uid()) and cu.role = 'agency' and cu.is_active));
create policy internal_onboarding_audit_agency_select on public.internal_onboarding_audit
  for select to authenticated using (exists (select 1 from public.client_users cu where cu.user_id = (select auth.uid()) and cu.role = 'agency' and cu.is_active));

create or replace function public.create_internal_onboarding(
  p_client_name text,
  p_client_slug text,
  p_legal_name text,
  p_cnpj text,
  p_legal_email text,
  p_legal_phone text,
  p_address_line text,
  p_address_number text,
  p_address_complement text,
  p_neighborhood text,
  p_city text,
  p_state text,
  p_postal_code text,
  p_niche text,
  p_timezone text,
  p_meta_business_id text,
  p_meta_ad_account_id text,
  p_meta_page_id text,
  p_google_manager_customer_id text,
  p_google_ads_customer_id text,
  p_ga4_measurement_id text,
  p_stevo_instance_id text,
  p_users jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := (select auth.uid());
  v_client uuid;
  v_onboarding uuid;
  v_pending integer := 0;
  v_gestao integer;
  v_atendimento integer;
  v_user record;
  v_auth_user uuid;
  v_role text;
begin
  if v_actor is null or not exists (
    select 1 from public.client_users cu where cu.user_id = v_actor and cu.role = 'agency' and cu.is_active
  ) then raise exception 'ONBOARDING_FORBIDDEN'; end if;
  if p_users is null or jsonb_typeof(p_users) <> 'array' then raise exception 'ONBOARDING_USERS_REQUIRED'; end if;
  if jsonb_array_length(p_users) > 50 then raise exception 'ONBOARDING_TOO_MANY_USERS'; end if;
  select count(*) into v_gestao from jsonb_to_recordset(p_users) as u(name text, email text, role text) where u.role = 'gestao' and btrim(u.name) <> '' and btrim(u.email) <> '';
  select count(*) into v_atendimento from jsonb_to_recordset(p_users) as u(name text, email text, role text) where u.role = 'atendimento' and btrim(u.name) <> '' and btrim(u.email) <> '';
  if v_gestao < 1 or v_atendimento < 1 then raise exception 'ONBOARDING_PROFILES_REQUIRED'; end if;
  if exists (select 1 from public.clients_base where client_slug = lower(btrim(p_client_slug))) then raise exception 'ONBOARDING_SLUG_EXISTS'; end if;
  if p_client_name is null or btrim(p_client_name) = '' or p_legal_name is null or btrim(p_legal_name) = '' or p_cnpj is null or btrim(p_cnpj) = '' then raise exception 'ONBOARDING_LEGAL_REQUIRED'; end if;

  insert into public.clients_base (ghl_location_id, client_name, client_slug, timezone, niche, onboarding_status, status, owner_name, owner_email, owner_phone, meta_business_id, meta_ad_account_id, meta_page_id, google_manager_customer_id, google_ads_customer_id, ga4_measurement_id, tracking_status, tracking_ready, meta_ready, google_ads_ready, sync_ready)
  values (null, btrim(p_client_name), lower(btrim(p_client_slug)), coalesce(nullif(btrim(p_timezone), ''), 'America/Sao_Paulo'), coalesce(nullif(btrim(p_niche), ''), 'odontologia'), 'received', 'active', btrim(p_legal_name), lower(btrim(p_legal_email)), nullif(btrim(coalesce(p_legal_phone, '')), ''), p_meta_business_id, p_meta_ad_account_id, p_meta_page_id, p_google_manager_customer_id, p_google_ads_customer_id, p_ga4_measurement_id, 'pending_config', false, false, false, false)
  returning id into v_client;

  insert into public.internal_onboardings (client_id, created_by, legal_name, cnpj, legal_email, legal_phone, address_line, address_number, address_complement, neighborhood, city, state, postal_code, meta_business_id, meta_ad_account_id, meta_page_id, google_manager_customer_id, google_ads_customer_id, ga4_measurement_id, stevo_instance_id)
  values (v_client, v_actor, btrim(p_legal_name), btrim(p_cnpj), lower(btrim(p_legal_email)), nullif(btrim(coalesce(p_legal_phone, '')), ''), btrim(p_address_line), btrim(p_address_number), nullif(btrim(coalesce(p_address_complement, '')), ''), btrim(p_neighborhood), btrim(p_city), upper(btrim(p_state)), btrim(p_postal_code), p_meta_business_id, p_meta_ad_account_id, p_meta_page_id, p_google_manager_customer_id, p_google_ads_customer_id, p_ga4_measurement_id, p_stevo_instance_id)
  returning id into v_onboarding;

  for v_user in select * from jsonb_to_recordset(p_users) as u(name text, email text, role text) loop
    select au.id into v_auth_user from auth.users au where lower(au.email) = lower(btrim(v_user.email)) limit 1;
    v_role := case v_user.role when 'gestao' then 'manager' else 'attendant' end;
    insert into public.internal_onboarding_users (onboarding_id, name, email, profile, auth_user_id, invite_status)
    values (v_onboarding, btrim(v_user.name), lower(btrim(v_user.email)), v_user.role, v_auth_user, case when v_auth_user is null then 'pending_auth' else 'linked' end);
    if v_auth_user is null then v_pending := v_pending + 1;
    else insert into public.client_users (client_id, user_id, role, is_active) values (v_client, v_auth_user, v_role, true) on conflict (client_id, user_id) do update set role = excluded.role, is_active = true;
    end if;
  end loop;

  insert into public.internal_onboarding_audit (onboarding_id, client_id, actor_id, action, metadata)
  values (v_onboarding, v_client, v_actor, 'created', jsonb_build_object('user_count', jsonb_array_length(p_users), 'pending_auth_users', v_pending));

  return jsonb_build_object('client_id', v_client, 'onboarding_id', v_onboarding, 'pending_auth_users', v_pending);
end
$fn$;

revoke all on function public.create_internal_onboarding(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.create_internal_onboarding(text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,jsonb) to authenticated;

create or replace function public.link_internal_onboarding_user(p_onboarding_user_id uuid, p_auth_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_actor uuid := (select auth.uid());
  v_client uuid;
  v_role text;
begin
  if v_actor is null or not exists (
    select 1 from public.client_users cu where cu.user_id = v_actor and cu.role = 'agency' and cu.is_active
  ) then raise exception 'ONBOARDING_FORBIDDEN'; end if;
  select io.client_id, case iu.profile when 'gestao' then 'manager' else 'attendant' end
    into v_client, v_role
    from public.internal_onboarding_users iu
    join public.internal_onboardings io on io.id = iu.onboarding_id
   where iu.id = p_onboarding_user_id and iu.auth_user_id is null and iu.invite_status = 'pending_auth';
  if v_client is null then raise exception 'ONBOARDING_USER_NOT_PENDING'; end if;
  update public.internal_onboarding_users
     set auth_user_id = p_auth_user_id, invite_status = 'linked'
   where id = p_onboarding_user_id;
  insert into public.client_users (client_id, user_id, role, is_active)
  values (v_client, p_auth_user_id, v_role, true)
  on conflict (client_id, user_id) do update set role = excluded.role, is_active = true;
  insert into public.internal_onboarding_audit (onboarding_id, client_id, actor_id, action, metadata)
  select iu.onboarding_id, v_client, v_actor, 'invite_sent', jsonb_build_object('user_id', p_auth_user_id)
    from public.internal_onboarding_users iu where iu.id = p_onboarding_user_id;
end
$fn$;

revoke all on function public.link_internal_onboarding_user(uuid, uuid) from public, anon, authenticated;
grant execute on function public.link_internal_onboarding_user(uuid, uuid) to authenticated;

comment on table public.internal_onboardings is 'Intake interno auditável. Nunca armazenar senha, token, refresh token ou segredo.';
comment on table public.internal_onboarding_users is 'Contas individuais do cliente: vincula usuários já existentes; pending_auth aguarda convite pelo fluxo de Auth.';
comment on table public.internal_onboarding_audit is 'Auditoria de ações do onboarding. Actor explícito; nunca armazenar credenciais ou tokens.';
