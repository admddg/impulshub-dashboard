-- IMP-216 rollback. Executar somente em transacao autorizada.
-- O rollback remove apenas eventos impuls_crm sem ghl_location_id criados
-- durante a vigencia desta migration; nao apaga events_raw nem historico GHL.
-- Dados de dashboard CRM sem GHL que forem removidos deixam de aparecer no
-- dashboard, e nao ha como reconstruir esses ids a partir de um GHL inexistente.

set local lock_timeout = '5s';

begin;

drop index if exists public.events_normalized_crm_opportunity_idx;

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

  select cb.ghl_location_id, cb.ghl_location_name, cb.client_name, cb.crm_emits_conversions
    into v_ghl_location_id, v_location_name, v_client_name, v_emits
    from public.clients_base cb
   where cb.id = new.tenant_id;

  -- Cliente ainda emite conversao pelo GHL: a ponte nao faz nada.
  -- Guarda antes da dedupe de proposito, para nao pagar a consulta.
  if not coalesce(v_emits, false) then
    return new;
  end if;

  select s.code
    into v_stage_code
    from crm.global_pipeline_stages s
   where s.id = new.current_stage_id;

  v_event_code := case v_stage_code
    when 'lead'        then 'lead'
    when 'atendimento' then 'primeira_conversa'
    when 'agendado'    then 'agendado'
    when 'compareceu'  then 'compareceu'
    when 'ganho'       then 'ganho'
    when 'perdido'     then 'perdido'
  end;

  if v_event_code is null then
    raise exception 'IMP-205 cannot map CRM stage % to an event code', new.current_stage_id;
  end if;

  if pg_catalog.length(pg_catalog.btrim(coalesce(v_ghl_location_id, ''))) = 0 then
    raise exception 'IMP-205 ghl_location_id is required for tenant %', new.tenant_id;
  end if;

  -- A oportunidade e bloqueada pelo proprio INSERT/UPDATE. A consulta abaixo,
  -- portanto, torna reentrada na mesma etapa um no-op serializado sem precisar
  -- alterar as tabelas public nem acoplar a ponte ao raw_event_id do Stevo.
  if exists (
    select 1
      from public.events_normalized en
     where en.client_id = new.tenant_id
       and en.opportunity_id = new.id::text
       and en.source_system = 'impuls_crm'
       and en.event_code = v_event_code
  ) then
    return new;
  end if;

  -- Espelha a grafia e o funnel_step mais recentes do GHL. A ponte nao cria
  -- uma nova convencao para os dados historicos.
  select en.event_name, en.funnel_step
    into v_event_name, v_funnel_step
    from public.events_normalized en
   where en.source_system = 'ghl'
     and en.event_code = v_event_code
   order by en.event_datetime desc, en.created_at desc, en.id desc
   limit 1;

  if not found then
    raise exception 'IMP-205 GHL event template is missing for event_code %', v_event_code;
  end if;

  select c.full_name, c.phone_normalized, c.email
    into v_contact_name, v_contact_phone, v_contact_email
    from crm.contacts c
   where c.tenant_id = new.tenant_id
     and c.id = new.contact_id;

  if tg_op = 'INSERT' then
    v_event_datetime := new.opened_at;
  else
    select h.occurred_at
      into v_event_datetime
      from crm.opportunity_stage_history h
     where h.tenant_id = new.tenant_id
       and h.opportunity_id = new.id
       and h.to_stage_id = new.current_stage_id
     order by h.occurred_at desc, h.created_at desc, h.id desc
     limit 1;
    v_event_datetime := coalesce(v_event_datetime, new.updated_at, pg_catalog.now());
  end if;

  insert into public.events_raw (
    source_system,
    event_type,
    location_id,
    location_name,
    contact_id,
    phone,
    email,
    payload,
    processing_status,
    processed_at
  ) values (
    'impuls_crm',
    'opportunity_stage_changed',
    v_ghl_location_id,
    v_location_name,
    new.contact_id::text,
    v_contact_phone,
    v_contact_email,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'tenant_id', new.tenant_id,
      'opportunity_id', new.id,
      'contact_id', new.contact_id,
      'pipeline_version_id', new.pipeline_version_id,
      'stage_id', new.current_stage_id,
      'stage_code', v_stage_code,
      'event_code', v_event_code,
      'stage_version', new.stage_version,
      'occurred_at', v_event_datetime
    )),
    'normalized',
    pg_catalog.now()
  )
  returning id into v_raw_event_id;

  insert into public.events_normalized (
    raw_event_id,
    client_id,
    ghl_location_id,
    ghl_location_name,
    client_name,
    event_code,
    event_name,
    funnel_step,
    event_datetime,
    source_system,
    source_event_type,
    contact_id,
    full_name,
    phone,
    email,
    conversion_source,
    entry_point_conversion_source,
    source_type,
    source_id,
    source_url,
    source_ads,
    ad_title,
    ctwa_clid,
    opportunity_id,
    pipeline_id,
    pipeline_stage,
    status,
    received_at,
    location_id,
    location_name,
    payload
  ) values (
    v_raw_event_id,
    new.tenant_id,
    v_ghl_location_id,
    v_location_name,
    v_client_name,
    v_event_code,
    v_event_name,
    v_funnel_step,
    v_event_datetime,
    'impuls_crm',
    'crm_stage_changed',
    new.contact_id::text,
    v_contact_name,
    v_contact_phone,
    v_contact_email,
    new.conversion_source,
    new.entry_point_conversion_source,
    case when new.meta_ad_id is not null then 'ad' else null end,
    new.meta_ad_id,
    new.source_url,
    new.meta_ad_id is not null,
    new.ad_title,
    new.ctwa_clid,
    new.id::text,
    new.pipeline_version_id::text,
    v_stage_code,
    new.status,
    pg_catalog.now(),
    v_ghl_location_id,
    v_location_name,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'tenant_id', new.tenant_id,
      'opportunity_id', new.id,
      'contact_id', new.contact_id,
      'stage_code', v_stage_code,
      'stage_version', new.stage_version
    ))
  )
  returning id into v_normalized_id;

  v_route := case
    when new.ctwa_clid is not null
      or new.conversion_source in ('FB_Ads', 'FB_Post')
    then 'whatsapp_bm'
    else 'standard'
  end;

  v_meta_event_name := case v_event_code
    when 'lead'     then case when v_route = 'whatsapp_bm' then 'LeadSubmitted' else 'Lead' end
    when 'agendado' then case when v_route = 'whatsapp_bm' then 'QualifiedLead' else 'Schedule' end
    when 'ganho'    then 'Purchase'
    else v_event_name
  end;

  insert into public.conversion_outbox (
    normalized_event_id,
    ghl_location_id,
    contact_id,
    event_code,
    platform,
    route,
    meta_event_name,
    payload,
    status
  ) values (
    v_normalized_id,
    v_ghl_location_id,
    new.contact_id::text,
    v_event_code,
    'meta',
    v_route,
    v_meta_event_name,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'event_id', v_normalized_id,
      'event_code', v_event_code,
      'platform', 'meta',
      'route', v_route,
      'meta_event_name', v_meta_event_name,
      'platform_event_name', v_meta_event_name,
      'lead_origem', new.conversion_source,
      'lead_entrada', 'WhatsApp',
      'user_data_source', pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'contact_id', new.contact_id,
        'full_name', v_contact_name,
        'phone', v_contact_phone,
        'email', v_contact_email
      )),
      'attribution', pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'ctwa_clid', new.ctwa_clid,
        'conversion_source', new.conversion_source,
        'entry_point_conversion_source', new.entry_point_conversion_source,
        'source_id', new.meta_ad_id,
        'source_url', new.source_url,
        'ad_title', new.ad_title
      )),
      'custom_data', pg_catalog.jsonb_build_object(
        'opportunity_id', new.id,
        'stage_code', v_stage_code,
        'stage_version', new.stage_version
      ),
      'routing_checks', pg_catalog.jsonb_build_object(
        'has_ctwa_clid', new.ctwa_clid is not null,
        'has_meta_ad_id', new.meta_ad_id is not null
      )
    )),
    'pending'
  );

  return new;
end;
$fn$;

revoke all on function crm.emit_opportunity_stage_event() from public, anon, authenticated, service_role;
comment on function crm.emit_opportunity_stage_event() is
  'IMP-205: bridge transacional de movimentos do CRM para events_raw, events_normalized e conversion_outbox. Inerte enquanto clients_base.crm_emits_conversions for false.';

-- A tabela e os eventos sao removidos antes de restaurar NOT NULL.
delete from public.events_normalized
 where source_system = 'impuls_crm' and ghl_location_id is null;
set constraints all immediate;

drop table if exists crm.event_map;
alter table public.clients_base drop column if exists crm_feeds_dashboard;
alter table public.events_normalized alter column ghl_location_id set not null;

commit;
