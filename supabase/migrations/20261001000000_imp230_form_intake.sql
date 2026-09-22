-- IMP-230: formulario de site, origem Google e entrada protegida por token.
set local lock_timeout = '5s';

alter table public.clients_base add column form_intake_token uuid not null default pg_catalog.gen_random_uuid();
create unique index clients_base_form_intake_token_uidx on public.clients_base(form_intake_token);

alter table crm.opportunities
  add column gclid text, add column gbraid text, add column wbraid text,
  add column utm_source text, add column utm_medium text, add column utm_campaign text,
  add column utm_content text, add column utm_term text;

create table public.form_intake_rate_limit (
  window_started timestamptz not null, ip inet not null, form_intake_token uuid not null,
  request_count integer not null default 0 check (request_count >= 0),
  primary key (window_started, ip, form_intake_token)
);
alter table public.form_intake_rate_limit enable row level security;
revoke all on table public.form_intake_rate_limit from public, anon, authenticated;
grant all on table public.form_intake_rate_limit to service_role;

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

  -- IMP-230: origem Google e UTMs seguem do card para o dashboard.
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
        'meta_ad_id', new.meta_ad_id, 'gclid', new.gclid, 'gbraid', new.gbraid,
        'wbraid', new.wbraid, 'utm_source', new.utm_source, 'utm_medium', new.utm_medium,
        'utm_campaign', new.utm_campaign, 'utm_content', new.utm_content, 'utm_term', new.utm_term)
    )),
    'normalized', pg_catalog.now()
  ) returning id into v_raw_event_id;

  insert into public.events_normalized (
    raw_event_id, client_id, ghl_location_id, ghl_location_name, client_name,
    event_code, event_name, funnel_step, event_datetime, source_system,
    source_event_type, contact_id, full_name, phone, email,
    conversion_source, entry_point_conversion_source, source_type, source_id,
    source_url, source_ads, ad_title, ctwa_clid, gclid, gbraid, wbraid, utm_source, utm_medium, utm_campaign, utm_content, utm_term, opportunity_id, pipeline_id,
    pipeline_stage, status, received_at, location_id, location_name, payload
  ) values (
    v_raw_event_id, new.tenant_id, v_ghl_location_id, v_location_name, v_client_name,
    v_event_code, v_event_name, v_funnel_step, v_event_datetime, 'impuls_crm',
    'crm_stage_changed', new.contact_id::text, v_contact_name, v_contact_phone, v_contact_email,
    new.conversion_source, new.entry_point_conversion_source,
    case when new.meta_ad_id is not null then 'ad' else null end,
    new.meta_ad_id, new.source_url, new.meta_ad_id is not null, new.ad_title,
    new.ctwa_clid, new.gclid, new.gbraid, new.wbraid, new.utm_source, new.utm_medium, new.utm_campaign, new.utm_content, new.utm_term, new.id::text, new.pipeline_version_id::text, v_stage_code,
    new.status, pg_catalog.now(), v_ghl_location_id, v_location_name,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'tenant_id', new.tenant_id, 'opportunity_id', new.id,
      'contact_id', new.contact_id, 'stage_code', v_stage_code,
      'stage_version', new.stage_version,
      'meta', pg_catalog.jsonb_build_object(
        'ctwa_clid', new.ctwa_clid, 'conversion_source', new.conversion_source,
        'meta_ad_id', new.meta_ad_id, 'gclid', new.gclid, 'gbraid', new.gbraid,
        'wbraid', new.wbraid, 'utm_source', new.utm_source, 'utm_medium', new.utm_medium,
        'utm_campaign', new.utm_campaign, 'utm_content', new.utm_content, 'utm_term', new.utm_term)
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

create or replace function crm.intake_form_lead(
  p_client_slug text,
  p_form_intake_token uuid,
  p_full_name text,
  p_phone text default null,
  p_email text default null,
  p_gclid text default null,
  p_gbraid text default null,
  p_wbraid text default null,
  p_utm_source text default null,
  p_utm_medium text default null,
  p_utm_campaign text default null,
  p_utm_content text default null,
  p_utm_term text default null,
  p_page_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_tenant uuid; v_contact uuid; v_opp uuid; v_pipeline uuid; v_stage uuid;
  v_name text := pg_catalog.btrim(p_full_name);
  v_phone text := nullif(pg_catalog.btrim(coalesce(p_phone, '')), '');
  v_email text := nullif(pg_catalog.lower(pg_catalog.btrim(coalesce(p_email, ''))), '');
  v_source text := case when nullif(pg_catalog.btrim(coalesce(p_gclid, '')), '') is not null then 'google_ads' else 'organic' end;
begin
  if v_name is null or pg_catalog.length(v_name) = 0 or (v_phone is null and v_email is null) then
    raise exception 'FORM_INTAKE_INVALID';
  end if;
  select cb.id into v_tenant from public.clients_base cb
   where pg_catalog.lower(cb.client_slug) = pg_catalog.lower(pg_catalog.btrim(p_client_slug))
     and cb.form_intake_token = p_form_intake_token
     and pg_catalog.lower(coalesce(cb.status, '')) <> 'inactive';
  if v_tenant is null then raise exception 'FORM_INTAKE_INVALID'; end if;
  select c.id into v_contact from crm.contacts c
   where c.tenant_id = v_tenant and ((v_phone is not null and c.phone_normalized = v_phone) or (v_email is not null and pg_catalog.lower(c.email) = v_email))
   order by c.created_at limit 1;
  if v_contact is null then
    insert into crm.contacts (tenant_id, full_name, phone_normalized, email) values (v_tenant, v_name, v_phone, v_email) returning id into v_contact;
  end if;
  select o.id into v_opp from crm.opportunities o
   where o.tenant_id = v_tenant and o.contact_id = v_contact and o.created_at >= pg_catalog.now() - interval '24 hours'
   order by o.created_at desc limit 1;
  if v_opp is not null then return pg_catalog.jsonb_build_object('contact_id', v_contact, 'opportunity_id', v_opp, 'deduped', true); end if;
  select pv.id, s.id into v_pipeline, v_stage
    from crm.global_pipeline_versions pv join crm.global_pipeline_stages s on s.pipeline_version_id = pv.id
   where pv.status = 'active' and s.code = 'lead';
  if v_stage is null then raise exception 'FORM_INTAKE_UNAVAILABLE'; end if;
  insert into crm.opportunities (tenant_id, contact_id, pipeline_version_id, current_stage_id, title, conversion_source, source_url, gclid, gbraid, wbraid, utm_source, utm_medium, utm_campaign, utm_content, utm_term)
  values (v_tenant, v_contact, v_pipeline, v_stage, v_name, v_source, nullif(pg_catalog.btrim(coalesce(p_page_url, '')), ''), nullif(pg_catalog.btrim(coalesce(p_gclid, '')), ''), nullif(pg_catalog.btrim(coalesce(p_gbraid, '')), ''), nullif(pg_catalog.btrim(coalesce(p_wbraid, '')), ''), nullif(pg_catalog.btrim(coalesce(p_utm_source, '')), ''), nullif(pg_catalog.btrim(coalesce(p_utm_medium, '')), ''), nullif(pg_catalog.btrim(coalesce(p_utm_campaign, '')), ''), nullif(pg_catalog.btrim(coalesce(p_utm_content, '')), ''), nullif(pg_catalog.btrim(coalesce(p_utm_term, '')), '')) returning id into v_opp;
  return pg_catalog.jsonb_build_object('contact_id', v_contact, 'opportunity_id', v_opp, 'deduped', false);
end
$fn$;

revoke all on function crm.intake_form_lead(text, uuid, text, text, text, text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function crm.intake_form_lead(text, uuid, text, text, text, text, text, text, text, text, text, text, text, text) to service_role;

insert into supabase_migrations.schema_migrations (version, name) values ('20261001000000','imp230_form_intake') on conflict (version) do nothing;

do $gate$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='clients_base' and column_name='form_intake_token') then raise exception 'IMP230_GATE: token ausente'; end if;
  if (select count(*) from information_schema.columns where table_schema='crm' and table_name='opportunities' and column_name in ('gclid','gbraid','wbraid','utm_source','utm_medium','utm_campaign','utm_content','utm_term')) <> 8 then raise exception 'IMP230_GATE: colunas Google incompletas'; end if;
  if has_table_privilege('anon','crm.contacts','INSERT') or has_table_privilege('anon','crm.opportunities','INSERT') then raise exception 'IMP230_GATE: anon recebeu INSERT'; end if;
  if has_function_privilege('anon','crm.intake_form_lead(text,uuid,text,text,text,text,text,text,text,text,text,text,text,text)','EXECUTE') then raise exception 'IMP230_GATE: anon executa intake'; end if;
  if not has_function_privilege('service_role','crm.intake_form_lead(text,uuid,text,text,text,text,text,text,text,text,text,text,text,text)','EXECUTE') then raise exception 'IMP230_GATE: service_role sem intake'; end if;
end
$gate$;
