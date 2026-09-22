-- IMP-218 application bundle; self-contained, no \ir.
-- IMP-218: event x platform matrix for Meta and Google.
-- Source of truth: the live post-IMP-217 trigger definition plus the accepted n8n contract.
set local lock_timeout = '5s';

-- O staging reconstruído ficou sem a coluna aditiva da IMP-217 apesar da cadeia
-- de migrations estar atualizada; em produção ela já existe. O IF NOT EXISTS
-- torna a ponte compatível sem substituir a lógica da IMP-217.
alter table public.events_normalized add column if not exists currency text;

alter table public.conversion_outbox
  alter column ghl_location_id drop not null,
  alter column route drop not null,
  alter column meta_event_name drop not null;

alter table crm.event_map
  add column if not exists meta_event_name text,
  add column if not exists meta_event_name_whatsapp text,
  add column if not exists google_event_name text;

update crm.event_map set
  meta_event_name = case event_code
    when 'lead' then 'Lead'
    when 'agendado' then 'Schedule'
    when 'ganho' then 'Purchase'
    else null end,
  meta_event_name_whatsapp = case event_code
    when 'lead' then 'LeadSubmitted'
    when 'agendado' then 'QualifiedLead'
    when 'ganho' then 'Purchase'
    else null end,
  google_event_name = case event_code
    when 'lead' then 'Lead'
    when 'agendado' then 'Agendou'
    when 'ganho' then 'Compra'
    else null end;

create unique index if not exists conversion_outbox_event_platform_uidx
  on public.conversion_outbox (normalized_event_id, platform);

CREATE OR REPLACE FUNCTION crm.emit_opportunity_stage_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_meta_event_name_standard text;
  v_meta_event_name_whatsapp text;
  v_google_event_name text;
  v_google_conversion_action text;
  v_google_enabled boolean;
  v_google_customer_id text;
  v_google_manager_customer_id text;
  v_google_dispatch_method text;
  v_google_destination_id text;
  v_value            numeric;
  v_value_status     text;
  v_currency         text;
  v_loss_reason_code text;
  v_loss_reason_detail text;
begin
  if tg_op = 'UPDATE'
     and new.current_stage_id is not distinct from old.current_stage_id then
    return new;
  end if;

  select cb.ghl_location_id, cb.ghl_location_name, cb.client_name,
         coalesce(cb.crm_feeds_dashboard, true), coalesce(cb.crm_emits_conversions, false),
         coalesce(cb.enable_google_tracking, false), cb.google_ads_customer_id,
         cb.google_manager_customer_id, coalesce(cb.google_ads_dispatch_method, 'data_manager_api'),
         cb.google_data_manager_destination_id
    into v_ghl_location_id, v_location_name, v_client_name, v_dashboard, v_emits,
         v_google_enabled, v_google_customer_id, v_google_manager_customer_id,
         v_google_dispatch_method, v_google_destination_id
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
  select m.event_code, m.event_name, m.funnel_step, m.meta_event_name,
         m.meta_event_name_whatsapp, m.google_event_name
    into v_event_code, v_event_name, v_funnel_step, v_meta_event_name_standard,
         v_meta_event_name_whatsapp, v_google_event_name
    from crm.event_map m
   where m.stage_code = v_stage_code and m.is_active;

  if v_event_code is null then
    raise exception 'IMP-216 cannot map CRM stage % to an event code', new.current_stage_id;
  end if;

  select co.value, co.value_status, co.currency, lr.code, co.evidence
    into v_value, v_value_status, v_currency, v_loss_reason_code, v_loss_reason_detail
    from crm.commercial_outcomes co
    left join crm.canonical_loss_reasons lr on lr.id = co.loss_reason_id
   where co.tenant_id = new.tenant_id and co.opportunity_id = new.id and co.is_current
   order by co.occurred_at desc, co.created_at desc, co.id desc limit 1;

  -- IMP-230: origem Google e UTMs seguem do card para o dashboard.
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
    valor_ganho, budget_status, closed_value, currency, motivo_perda_categoria, motivo_perda_detalhe,
    pipeline_stage, status, received_at, location_id, location_name, payload
  ) values (
    v_raw_event_id, new.tenant_id, v_ghl_location_id, v_location_name, v_client_name,
    v_event_code, v_event_name, v_funnel_step, v_event_datetime, 'impuls_crm',
    'crm_stage_changed', new.contact_id::text, v_contact_name, v_contact_phone, v_contact_email,
    new.conversion_source, new.entry_point_conversion_source,
    case when new.meta_ad_id is not null then 'ad' else null end,
    new.meta_ad_id, new.source_url, new.meta_ad_id is not null, new.ad_title,
    new.ctwa_clid, new.gclid, new.gbraid, new.wbraid, new.utm_source, new.utm_medium, new.utm_campaign, new.utm_content, new.utm_term, new.id::text, new.pipeline_version_id::text,
    v_value, v_value_status, v_value, v_currency, case when v_event_code = 'perdido' then v_loss_reason_code end, case when v_event_code = 'perdido' then v_loss_reason_detail end,
    v_stage_code, new.status, pg_catalog.now(), v_ghl_location_id, v_location_name,
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

  if not v_emits or v_event_code not in ('lead', 'agendado', 'ganho')
     or (v_event_code = 'ganho' and v_value_status = 'pending') then
    return new;
  end if;

  v_route := case when new.ctwa_clid is not null
       or new.conversion_source in ('FB_Ads', 'FB_Post')
    then 'whatsapp_bm' else 'standard' end;
  v_meta_event_name := case when v_route = 'whatsapp_bm'
    then v_meta_event_name_whatsapp else v_meta_event_name_standard end;

  v_google_conversion_action := case v_event_code
    when 'lead' then (select cb.google_conversion_action_lead from public.clients_base cb where cb.id = new.tenant_id)
    when 'agendado' then (select cb.google_conversion_action_agendado from public.clients_base cb where cb.id = new.tenant_id)
    when 'ganho' then (select cb.google_conversion_action_ganho from public.clients_base cb where cb.id = new.tenant_id)
    else null end;

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
      'custom_data', pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'opportunity_id', new.id, 'stage_code', v_stage_code, 'stage_version', new.stage_version,
        'value', case when v_value_status = 'valid' then v_value end,
        'currency', case when v_value_status = 'valid' then v_currency end)),
      'routing_checks', pg_catalog.jsonb_build_object(
        'has_ctwa_clid', new.ctwa_clid is not null, 'has_meta_ad_id', new.meta_ad_id is not null)
    )), 'pending'
  );

  if v_google_enabled and pg_catalog.nullif(pg_catalog.btrim(coalesce(v_google_conversion_action, '')), '') is not null
     and v_google_event_name is not null then
    insert into public.conversion_outbox (
      normalized_event_id, ghl_location_id, contact_id, event_code, platform,
      route, meta_event_name, platform_event_name, platform_conversion_action,
      platform_account_id, platform_manager_account_id, dispatch_method,
      destination_config, payload, status
    ) values (
      v_normalized_id, null, new.contact_id::text, v_event_code, 'google_ads',
      null, null, v_google_event_name, v_google_conversion_action,
      v_google_customer_id, v_google_manager_customer_id, v_google_dispatch_method,
      pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'customer_id', v_google_customer_id,
        'manager_customer_id', v_google_manager_customer_id,
        'destination_id', v_google_destination_id)),
      pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'event_id', v_normalized_id, 'event_code', v_event_code,
        'platform', 'google_ads', 'platform_event_name', v_google_event_name,
        'platform_conversion_action', v_google_conversion_action,
        'platform_account_id', v_google_customer_id,
        'platform_manager_account_id', v_google_manager_customer_id,
        'dispatch_method', v_google_dispatch_method,
        'destination_config', pg_catalog.jsonb_build_object(
          'customer_id', v_google_customer_id,
          'manager_customer_id', v_google_manager_customer_id,
          'destination_id', v_google_destination_id),
        'user_data', pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
          'contact_id', new.contact_id, 'full_name', v_contact_name,
          'phone', v_contact_phone, 'email', v_contact_email)),
        'attribution', pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
          'gclid', new.gclid, 'gbraid', new.gbraid, 'wbraid', new.wbraid,
          'utm_source', new.utm_source, 'utm_medium', new.utm_medium,
          'utm_campaign', new.utm_campaign)),
        'custom_data', pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
          'opportunity_id', new.id, 'stage_code', v_stage_code,
          'value', case when v_value_status = 'valid' then v_value end,
          'currency', case when v_value_status = 'valid' then v_currency end))
      )), 'pending'
    );
  end if;
  return new;
end;
$function$
;

revoke all on function crm.emit_opportunity_stage_event() from public, anon, authenticated, service_role;
grant execute on function crm.emit_opportunity_stage_event() to service_role;

insert into supabase_migrations.schema_migrations (version, name)
values ('20261004000000', 'imp218_event_platform_matrix')
on conflict (version) do nothing;

do $gate$
begin
  if not exists (select 1 from information_schema.columns where table_schema='crm' and table_name='event_map' and column_name='google_event_name') then raise exception 'IMP218_GATE: google_event_name ausente'; end if;
  if exists (select 1 from crm.event_map where event_code in ('lead','agendado','ganho') and (meta_event_name is null or meta_event_name_whatsapp is null or google_event_name is null)) then raise exception 'IMP218_GATE: matriz elegivel incompleta'; end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='conversion_outbox_event_platform_uidx') then raise exception 'IMP218_GATE: idempotencia ausente'; end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='conversion_outbox' and column_name in ('ghl_location_id','route','meta_event_name') and is_nullable='NO') then raise exception 'IMP218_GATE: colunas Google continuam NOT NULL'; end if;
  if has_function_privilege('anon', 'crm.emit_opportunity_stage_event()', 'EXECUTE') then raise exception 'IMP218_GATE: anon executa emissor'; end if;
end
$gate$;
