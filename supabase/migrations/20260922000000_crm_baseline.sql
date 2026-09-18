-- IMP-203: clean CRM baseline in the dedicated schema.
-- Existing public/auth objects are dependencies only; this migration does not create or mutate them.

set local lock_timeout = '5s';

create schema crm;

revoke all on schema crm from public;
grant usage on schema crm to authenticated, service_role;

create table crm.tenants (
  id uuid primary key references public.clients_base(id) on delete restrict,
  slug text not null unique check (slug = pg_catalog.lower(slug) and pg_catalog.length(slug) between 3 and 80),
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) > 0),
  status text not null default 'active' check (status in ('active', 'paused', 'archived')),
  created_at timestamptz not null default pg_catalog.now()
);

create table crm.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  display_name text,
  created_at timestamptz not null default pg_catalog.now()
);

create table crm.tenant_memberships (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references crm.tenants(id) on delete restrict,
  profile_id uuid not null references crm.profiles(id) on delete restrict,
  role text not null check (role in ('owner', 'admin', 'manager', 'attendant', 'integration', 'viewer')),
  status text not null default 'active' check (status in ('active', 'suspended', 'removed')),
  created_at timestamptz not null default pg_catalog.now(),
  unique (tenant_id, profile_id)
);

create table crm.global_pipeline_versions (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  version_no integer not null unique check (version_no > 0),
  status text not null check (status in ('draft', 'active', 'retired')),
  published_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  check (status <> 'active' or published_at is not null)
);

create unique index global_pipeline_versions_one_active
  on crm.global_pipeline_versions (status)
  where status = 'active';

create table crm.global_pipeline_stages (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  pipeline_version_id uuid not null references crm.global_pipeline_versions(id) on delete restrict,
  code text not null check (code in ('lead', 'atendimento', 'agendado', 'compareceu', 'ganho', 'perdido')),
  label text not null check (pg_catalog.length(pg_catalog.btrim(label)) > 0),
  position smallint not null check (position between 1 and 6),
  is_terminal boolean not null default false,
  created_at timestamptz not null default pg_catalog.now(),
  unique (pipeline_version_id, code),
  unique (pipeline_version_id, position),
  unique (pipeline_version_id, label),
  check ((code in ('ganho', 'perdido')) = is_terminal)
);

create table crm.canonical_loss_reasons (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  code text not null unique check (code = pg_catalog.lower(code) and pg_catalog.length(code) > 0),
  label text not null unique check (pg_catalog.length(pg_catalog.btrim(label)) > 0),
  requires_note boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now()
);

create table crm.contacts (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references crm.tenants(id) on delete restrict,
  full_name text not null check (pg_catalog.length(pg_catalog.btrim(full_name)) > 0),
  email text,
  phone_normalized text,
  default_owner_profile_id uuid,
  status text not null default 'active' check (status in ('active', 'archived')),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  check (email is null or pg_catalog.strpos(email, '@') > 1),
  check (phone_normalized is not null or email is not null),
  unique (tenant_id, id),
  foreign key (tenant_id, default_owner_profile_id)
    references crm.tenant_memberships (tenant_id, profile_id) on delete restrict
);

create index contacts_tenant_id_idx on crm.contacts (tenant_id);

create table crm.contact_identities (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references crm.tenants(id) on delete restrict,
  contact_id uuid not null,
  kind text not null check (kind in ('phone', 'jid', 'lid', 'email', 'external')),
  value_normalized text not null check (pg_catalog.length(pg_catalog.btrim(value_normalized)) > 0),
  provider text,
  is_verified boolean not null default false,
  created_at timestamptz not null default pg_catalog.now(),
  unique (tenant_id, id),
  unique (tenant_id, kind, value_normalized),
  foreign key (tenant_id, contact_id)
    references crm.contacts (tenant_id, id) on delete restrict
);

create index contact_identities_contact_idx
  on crm.contact_identities (tenant_id, contact_id);

create table crm.opportunities (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references crm.tenants(id) on delete restrict,
  contact_id uuid not null,
  owner_profile_id uuid,
  previous_opportunity_id uuid,
  pipeline_version_id uuid not null references crm.global_pipeline_versions(id) on delete restrict,
  current_stage_id uuid not null references crm.global_pipeline_stages(id) on delete restrict,
  stage_version integer not null default 0 check (stage_version >= 0),
  title text not null check (pg_catalog.length(pg_catalog.btrim(title)) > 0),
  status text not null default 'open' check (status in ('open', 'won', 'lost')),
  opened_at timestamptz not null default pg_catalog.now(),
  closed_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  unique (tenant_id, id),
  check ((status = 'open') = (closed_at is null)),
  foreign key (tenant_id, contact_id)
    references crm.contacts (tenant_id, id) on delete restrict,
  foreign key (tenant_id, owner_profile_id)
    references crm.tenant_memberships (tenant_id, profile_id) on delete restrict,
  foreign key (tenant_id, previous_opportunity_id)
    references crm.opportunities (tenant_id, id) on delete restrict
);

create index opportunities_tenant_contact_idx
  on crm.opportunities (tenant_id, contact_id);
create index opportunities_open_recent_idx
  on crm.opportunities (tenant_id, contact_id, created_at desc)
  where status = 'open';

create table crm.activities (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references crm.tenants(id) on delete restrict,
  contact_id uuid,
  opportunity_id uuid,
  actor_profile_id uuid,
  raw_event_id uuid references public.stevo_events_raw(id) on delete restrict,
  kind text not null check (kind in ('message', 'note', 'call', 'form', 'system')),
  direction text check (direction in ('inbound', 'outbound', 'internal')),
  body text,
  provider_message_id text,
  sent_confirmed_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  unique (tenant_id, id),
  check (kind <> 'message' or body is not null),
  foreign key (tenant_id, contact_id)
    references crm.contacts (tenant_id, id) on delete restrict,
  foreign key (tenant_id, opportunity_id)
    references crm.opportunities (tenant_id, id) on delete restrict,
  foreign key (tenant_id, actor_profile_id)
    references crm.tenant_memberships (tenant_id, profile_id) on delete restrict
);

create unique index activities_provider_message_unique
  on crm.activities (tenant_id, provider_message_id)
  where provider_message_id is not null;

create table crm.opportunity_stage_history (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references crm.tenants(id) on delete restrict,
  opportunity_id uuid not null,
  from_stage_id uuid references crm.global_pipeline_stages(id) on delete restrict,
  to_stage_id uuid not null references crm.global_pipeline_stages(id) on delete restrict,
  transition_type text not null check (transition_type in ('automatic', 'manual', 'undo', 'correction')),
  origin text not null check (origin in ('frase_configurada', 'manual', 'integracao', 'sistema')),
  actor_profile_id uuid,
  source_activity_id uuid,
  source_rule_version_id uuid,
  reason text,
  compensates_history_id uuid,
  occurred_at timestamptz not null default pg_catalog.now(),
  created_at timestamptz not null default pg_catalog.now(),
  unique (tenant_id, id),
  unique (tenant_id, id, opportunity_id),
  foreign key (tenant_id, opportunity_id)
    references crm.opportunities (tenant_id, id) on delete restrict,
  foreign key (tenant_id, actor_profile_id)
    references crm.tenant_memberships (tenant_id, profile_id) on delete restrict,
  foreign key (tenant_id, source_activity_id)
    references crm.activities (tenant_id, id) on delete restrict,
  foreign key (tenant_id, compensates_history_id, opportunity_id)
    references crm.opportunity_stage_history (tenant_id, id, opportunity_id) on delete restrict
);

create index opportunity_stage_history_timeline_idx
  on crm.opportunity_stage_history (tenant_id, opportunity_id, occurred_at, created_at);

create unique index opportunity_stage_history_one_compensation
  on crm.opportunity_stage_history (tenant_id, compensates_history_id)
  where compensates_history_id is not null;

create table crm.opportunity_milestones (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references crm.tenants(id) on delete restrict,
  opportunity_id uuid not null,
  kind text not null check (kind in ('lead_received', 'conversation_started', 'appointment', 'attendance', 'proposal', 'sale', 'revenue')),
  origin text not null check (origin in ('frase_configurada', 'manual', 'integracao', 'sistema')),
  actor_profile_id uuid,
  evidence text,
  occurred_at timestamptz not null default pg_catalog.now(),
  created_at timestamptz not null default pg_catalog.now(),
  foreign key (tenant_id, opportunity_id)
    references crm.opportunities (tenant_id, id) on delete restrict,
  foreign key (tenant_id, actor_profile_id)
    references crm.tenant_memberships (tenant_id, profile_id) on delete restrict
);

create table crm.commercial_outcomes (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references crm.tenants(id) on delete restrict,
  opportunity_id uuid not null,
  outcome text not null check (outcome in ('won', 'lost')),
  origin text not null check (origin in ('frase_configurada', 'manual', 'integracao', 'sistema')),
  actor_profile_id uuid,
  loss_reason_id uuid references crm.canonical_loss_reasons(id) on delete restrict,
  evidence text,
  value numeric(14,2),
  value_status text not null default 'pending' check (value_status in ('pending', 'valid')),
  currency text,
  is_current boolean not null default true,
  occurred_at timestamptz not null default pg_catalog.now(),
  created_at timestamptz not null default pg_catalog.now(),
  unique (tenant_id, id),
  check ((outcome = 'lost') = (loss_reason_id is not null)),
  check (
    (value_status = 'pending' and value is null and currency is null)
    or
    (value_status = 'valid'
      and value is not null
      and value > 0
      and currency is not null
      and pg_catalog.length(pg_catalog.btrim(currency)) > 0)
  ),
  check (outcome <> 'lost' or value_status = 'pending'),
  foreign key (tenant_id, opportunity_id)
    references crm.opportunities (tenant_id, id) on delete restrict,
  foreign key (tenant_id, actor_profile_id)
    references crm.tenant_memberships (tenant_id, profile_id) on delete restrict
);

create unique index commercial_outcomes_one_current
  on crm.commercial_outcomes (tenant_id, opportunity_id)
  where is_current;

create table crm.processed_events (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references crm.tenants(id) on delete restrict,
  raw_event_id uuid not null references public.stevo_events_raw(id) on delete restrict,
  source text not null check (pg_catalog.length(pg_catalog.btrim(source)) > 0),
  external_id text not null check (pg_catalog.length(pg_catalog.btrim(external_id)) > 0),
  payload_hash text not null check (pg_catalog.length(payload_hash) >= 32),
  status text not null default 'processing' check (status in ('processing', 'processed', 'failed', 'rejected')),
  error_code text,
  processed_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  unique (tenant_id, source, external_id),
  unique (tenant_id, raw_event_id)
);

insert into crm.global_pipeline_versions (id, version_no, status, published_at, created_at)
values (
  '00000000-0000-0000-0000-000000000101', 1, 'active',
  '2026-09-22 00:00:00+00', '2026-09-22 00:00:00+00'
);

insert into crm.global_pipeline_stages
  (id, pipeline_version_id, code, label, position, is_terminal, created_at)
values
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000101', 'lead', 'Lead', 1, false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000202', '00000000-0000-0000-0000-000000000101', 'atendimento', 'Atendimento', 2, false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000203', '00000000-0000-0000-0000-000000000101', 'agendado', 'Agendado', 3, false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000204', '00000000-0000-0000-0000-000000000101', 'compareceu', 'Compareceu', 4, false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000205', '00000000-0000-0000-0000-000000000101', 'ganho', 'Ganho', 5, true, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000206', '00000000-0000-0000-0000-000000000101', 'perdido', 'Perdido', 6, true, '2026-09-22 00:00:00+00');

insert into crm.canonical_loss_reasons
  (id, code, label, requires_note, created_at)
values
  ('00000000-0000-0000-0000-000000000301', 'sem_interesse', 'Sem interesse / desistiu', false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000302', 'preco_condicao_financeira', 'Preço ou condição financeira', false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000303', 'agenda_indisponivel', 'Agenda ou disponibilidade incompatível', false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000304', 'outra_clinica_profissional', 'Escolheu outra clínica ou profissional', false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000305', 'sem_retorno', 'Sem retorno após cadência concluída', false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000306', 'nao_elegivel', 'Não elegível / sem indicação para o serviço', false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000307', 'servico_localizacao_indisponivel', 'Serviço, unidade ou localização indisponível', false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000308', 'entrada_invalida_duplicada', 'Entrada inválida ou duplicada — encerramento administrativo excluído da taxa comercial', false, '2026-09-22 00:00:00+00'),
  ('00000000-0000-0000-0000-000000000309', 'outro', 'Outro', true, '2026-09-22 00:00:00+00');

insert into crm.tenants (id, slug, name, status, created_at)
select
  cb.id,
  pg_catalog.lower(pg_catalog.btrim(cb.client_slug)),
  cb.client_name,
  case
    when pg_catalog.lower(cb.status) in ('active', 'paused', 'archived') then pg_catalog.lower(cb.status)
    else 'paused'
  end,
  '2026-09-22 00:00:00+00'::timestamptz
from public.clients_base cb
where pg_catalog.lower(cb.status) <> 'inactive'
on conflict do nothing;

insert into crm.profiles (id, created_at)
select distinct
  cu.user_id,
  '2026-09-22 00:00:00+00'::timestamptz
from public.client_users cu
join auth.users u on u.id = cu.user_id
on conflict do nothing;

do $$
begin
  if exists (
    select 1
      from public.client_users cu
     where pg_catalog.lower(cu.role) not in (
       'owner', 'admin', 'manager', 'integration', 'attendant', 'viewer', 'agency'
     )
  ) then
    raise exception 'unsupported public.client_users role for CRM membership seed';
  end if;
end
$$;

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
  '2026-09-22 00:00:00+00'::timestamptz
from public.client_users cu
join crm.tenants t on t.id = cu.client_id
join crm.profiles p on p.id = cu.user_id
on conflict do nothing;

create function crm.is_member(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
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
$$;

create function crm.reject_append_only_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'append-only table cannot be mutated: %', tg_table_name;
end;
$$;

create function crm.validate_opportunity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  stage_pipeline uuid;
  stage_code text;
  previous_contact uuid;
  previous_status text;
  previous_closed_at timestamptz;
  new_lock_key bigint;
  old_lock_key bigint;
begin
  new_lock_key := pg_catalog.hashtextextended(
    new.tenant_id::text || ':' || new.contact_id::text,
    0
  );
  if tg_op = 'UPDATE' then
    old_lock_key := pg_catalog.hashtextextended(
      old.tenant_id::text || ':' || old.contact_id::text,
      0
    );
    if old_lock_key <= new_lock_key then
      perform pg_catalog.pg_advisory_xact_lock(old_lock_key);
      if old_lock_key <> new_lock_key then
        perform pg_catalog.pg_advisory_xact_lock(new_lock_key);
      end if;
    else
      perform pg_catalog.pg_advisory_xact_lock(new_lock_key);
      perform pg_catalog.pg_advisory_xact_lock(old_lock_key);
    end if;
  else
    perform pg_catalog.pg_advisory_xact_lock(new_lock_key);
  end if;

  select s.pipeline_version_id, s.code
    into stage_pipeline, stage_code
    from crm.global_pipeline_stages s
   where s.id = new.current_stage_id;

  if stage_pipeline is distinct from new.pipeline_version_id then
    raise exception 'opportunity stage does not belong to pipeline version';
  end if;

  if (stage_code = 'ganho' and new.status <> 'won')
     or (stage_code = 'perdido' and new.status <> 'lost')
     or (stage_code not in ('ganho', 'perdido') and new.status <> 'open') then
    raise exception 'opportunity status must match its current stage';
  end if;

  if new.previous_opportunity_id is not null then
    if new.previous_opportunity_id = new.id then
      raise exception 'opportunity cannot reference itself as the previous cycle';
    end if;

    select o.contact_id, o.status, o.closed_at
      into previous_contact, previous_status, previous_closed_at
      from crm.opportunities o
     where o.tenant_id = new.tenant_id
       and o.id = new.previous_opportunity_id;
    if previous_contact is distinct from new.contact_id then
      raise exception 'previous opportunity must share tenant and contact';
    end if;
    if previous_status not in ('won', 'lost')
       or previous_closed_at is null
       or previous_closed_at > new.opened_at then
      raise exception 'previous opportunity must be closed before the new cycle opens';
    end if;
    if exists (
      with recursive lineage as (
        select o.id, o.previous_opportunity_id
          from crm.opportunities o
         where o.tenant_id = new.tenant_id
           and o.id = new.previous_opportunity_id
        union
        select o.id, o.previous_opportunity_id
          from crm.opportunities o
          join lineage l on l.previous_opportunity_id = o.id
         where o.tenant_id = new.tenant_id
      )
      select 1 from lineage where id = new.id
    ) then
      raise exception 'opportunity previous-cycle chain cannot contain a cycle';
    end if;
  end if;

  if exists (
    select 1
      from crm.opportunities successor
     where successor.tenant_id = new.tenant_id
       and successor.previous_opportunity_id = new.id
       and (
         successor.contact_id is distinct from new.contact_id
         or new.status not in ('won', 'lost')
         or new.closed_at is null
         or new.closed_at > successor.opened_at
       )
  ) then
    raise exception 'opportunity update would invalidate a later cycle';
  end if;

  return new;
end;
$$;

create function crm.validate_activity_raw_tenant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  raw_tenant uuid;
begin
  if new.raw_event_id is not null then
    select r.client_id
      into raw_tenant
      from public.stevo_events_raw r
     where r.id = new.raw_event_id;
    if raw_tenant is distinct from new.tenant_id then
      raise exception 'raw event must belong to the activity tenant';
    end if;
  end if;
  return new;
end;
$$;

create function crm.validate_stage_history()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  opportunity_pipeline uuid;
  from_pipeline uuid;
  to_pipeline uuid;
  from_position smallint;
  to_position smallint;
  from_is_terminal boolean;
  compensated_at timestamptz;
  compensated_transition_type text;
  compensated_from_stage_id uuid;
  compensated_to_stage_id uuid;
begin
  select o.pipeline_version_id
    into opportunity_pipeline
    from crm.opportunities o
   where o.tenant_id = new.tenant_id
     and o.id = new.opportunity_id;
  select s.pipeline_version_id, s.position, s.is_terminal
    into from_pipeline, from_position, from_is_terminal
    from crm.global_pipeline_stages s
   where s.id = new.from_stage_id;
  select s.pipeline_version_id, s.position
    into to_pipeline, to_position
    from crm.global_pipeline_stages s
   where s.id = new.to_stage_id;

  if to_pipeline is distinct from opportunity_pipeline
     or (new.from_stage_id is not null and from_pipeline is distinct from opportunity_pipeline) then
    raise exception 'stage history must use the opportunity pipeline version';
  end if;

  if new.transition_type in ('manual', 'undo', 'correction')
     and not exists (
       select 1
         from public.client_users cu
        where cu.client_id = new.tenant_id
          and cu.user_id = new.actor_profile_id
          and cu.is_active = true
          and pg_catalog.lower(cu.role) <> 'viewer'
     ) then
    raise exception 'manual, undo and correction transitions require an active actor';
  end if;

  if new.transition_type in ('undo', 'correction') then
    if new.compensates_history_id is null
       or pg_catalog.length(pg_catalog.btrim(coalesce(new.reason, ''))) = 0 then
      raise exception 'undo and correction require actor, reason and compensated history';
    end if;
  elsif new.compensates_history_id is not null then
    raise exception 'only undo and correction may compensate history';
  end if;

  if new.transition_type = 'manual'
     and to_position < from_position
     and pg_catalog.length(pg_catalog.btrim(coalesce(new.reason, ''))) = 0 then
    raise exception 'manual regression requires a reason';
  end if;

  if new.transition_type = 'automatic'
     and from_is_terminal
     and new.from_stage_id is distinct from new.to_stage_id then
    raise exception 'automatic transition cannot leave a terminal stage';
  end if;

  if new.compensates_history_id is not null then
    select h.occurred_at, h.transition_type, h.from_stage_id, h.to_stage_id
      into compensated_at, compensated_transition_type,
           compensated_from_stage_id, compensated_to_stage_id
      from crm.opportunity_stage_history h
     where h.tenant_id = new.tenant_id
       and h.id = new.compensates_history_id
       and h.opportunity_id = new.opportunity_id;
    if compensated_at is null or compensated_at >= new.occurred_at then
      raise exception 'compensation must reference an earlier history row';
    end if;
    if new.transition_type = 'undo'
       and (
         compensated_transition_type is distinct from 'automatic'
         or new.from_stage_id is distinct from compensated_to_stage_id
         or new.to_stage_id is distinct from compensated_from_stage_id
       ) then
      raise exception 'undo must reverse the referenced automatic transition';
    end if;
  end if;

  return new;
end;
$$;

create function crm.validate_opportunity_history_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  checked_tenant_id uuid;
  checked_opportunity_id uuid;
  current_stage_id uuid;
  latest_history_stage_id uuid;
begin
  if tg_table_name = 'opportunities' then
    if tg_op = 'UPDATE'
       and new.current_stage_id is not distinct from old.current_stage_id then
      return null;
    end if;
    checked_tenant_id := new.tenant_id;
    checked_opportunity_id := new.id;
  else
    checked_tenant_id := new.tenant_id;
    checked_opportunity_id := new.opportunity_id;
  end if;

  select o.current_stage_id
    into current_stage_id
    from crm.opportunities o
   where o.tenant_id = checked_tenant_id
     and o.id = checked_opportunity_id;

  select h.to_stage_id
    into latest_history_stage_id
    from crm.opportunity_stage_history h
   where h.tenant_id = checked_tenant_id
     and h.opportunity_id = checked_opportunity_id
   order by h.occurred_at desc, h.created_at desc, h.id desc
   limit 1;

  if latest_history_stage_id is null
     or current_stage_id is distinct from latest_history_stage_id then
    raise exception 'opportunity current stage must match its latest history row';
  end if;

  return null;
end;
$$;

create function crm.validate_commercial_outcome()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  note_required boolean;
  reason_active boolean;
begin
  if new.origin = 'manual'
     and (
       not exists (
         select 1
           from public.client_users cu
          where cu.client_id = new.tenant_id
            and cu.user_id = new.actor_profile_id
            and cu.is_active = true
            and pg_catalog.lower(cu.role) <> 'viewer'
       )
       or pg_catalog.length(pg_catalog.btrim(coalesce(new.evidence, ''))) = 0
     ) then
    raise exception 'manual outcome requires active write actor and evidence';
  end if;

  if new.outcome = 'lost' then
    select r.requires_note, r.active
      into note_required, reason_active
      from crm.canonical_loss_reasons r
     where r.id = new.loss_reason_id;
    if reason_active is distinct from true then
      raise exception 'lost outcome requires an active canonical reason';
    end if;
    if note_required and pg_catalog.length(pg_catalog.btrim(coalesce(new.evidence, ''))) = 0 then
      raise exception 'the selected loss reason requires a note';
    end if;
  end if;
  return new;
end;
$$;

create function crm.validate_opportunity_outcome_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  checked_tenant_id uuid;
  checked_opportunity_id uuid;
  opportunity_status text;
  current_outcome_count integer;
  matching_outcome_count integer;
begin
  if tg_table_name = 'opportunities' then
    checked_tenant_id := new.tenant_id;
    checked_opportunity_id := new.id;
  elsif tg_op = 'DELETE' then
    checked_tenant_id := old.tenant_id;
    checked_opportunity_id := old.opportunity_id;
  else
    checked_tenant_id := new.tenant_id;
    checked_opportunity_id := new.opportunity_id;
  end if;

  select o.status
    into opportunity_status
    from crm.opportunities o
   where o.tenant_id = checked_tenant_id
     and o.id = checked_opportunity_id;

  if not found then
    return null;
  end if;

  select
    pg_catalog.count(*)::integer,
    pg_catalog.count(*) filter (where co.outcome = opportunity_status)::integer
    into current_outcome_count, matching_outcome_count
    from crm.commercial_outcomes co
   where co.tenant_id = checked_tenant_id
     and co.opportunity_id = checked_opportunity_id
     and co.is_current;

  if opportunity_status = 'open' and current_outcome_count <> 0 then
    raise exception 'open opportunity cannot have a current commercial outcome';
  end if;

  if opportunity_status in ('won', 'lost')
     and (current_outcome_count <> 1 or matching_outcome_count <> 1) then
    raise exception 'terminal opportunity requires exactly one matching current commercial outcome';
  end if;

  return null;
end;
$$;

create function crm.validate_processed_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  raw_tenant_id uuid;
  raw_payload_hash text;
begin
  if tg_op = 'UPDATE'
     and (
       new.id is distinct from old.id
       or new.tenant_id is distinct from old.tenant_id
       or new.raw_event_id is distinct from old.raw_event_id
       or new.source is distinct from old.source
       or new.external_id is distinct from old.external_id
       or new.payload_hash is distinct from old.payload_hash
       or new.created_at is distinct from old.created_at
     ) then
    raise exception 'processed event identity is immutable';
  end if;

  select r.client_id, r.payload_hash
    into raw_tenant_id, raw_payload_hash
    from public.stevo_events_raw r
   where r.id = new.raw_event_id;

  if raw_tenant_id is distinct from new.tenant_id then
    raise exception 'raw event must belong to the processed event tenant';
  end if;
  if raw_payload_hash is distinct from new.payload_hash then
    raise exception 'processed event hash must match raw event hash';
  end if;

  return new;
end;
$$;

create function crm.restrict_outcome_revision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'commercial outcomes are append-only';
  end if;
  if new.is_current
     or old.is_current is not true
     or new.id is distinct from old.id
     or new.tenant_id is distinct from old.tenant_id
     or new.opportunity_id is distinct from old.opportunity_id
     or new.outcome is distinct from old.outcome
     or new.origin is distinct from old.origin
     or new.actor_profile_id is distinct from old.actor_profile_id
     or new.loss_reason_id is distinct from old.loss_reason_id
     or new.evidence is distinct from old.evidence
     or new.value is distinct from old.value
     or new.value_status is distinct from old.value_status
     or new.currency is distinct from old.currency
     or new.occurred_at is distinct from old.occurred_at
     or new.created_at is distinct from old.created_at then
    raise exception 'commercial outcome fields are immutable; insert a correction and retire the current row';
  end if;
  return new;
end;
$$;

create trigger opportunities_validate
before insert or update on crm.opportunities
for each row execute function crm.validate_opportunity();

create trigger activities_validate_raw_tenant
before insert or update on crm.activities
for each row execute function crm.validate_activity_raw_tenant();

create trigger opportunity_stage_history_validate
before insert on crm.opportunity_stage_history
for each row execute function crm.validate_stage_history();

create trigger opportunity_stage_history_append_only
before update or delete on crm.opportunity_stage_history
for each row execute function crm.reject_append_only_mutation();

create constraint trigger opportunity_stage_history_validate_current_stage
after insert on crm.opportunity_stage_history
deferrable initially deferred
for each row execute function crm.validate_opportunity_history_consistency();

create constraint trigger opportunities_validate_latest_history
after update on crm.opportunities
deferrable initially deferred
for each row execute function crm.validate_opportunity_history_consistency();

create trigger opportunity_milestones_append_only
before update or delete on crm.opportunity_milestones
for each row execute function crm.reject_append_only_mutation();

create trigger commercial_outcomes_validate
before insert on crm.commercial_outcomes
for each row execute function crm.validate_commercial_outcome();

create trigger commercial_outcomes_append_only
before update or delete on crm.commercial_outcomes
for each row execute function crm.restrict_outcome_revision();

create constraint trigger opportunities_validate_outcome_consistency
after insert or update on crm.opportunities
deferrable initially deferred
for each row execute function crm.validate_opportunity_outcome_consistency();

create constraint trigger commercial_outcomes_validate_opportunity_consistency
after insert or update or delete on crm.commercial_outcomes
deferrable initially deferred
for each row execute function crm.validate_opportunity_outcome_consistency();

create trigger processed_events_validate
before insert or update on crm.processed_events
for each row execute function crm.validate_processed_event();

alter table crm.tenants enable row level security;
alter table crm.profiles enable row level security;
alter table crm.tenant_memberships enable row level security;
alter table crm.global_pipeline_versions enable row level security;
alter table crm.global_pipeline_stages enable row level security;
alter table crm.canonical_loss_reasons enable row level security;
alter table crm.contacts enable row level security;
alter table crm.contact_identities enable row level security;
alter table crm.opportunities enable row level security;
alter table crm.opportunity_stage_history enable row level security;
alter table crm.opportunity_milestones enable row level security;
alter table crm.activities enable row level security;
alter table crm.commercial_outcomes enable row level security;
alter table crm.processed_events enable row level security;

create policy tenant_read_tenants on crm.tenants
  for select to authenticated using (crm.is_member(id));
create policy service_write_tenants on crm.tenants
  for all to service_role using (true) with check (true);

create policy tenant_read_profiles on crm.profiles
  for select to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1
        from crm.tenant_memberships m
       where m.profile_id = profiles.id
         and m.status = 'active'
         and crm.is_member(m.tenant_id)
    )
  );
create policy service_write_profiles on crm.profiles
  for all to service_role using (true) with check (true);

create policy tenant_read_memberships on crm.tenant_memberships
  for select to authenticated using (crm.is_member(tenant_id));
create policy service_write_memberships on crm.tenant_memberships
  for all to service_role using (true) with check (true);

create policy global_read_pipeline_versions on crm.global_pipeline_versions
  for select to authenticated using (true);
create policy service_write_pipeline_versions on crm.global_pipeline_versions
  for all to service_role using (true) with check (true);

create policy global_read_pipeline_stages on crm.global_pipeline_stages
  for select to authenticated using (true);
create policy service_write_pipeline_stages on crm.global_pipeline_stages
  for all to service_role using (true) with check (true);

create policy global_read_loss_reasons on crm.canonical_loss_reasons
  for select to authenticated using (true);
create policy service_write_loss_reasons on crm.canonical_loss_reasons
  for all to service_role using (true) with check (true);

create policy tenant_read_contacts on crm.contacts
  for select to authenticated using (crm.is_member(tenant_id));
create policy service_write_contacts on crm.contacts
  for all to service_role using (true) with check (true);

create policy tenant_read_contact_identities on crm.contact_identities
  for select to authenticated using (crm.is_member(tenant_id));
create policy service_write_contact_identities on crm.contact_identities
  for all to service_role using (true) with check (true);

create policy tenant_read_opportunities on crm.opportunities
  for select to authenticated using (crm.is_member(tenant_id));
create policy service_write_opportunities on crm.opportunities
  for all to service_role using (true) with check (true);

create policy tenant_read_stage_history on crm.opportunity_stage_history
  for select to authenticated using (crm.is_member(tenant_id));
create policy service_write_stage_history on crm.opportunity_stage_history
  for all to service_role using (true) with check (true);

create policy tenant_read_milestones on crm.opportunity_milestones
  for select to authenticated using (crm.is_member(tenant_id));
create policy service_write_milestones on crm.opportunity_milestones
  for all to service_role using (true) with check (true);

create policy tenant_read_activities on crm.activities
  for select to authenticated using (crm.is_member(tenant_id));
create policy service_write_activities on crm.activities
  for all to service_role using (true) with check (true);

create policy tenant_read_commercial_outcomes on crm.commercial_outcomes
  for select to authenticated using (crm.is_member(tenant_id));
create policy service_write_commercial_outcomes on crm.commercial_outcomes
  for all to service_role using (true) with check (true);

create policy tenant_read_processed_events on crm.processed_events
  for select to authenticated using (crm.is_member(tenant_id));
create policy service_write_processed_events on crm.processed_events
  for all to service_role using (true) with check (true);

revoke all on all tables in schema crm from public, anon, authenticated;
grant select on all tables in schema crm to authenticated;
grant all privileges on all tables in schema crm to service_role;

revoke all on all functions in schema crm from public, anon, authenticated;
grant execute on function crm.is_member(uuid) to authenticated, service_role;
