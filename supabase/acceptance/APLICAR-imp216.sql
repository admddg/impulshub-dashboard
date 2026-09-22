-- IMP-216 — APLICAR (autocontido: cole inteiro no SQL Editor do Supabase de producao).
-- Aplicar somente com autorizacao do Caio. A migration abaixo ja registra o ledger e tem gate final.
-- Provado em staging (migration + aceite + isolamento + rollback); prova em producao so com autorizacao.

begin;
-- IMP-216: separa alimentar o dashboard de enviar conversao.
-- Nao executa a parte Google: as colunas de origem ainda pertencem a IMP-230.
set local lock_timeout = '5s';

alter table public.events_normalized
  alter column ghl_location_id drop not null;

alter table public.clients_base
  add column if not exists crm_feeds_dashboard boolean not null default true;

comment on column public.clients_base.crm_feeds_dashboard is
  'Quando true, movimentos do CRM alimentam events_normalized. Deve permanecer false em clientes cujo GHL ja alimenta o dashboard, para evitar duplicacao.';

update public.clients_base
   set crm_feeds_dashboard = false
 where id = any(array[
   '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid,
   '3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid,
   'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid
 ]);
set constraints all immediate;

create table crm.event_map (
  event_code text primary key,
  stage_code text not null unique,
  version integer not null check (version > 0),
  event_name text not null,
  funnel_step smallint,
  is_active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  unique (version, event_code)
);

alter table crm.event_map enable row level security;
revoke all on table crm.event_map from public, anon, authenticated;
grant all on table crm.event_map to service_role;

insert into crm.event_map (event_code, stage_code, version, event_name, funnel_step)
values
  ('lead', 'lead', 1, 'Lead', null),
  ('primeira_conversa', 'atendimento', 1, 'Primeira_Conversa', null),
  ('agendado', 'agendado', 1, 'Agendado', null),
  ('compareceu', 'compareceu', 1, 'Compareceu', null),
  ('ganho', 'ganho', 1, 'Ganho', null),
  ('perdido', 'perdido', 1, 'Perdido', null);

create or replace function crm.emit_opportunity_stage_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_stage_code       text;
  v_event_code       text;
  v_event_name       text;
  v_funnel_step      smallint;
  v_event_datetime   timestamptz;
  v_ghl_location_id  text;
  v_location_name    text;
  v_client_name      text;
  v_dashboard       boolean;
  v_emits            boolean;
  v_contact_name     text;
  v_contact_phone    text;
  v_contact_email    text;
  v_raw_event_id     uuid;
  v_normalized_id    uuid;
  v_route            text;
  v_meta_event_name  text;
begin
  if tg_op = 'UPDATE'
     and new.current_stage_id is not distinct from old.current_stage_id then
    return new;
  end if;

  select cb.ghl_location_id, cb.ghl_location_name, cb.client_name,
         coalesce(cb.crm_feeds_dashboard, true), coalesce(cb.crm_emits_conversions, false)
    into v_ghl_location_id, v_location_name, v_client_name, v_dashboard, v_emits
    from public.clients_base cb
   where cb.id = new.tenant_id;

  -- clients_base.ghl_location_id e NOT NULL UNIQUE: cliente sem GHL usa '' ou
  -- placeholder. Vazio vira NULL no evento (client_id e a chave canonica).
  v_ghl_location_id := nullif(pg_catalog.btrim(coalesce(v_ghl_location_id, '')), '');

  if not v_dashboard and not v_emits then
    return new;
  end if;

  select s.code into v_stage_code
    from crm.global_pipeline_stages s where s.id = new.current_stage_id;
  select m.event_code, m.event_name, m.funnel_step
    into v_event_code, v_event_name, v_funnel_step
    from crm.event_map m
   where m.stage_code = v_stage_code and m.is_active;

  if v_event_code is null then
    raise exception 'IMP-216 cannot map CRM stage % to an event code', new.current_stage_id;
  end if;

  -- Google (gclid/gbraid/wbraid/UTM) pertence a IMP-230; nao inventar colunas.
  if v_emits and v_ghl_location_id is null then
    raise exception 'IMP-216 ghl_location_id is required only for conversion emission, tenant %', new.tenant_id;
  end if;

  if exists (
    select 1 from public.events_normalized en
     where en.client_id = new.tenant_id
       and en.opportunity_id = new.id::text
       and en.source_system = 'impuls_crm'
       and en.event_code = v_event_code
  ) then
    return new;
  end if;

  select c.full_name, c.phone_normalized, c.email
    into v_contact_name, v_contact_phone, v_contact_email
    from crm.contacts c
   where c.tenant_id = new.tenant_id and c.id = new.contact_id;

  if tg_op = 'INSERT' then
    v_event_datetime := new.opened_at;
  else
    select h.occurred_at into v_event_datetime
      from crm.opportunity_stage_history h
     where h.tenant_id = new.tenant_id and h.opportunity_id = new.id
       and h.to_stage_id = new.current_stage_id
     order by h.occurred_at desc, h.created_at desc, h.id desc limit 1;
    v_event_datetime := coalesce(v_event_datetime, new.updated_at, pg_catalog.now());
  end if;

  insert into public.events_raw (
    source_system, event_type, location_id, location_name,
    contact_id, phone, email, payload, processing_status, processed_at
  ) values (
    'impuls_crm', 'opportunity_stage_changed',
    case when v_dashboard then v_ghl_location_id else v_ghl_location_id end,
    case when v_dashboard then v_location_name else v_location_name end,
    new.contact_id::text, v_contact_phone, v_contact_email,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'tenant_id', new.tenant_id, 'opportunity_id', new.id,
      'contact_id', new.contact_id, 'pipeline_version_id', new.pipeline_version_id,
      'stage_id', new.current_stage_id, 'stage_code', v_stage_code,
      'event_code', v_event_code, 'stage_version', new.stage_version,
      'occurred_at', v_event_datetime,
      'meta', pg_catalog.jsonb_build_object(
        'ctwa_clid', new.ctwa_clid, 'conversion_source', new.conversion_source,
        'meta_ad_id', new.meta_ad_id)
    )),
    'normalized', pg_catalog.now()
  ) returning id into v_raw_event_id;

  insert into public.events_normalized (
    raw_event_id, client_id, ghl_location_id, ghl_location_name, client_name,
    event_code, event_name, funnel_step, event_datetime, source_system,
    source_event_type, contact_id, full_name, phone, email,
    conversion_source, entry_point_conversion_source, source_type, source_id,
    source_url, source_ads, ad_title, ctwa_clid, opportunity_id, pipeline_id,
    pipeline_stage, status, received_at, location_id, location_name, payload
  ) values (
    v_raw_event_id, new.tenant_id, v_ghl_location_id, v_location_name, v_client_name,
    v_event_code, v_event_name, v_funnel_step, v_event_datetime, 'impuls_crm',
    'crm_stage_changed', new.contact_id::text, v_contact_name, v_contact_phone, v_contact_email,
    new.conversion_source, new.entry_point_conversion_source,
    case when new.meta_ad_id is not null then 'ad' else null end,
    new.meta_ad_id, new.source_url, new.meta_ad_id is not null, new.ad_title,
    new.ctwa_clid, new.id::text, new.pipeline_version_id::text, v_stage_code,
    new.status, pg_catalog.now(), v_ghl_location_id, v_location_name,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'tenant_id', new.tenant_id, 'opportunity_id', new.id,
      'contact_id', new.contact_id, 'stage_code', v_stage_code,
      'stage_version', new.stage_version,
      'meta', pg_catalog.jsonb_build_object(
        'ctwa_clid', new.ctwa_clid, 'conversion_source', new.conversion_source,
        'meta_ad_id', new.meta_ad_id)
    ))
  ) returning id into v_normalized_id;

  if not v_emits then
    return new;
  end if;

  v_route := case when new.ctwa_clid is not null
       or new.conversion_source in ('FB_Ads', 'FB_Post')
    then 'whatsapp_bm' else 'standard' end;
  v_meta_event_name := case v_event_code
    when 'lead' then case when v_route = 'whatsapp_bm' then 'LeadSubmitted' else 'Lead' end
    when 'agendado' then case when v_route = 'whatsapp_bm' then 'QualifiedLead' else 'Schedule' end
    when 'ganho' then 'Purchase'
    else v_event_name end;

  insert into public.conversion_outbox (
    normalized_event_id, ghl_location_id, contact_id, event_code,
    platform, route, meta_event_name, payload, status
  ) values (
    v_normalized_id, v_ghl_location_id, new.contact_id::text, v_event_code,
    'meta', v_route, v_meta_event_name,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'event_id', v_normalized_id, 'event_code', v_event_code,
      'platform', 'meta', 'route', v_route, 'meta_event_name', v_meta_event_name,
      'platform_event_name', v_meta_event_name, 'lead_origem', new.conversion_source,
      'lead_entrada', 'WhatsApp',
      'user_data_source', pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'contact_id', new.contact_id, 'full_name', v_contact_name,
        'phone', v_contact_phone, 'email', v_contact_email)),
      'attribution', pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'ctwa_clid', new.ctwa_clid, 'conversion_source', new.conversion_source,
        'entry_point_conversion_source', new.entry_point_conversion_source,
        'source_id', new.meta_ad_id, 'source_url', new.source_url, 'ad_title', new.ad_title)),
      'custom_data', pg_catalog.jsonb_build_object(
        'opportunity_id', new.id, 'stage_code', v_stage_code, 'stage_version', new.stage_version),
      'routing_checks', pg_catalog.jsonb_build_object(
        'has_ctwa_clid', new.ctwa_clid is not null, 'has_meta_ad_id', new.meta_ad_id is not null)
    )), 'pending'
  );
  return new;
end;
$fn$;

revoke all on function crm.emit_opportunity_stage_event() from public, anon, authenticated, service_role;

comment on function crm.emit_opportunity_stage_event() is
  'IMP-216: alimenta events_normalized por crm_feeds_dashboard; envia Meta por crm_emits_conversions. Google fica para IMP-230.';

create index if not exists events_normalized_crm_opportunity_idx
  on public.events_normalized (client_id, opportunity_id, event_code)
  where source_system = 'impuls_crm';

insert into supabase_migrations.schema_migrations (version, name)
values ('20260930000000', 'imp216_split_flags')
on conflict (version) do nothing;

do $gate$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='clients_base' and column_name='crm_feeds_dashboard') then
    raise exception 'IMP216_GATE: crm_feeds_dashboard ausente';
  end if;
  if exists (select 1 from public.clients_base where id = any(array['19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid,'3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid,'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid]) and crm_feeds_dashboard is distinct from false) then
    raise exception 'IMP216_GATE: cliente GHL com dashboard ligado';
  end if;
  if (select count(*) from crm.event_map) <> 6 then raise exception 'IMP216_GATE: mapa incompleto'; end if;
  if not exists (select 1 from pg_trigger where tgname='opportunities_emit_stage_event' and tgrelid='crm.opportunities'::regclass) then
    raise exception 'IMP216_GATE: trigger ausente';
  end if;
  if has_function_privilege('anon', 'crm.emit_opportunity_stage_event()', 'EXECUTE') then
    raise exception 'IMP216_GATE: anon ainda pode executar a funcao';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='events_normalized' and column_name='ghl_location_id' and is_nullable='NO') then
    raise exception 'IMP216_GATE: ghl_location_id ainda NOT NULL';
  end if;
end
$gate$;

commit;
