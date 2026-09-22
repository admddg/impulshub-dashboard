


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "crm";


ALTER SCHEMA "crm" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "private";


ALTER SCHEMA "private" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "crm"."bump_stage_version"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.current_stage_id is distinct from old.current_stage_id then
    new.stage_version := old.stage_version + 1;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "crm"."bump_stage_version"() OWNER TO "postgres";


COMMENT ON FUNCTION "crm"."bump_stage_version"() IS 'Garante stage_version = anterior + 1 em qualquer troca de etapa, inclusive movimentos automaticos do parser.';



CREATE OR REPLACE FUNCTION "crm"."can_write"("p_tenant_id" "uuid", "p_profile_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select case
    when not crm.is_member(p_tenant_id) then false
    else coalesce((
      select cu.is_active and pg_catalog.lower(cu.role) <> 'viewer'
        from public.client_users cu
       where cu.client_id = p_tenant_id
         and cu.user_id = p_profile_id
       limit 1
    ), false)
  end
$$;


ALTER FUNCTION "crm"."can_write"("p_tenant_id" "uuid", "p_profile_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."emit_opportunity_stage_event"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
$$;


ALTER FUNCTION "crm"."emit_opportunity_stage_event"() OWNER TO "postgres";


COMMENT ON FUNCTION "crm"."emit_opportunity_stage_event"() IS 'IMP-216: alimenta events_normalized por crm_feeds_dashboard; envia Meta por crm_emits_conversions. Google fica para IMP-230.';



CREATE OR REPLACE FUNCTION "crm"."is_member"("p_tenant_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "crm"."is_member"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."reject_append_only_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  raise exception 'append-only table cannot be mutated: %', tg_table_name;
end;
$$;


ALTER FUNCTION "crm"."reject_append_only_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."restrict_outcome_revision"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "crm"."restrict_outcome_revision"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."stevo_ctwa_clid"("p_conversion_data" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
declare
  decoded text;
begin
  if p_conversion_data is null or pg_catalog.btrim(p_conversion_data) = '' then
    return null;
  end if;

  begin
    decoded := pg_catalog.convert_from(pg_catalog.decode(p_conversion_data, 'base64'), 'UTF8');
  exception when others then
    return null;
  end;

  if decoded !~ '^Af[A-Za-z0-9_-]{10,}$' then
    return null;
  end if;

  return decoded;
end;
$_$;


ALTER FUNCTION "crm"."stevo_ctwa_clid"("p_conversion_data" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."stevo_message_body"("p_message" "jsonb", "p_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select case
    when pg_catalog.length(pg_catalog.btrim(coalesce(p_text, ''))) > 0 then p_text
    when p_message ? 'audioMessage'    then '[audio]'
    when p_message ? 'imageMessage'    then '[imagem]'
    when p_message ? 'videoMessage'    then '[video]'
    when p_message ? 'documentMessage' then '[documento]'
    when p_message ? 'stickerMessage'  then '[figurinha]'
    when p_message ? 'locationMessage' then '[localizacao]'
    when p_message ? 'contactMessage'  then '[contato]'
    when p_message ? 'reactionMessage' then '[reacao]'
    else '[mensagem sem texto]'
  end
$$;


ALTER FUNCTION "crm"."stevo_message_body"("p_message" "jsonb", "p_text" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."stevo_parse_messages"("p_limit" integer DEFAULT 20000) RETURNS TABLE("lidos" integer, "contatos_criados" integer, "oportunidades_criadas" integer, "atendimentos" integer, "ignorados_grupo" integer, "ignorados_lid" integer, "ignorados_duplicados" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  ev record;
  v_pipeline_id uuid; v_stage_lead uuid; v_stage_atendim uuid;
  v_chat text; v_dominio text; v_numero text;
  v_de_mim boolean; v_grupo boolean; v_push text; v_texto text;
  v_msg jsonb; v_ctx jsonb; v_ar jsonb;
  v_msg_id text; v_ocorrido timestamptz;
  v_conv_source text; v_ctwa text; v_ad_id text; v_src_url text;
  v_titulo text; v_entry text;
  v_contato_id uuid; v_oportunidade_id uuid; v_etapa_atual uuid;
  v_atividade_id uuid; v_inserido integer;
begin
  lidos := 0; contatos_criados := 0; oportunidades_criadas := 0; atendimentos := 0;
  ignorados_grupo := 0; ignorados_lid := 0; ignorados_duplicados := 0;

  select v.id into v_pipeline_id from crm.global_pipeline_versions v where v.status='active';
  select s.id into v_stage_lead from crm.global_pipeline_stages s
   where s.pipeline_version_id=v_pipeline_id and s.code='lead';
  select s.id into v_stage_atendim from crm.global_pipeline_stages s
   where s.pipeline_version_id=v_pipeline_id and s.code='atendimento';
  if v_pipeline_id is null or v_stage_lead is null or v_stage_atendim is null then
    raise exception 'pipeline global ativo nao encontrado';
  end if;

  for ev in
    select r.id, r.client_id, r.payload, r.payload_hash, r.event_timestamp, r.received_at
      from public.stevo_events_raw r
     where r.event_type='Message' and r.parse_status='raw' and r.client_id is not null
       and exists (select 1 from crm.tenants t where t.id=r.client_id)
     order by coalesce(r.event_timestamp, r.received_at), r.received_at, r.id
     limit p_limit
  loop
    lidos := lidos + 1;
    v_chat := ev.payload #>> '{data,Info,Chat}';
    v_grupo := (ev.payload #>> '{data,Info,IsGroup}')::boolean;
    v_de_mim := (ev.payload #>> '{data,Info,IsFromMe}')::boolean;
    v_push := nullif(pg_catalog.btrim(coalesce(ev.payload #>> '{data,Info,PushName}','')),'');
    v_texto := ev.payload #>> '{data,text}';
    v_msg := ev.payload #> '{data,Message}';
    v_msg_id := ev.payload #>> '{data,Info,ID}';
    v_ocorrido := coalesce(ev.event_timestamp, ev.received_at);

    v_ctx := ev.payload #> '{data,Message,extendedTextMessage,contextInfo}';
    v_ar  := v_ctx #> '{externalAdReply}';
    v_conv_source := v_ctx #>> '{conversionSource}';
    v_ctwa        := crm.stevo_ctwa_clid(v_ctx #>> '{conversionData}');
    v_entry       := v_ctx #>> '{entryPointConversionSource}';
    v_ad_id       := v_ar  #>> '{sourceID}';
    v_src_url     := v_ar  #>> '{sourceURL}';
    v_titulo      := v_ar  #>> '{title}';

    if coalesce(v_grupo,false) then
      update public.stevo_events_raw set parse_status='skipped_group' where id=ev.id;
      ignorados_grupo := ignorados_grupo+1; continue;
    end if;
    if v_chat is null or v_msg_id is null then
      update public.stevo_events_raw set parse_status='skipped_incomplete' where id=ev.id; continue;
    end if;

    v_numero := pg_catalog.split_part(v_chat,'@',1);
    v_dominio := pg_catalog.split_part(v_chat,'@',2);
    if v_dominio <> 's.whatsapp.net' then
      update public.stevo_events_raw set parse_status='skipped_lid' where id=ev.id;
      ignorados_lid := ignorados_lid+1; continue;
    end if;

    insert into crm.processed_events (tenant_id, raw_event_id, source, external_id, payload_hash, status)
    values (ev.client_id, ev.id, 'stevo', v_msg_id, ev.payload_hash, 'processing')
    on conflict do nothing;
    get diagnostics v_inserido = row_count;
    if v_inserido = 0 then
      update public.stevo_events_raw set parse_status='duplicate' where id=ev.id;
      ignorados_duplicados := ignorados_duplicados+1; continue;
    end if;

    select ci.contact_id into v_contato_id from crm.contact_identities ci
     where ci.tenant_id=ev.client_id and ci.kind='phone' and ci.value_normalized=v_numero;

    if v_contato_id is null then
      insert into crm.contacts (tenant_id, full_name, phone_normalized)
      values (ev.client_id, coalesce(v_push, v_numero), v_numero) returning id into v_contato_id;
      insert into crm.contact_identities (tenant_id, contact_id, kind, value_normalized, provider)
      values (ev.client_id, v_contato_id, 'phone', v_numero, 'stevo');
      contatos_criados := contatos_criados+1;
    elsif v_push is not null and not v_de_mim then
      update crm.contacts c set full_name=v_push, updated_at=pg_catalog.now()
       where c.tenant_id=ev.client_id and c.id=v_contato_id and c.full_name is distinct from v_push;
    end if;

    v_oportunidade_id := null; v_etapa_atual := null;
    select o.id, o.current_stage_id into v_oportunidade_id, v_etapa_atual
      from crm.opportunities o
     where o.tenant_id=ev.client_id and o.contact_id=v_contato_id and o.status='open'
     order by o.created_at desc limit 1;

    if v_oportunidade_id is null then
      insert into crm.opportunities
        (tenant_id, contact_id, pipeline_version_id, current_stage_id, title, status, opened_at,
         ctwa_clid, conversion_source, meta_ad_id, source_url, ad_title, entry_point_conversion_source)
      values (ev.client_id, v_contato_id, v_pipeline_id, v_stage_lead,
              coalesce(v_push, v_numero), 'open', v_ocorrido,
              v_ctwa, v_conv_source, v_ad_id, v_src_url, v_titulo, v_entry)
      returning id into v_oportunidade_id;
      v_etapa_atual := v_stage_lead;

      insert into crm.opportunity_stage_history
        (tenant_id, opportunity_id, from_stage_id, to_stage_id, transition_type, origin, occurred_at)
      values (ev.client_id, v_oportunidade_id, null, v_stage_lead, 'automatic', 'sistema', v_ocorrido);

      insert into crm.opportunity_milestones
        (tenant_id, opportunity_id, kind, origin, evidence, occurred_at)
      values (ev.client_id, v_oportunidade_id, 'lead_received', 'sistema',
              'whatsapp:'||v_conv_source||coalesce(' ad:'||v_ad_id,''), v_ocorrido);
      oportunidades_criadas := oportunidades_criadas+1;
    end if;

    v_atividade_id := null;
    insert into crm.activities
      (tenant_id, contact_id, opportunity_id, raw_event_id, kind, direction, body,
       provider_message_id, sent_confirmed_at, created_at)
    values (ev.client_id, v_contato_id, v_oportunidade_id, ev.id, 'message',
            case when v_de_mim then 'outbound' else 'inbound' end,
            crm.stevo_message_body(v_msg, v_texto), v_msg_id,
            case when v_de_mim then v_ocorrido else null end, v_ocorrido)
    on conflict do nothing returning id into v_atividade_id;

    if v_de_mim and v_oportunidade_id is not null and v_etapa_atual = v_stage_lead then
      insert into crm.opportunity_stage_history
        (tenant_id, opportunity_id, from_stage_id, to_stage_id, transition_type,
         origin, source_activity_id, occurred_at)
      values (ev.client_id, v_oportunidade_id, v_stage_lead, v_stage_atendim,
              'automatic', 'sistema', v_atividade_id, v_ocorrido);
      update crm.opportunities o set current_stage_id=v_stage_atendim, updated_at=pg_catalog.now()
       where o.tenant_id=ev.client_id and o.id=v_oportunidade_id;
      insert into crm.opportunity_milestones
        (tenant_id, opportunity_id, kind, origin, evidence, occurred_at)
      values (ev.client_id, v_oportunidade_id, 'conversation_started', 'sistema',
              'whatsapp:primeira_resposta', v_ocorrido);
      atendimentos := atendimentos+1;
    end if;

    update crm.processed_events pe set status='processed', processed_at=pg_catalog.now()
     where pe.tenant_id=ev.client_id and pe.raw_event_id=ev.id;
    update public.stevo_events_raw set parse_status='processed' where id=ev.id;
  end loop;

  return next;
end;
$$;


ALTER FUNCTION "crm"."stevo_parse_messages"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."validate_activity_raw_tenant"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "crm"."validate_activity_raw_tenant"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."validate_commercial_outcome"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "crm"."validate_commercial_outcome"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."validate_opportunity"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "crm"."validate_opportunity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."validate_opportunity_history_consistency"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "crm"."validate_opportunity_history_consistency"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."validate_opportunity_outcome_consistency"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "crm"."validate_opportunity_outcome_consistency"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."validate_opportunity_owners"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if new.crc_owner_profile_id is not null and not exists (
    select 1 from crm.tenant_memberships tm
     where tm.tenant_id = new.tenant_id and tm.profile_id = new.crc_owner_profile_id
       and tm.status = 'active' and tm.is_assignable
  ) then
    raise exception 'opportunity crc owner must be an active assignable member of the tenant';
  end if;
  if new.sales_owner_profile_id is not null and not exists (
    select 1 from crm.tenant_memberships tm
     where tm.tenant_id = new.tenant_id and tm.profile_id = new.sales_owner_profile_id
       and tm.status = 'active' and tm.is_assignable
  ) then
    raise exception 'opportunity sales owner must be an active assignable member of the tenant';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "crm"."validate_opportunity_owners"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."validate_processed_event"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "crm"."validate_processed_event"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "crm"."validate_stage_history"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "crm"."validate_stage_history"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."can_view_client_financials"("p_client_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select auth.role() = 'service_role'
      or exists (select 1 from private.financial_client_ids() ids where ids.client_id = p_client_id);
$$;


ALTER FUNCTION "private"."can_view_client_financials"("p_client_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."financial_client_ids"() RETURNS TABLE("client_id" "uuid")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select cu.client_id
    from public.client_users cu
   where cu.user_id = (select auth.uid())
     and cu.is_active
     and cu.role = any (array['agency','owner','admin','manager','viewer'])
  union
  select cb.id
    from public.clients_base cb
   where auth.role() = 'service_role';
$$;


ALTER FUNCTION "private"."financial_client_ids"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."is_agency_user"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'private'
    AS $$
  select exists (
    select 1
    from public.client_users cu
    where cu.user_id = auth.uid()
      and cu.is_active = true
      and cu.role = 'agency'
  );
$$;


ALTER FUNCTION "private"."is_agency_user"() OWNER TO "postgres";


COMMENT ON FUNCTION "private"."is_agency_user"() IS 'Retorna true para usuários com vínculo ativo role=agency. EXECUTE concedido a authenticated para uso em views canônicas; o schema private não é exposto pelo PostgREST.';



CREATE OR REPLACE FUNCTION "private"."my_client_ids"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select cu.client_id
  from public.client_users cu
  where cu.user_id = (select auth.uid())
    and cu.is_active
$$;


ALTER FUNCTION "private"."my_client_ids"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."user_can_access_client"("p_client_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  select exists (
    select 1
    from public.client_users cu
    where cu.client_id = p_client_id
      and cu.user_id = (select auth.uid())
      and cu.is_active = true
  );
$$;


ALTER FUNCTION "private"."user_can_access_client"("p_client_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."am_i_agency_user"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'private'
    AS $$
  select private.is_agency_user();
$$;


ALTER FUNCTION "public"."am_i_agency_user"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."am_i_agency_user"() IS 'Gate público e seguro para o frontend identificar usuários internos da agência. Retorna true somente quando auth.uid() possui vínculo ativo com role=agency em client_users.';



CREATE OR REPLACE FUNCTION "public"."crm_board_counts"("p_client_id" "uuid", "p_opened_from" "date" DEFAULT NULL::"date", "p_opened_to" "date" DEFAULT NULL::"date", "p_owner_role" "text" DEFAULT NULL::"text", "p_owner_profile_id" "uuid" DEFAULT NULL::"uuid", "p_unassigned" boolean DEFAULT false, "p_origin" "text" DEFAULT NULL::"text") RETURNS TABLE("client_id" "uuid", "stage_code" "text", "stage_label" "text", "stage_position" smallint, "is_terminal" boolean, "opportunities" bigint)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select t.id, s.code, s.label, s.position, s.is_terminal, count(o.id)
    from crm.tenants t
   cross join crm.global_pipeline_stages s
    join crm.global_pipeline_versions v
      on v.id = s.pipeline_version_id and v.status = 'active'
    left join crm.opportunities o
      on o.tenant_id = t.id
     and o.current_stage_id = s.id
     and (p_opened_from is null or o.opened_at >= p_opened_from::timestamptz)
     and (p_opened_to is null or o.opened_at < (p_opened_to + 1)::timestamptz)
     and (
       (p_unassigned and case p_owner_role
          when 'crc' then o.crc_owner_profile_id is null
          when 'sales' then o.sales_owner_profile_id is null
          else o.crc_owner_profile_id is null and o.sales_owner_profile_id is null
        end)
       or (not p_unassigned and p_owner_profile_id is null)
       or (not p_unassigned and p_owner_profile_id is not null and case p_owner_role
          when 'crc' then o.crc_owner_profile_id = p_owner_profile_id
          when 'sales' then o.sales_owner_profile_id = p_owner_profile_id
          else false
        end)
     )
     and (p_origin is null or p_origin = case
       when o.conversion_source is not null or o.ctwa_clid is not null or o.meta_ad_id is not null
         then 'anuncio' else 'organico' end)
   where t.id = p_client_id
   group by t.id, s.code, s.label, s.position, s.is_terminal
$$;


ALTER FUNCTION "public"."crm_board_counts"("p_client_id" "uuid", "p_opened_from" "date", "p_opened_to" "date", "p_owner_role" "text", "p_owner_profile_id" "uuid", "p_unassigned" boolean, "p_origin" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crm_guard"("p_opportunity_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_tenant uuid;
begin
  select o.tenant_id into v_tenant
    from crm.opportunities o
   where o.id = p_opportunity_id
     for update;

  if v_tenant is null then
    raise exception 'CRM_FORBIDDEN: oportunidade inexistente ou inacessivel';
  end if;

  if not crm.is_member(v_tenant) then
    raise exception 'CRM_FORBIDDEN: sem acesso a este cliente';
  end if;

  if not exists (
    select 1 from public.client_users cu
     where cu.client_id = v_tenant
       and cu.user_id = auth.uid()
       and cu.is_active
       and pg_catalog.lower(cu.role) <> 'viewer'
  ) then
    raise exception 'CRM_FORBIDDEN: papel sem permissao de escrita';
  end if;

  return v_tenant;
end;
$$;


ALTER FUNCTION "public"."crm_guard"("p_opportunity_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "crm"."activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "contact_id" "uuid",
    "opportunity_id" "uuid",
    "actor_profile_id" "uuid",
    "raw_event_id" "uuid",
    "kind" "text" NOT NULL,
    "direction" "text",
    "body" "text",
    "provider_message_id" "text",
    "sent_confirmed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "activities_check" CHECK ((("kind" <> 'message'::"text") OR ("body" IS NOT NULL))),
    CONSTRAINT "activities_direction_check" CHECK (("direction" = ANY (ARRAY['inbound'::"text", 'outbound'::"text", 'internal'::"text"]))),
    CONSTRAINT "activities_kind_check" CHECK (("kind" = ANY (ARRAY['message'::"text", 'note'::"text", 'call'::"text", 'form'::"text", 'system'::"text"])))
);


ALTER TABLE "crm"."activities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "email" "text",
    "phone_normalized" "text",
    "default_owner_profile_id" "uuid",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contacts_check" CHECK ((("phone_normalized" IS NOT NULL) OR ("email" IS NOT NULL))),
    CONSTRAINT "contacts_email_check" CHECK ((("email" IS NULL) OR ("strpos"("email", '@'::"text") > 1))),
    CONSTRAINT "contacts_full_name_check" CHECK (("length"("btrim"("full_name")) > 0)),
    CONSTRAINT "contacts_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'archived'::"text"])))
);


ALTER TABLE "crm"."contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."global_pipeline_stages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pipeline_version_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "label" "text" NOT NULL,
    "position" smallint NOT NULL,
    "is_terminal" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "global_pipeline_stages_check" CHECK ((("code" = ANY (ARRAY['ganho'::"text", 'perdido'::"text"])) = "is_terminal")),
    CONSTRAINT "global_pipeline_stages_code_check" CHECK (("code" = ANY (ARRAY['lead'::"text", 'atendimento'::"text", 'agendado'::"text", 'compareceu'::"text", 'ganho'::"text", 'perdido'::"text"]))),
    CONSTRAINT "global_pipeline_stages_label_check" CHECK (("length"("btrim"("label")) > 0)),
    CONSTRAINT "global_pipeline_stages_position_check" CHECK ((("position" >= 1) AND ("position" <= 6)))
);


ALTER TABLE "crm"."global_pipeline_stages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."opportunities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "previous_opportunity_id" "uuid",
    "pipeline_version_id" "uuid" NOT NULL,
    "current_stage_id" "uuid" NOT NULL,
    "stage_version" integer DEFAULT 0 NOT NULL,
    "title" "text" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "opened_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "closed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ctwa_clid" "text",
    "conversion_source" "text",
    "meta_ad_id" "text",
    "source_url" "text",
    "ad_title" "text",
    "entry_point_conversion_source" "text",
    "crc_owner_profile_id" "uuid",
    "sales_owner_profile_id" "uuid",
    "gclid" "text",
    "gbraid" "text",
    "wbraid" "text",
    "utm_source" "text",
    "utm_medium" "text",
    "utm_campaign" "text",
    "utm_content" "text",
    "utm_term" "text",
    CONSTRAINT "opportunities_check" CHECK ((("status" = 'open'::"text") = ("closed_at" IS NULL))),
    CONSTRAINT "opportunities_stage_version_check" CHECK (("stage_version" >= 0)),
    CONSTRAINT "opportunities_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'won'::"text", 'lost'::"text"]))),
    CONSTRAINT "opportunities_title_check" CHECK (("length"("btrim"("title")) > 0))
);


ALTER TABLE "crm"."opportunities" OWNER TO "postgres";


COMMENT ON COLUMN "crm"."opportunities"."ctwa_clid" IS 'Click ID do click-to-WhatsApp, decodificado de contextInfo.conversionData. Alimenta events_normalized.ctwa_clid e a Conversions API.';



COMMENT ON COLUMN "crm"."opportunities"."meta_ad_id" IS 'externalAdReply.sourceID. Junta com public.meta_ads_daily.ad_id.';



CREATE TABLE IF NOT EXISTS "crm"."profiles" (
    "id" "uuid" NOT NULL,
    "display_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "crm"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clients_base" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ghl_location_id" "text" NOT NULL,
    "ghl_location_name" "text",
    "agency_location_id" "text",
    "client_name" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "timezone" "text" DEFAULT 'America/Sao_Paulo'::"text" NOT NULL,
    "onboarding_status" "text" DEFAULT 'received'::"text",
    "owner_name" "text",
    "owner_email" "text",
    "owner_phone" "text",
    "account_manager" "text",
    "niche" "text" DEFAULT 'odontologia'::"text",
    "meta_pixel_id" "text",
    "meta_page_id" "text",
    "meta_access_token" "text",
    "google_conversion_id" "text",
    "google_label_lead" "text",
    "google_label_avaliacao" "text",
    "google_label_ganho" "text",
    "google_ads_customer_id" "text",
    "google_ads_refresh_token" "text",
    "google_ads_developer_token" "text",
    "ga4_measurement_id" "text",
    "ga4_api_secret" "text",
    "enable_meta_tracking" boolean DEFAULT true NOT NULL,
    "enable_google_tracking" boolean DEFAULT false NOT NULL,
    "enable_ga4_tracking" boolean DEFAULT true NOT NULL,
    "website_url" "text",
    "spreadsheet_url" "text",
    "notes" "text",
    "onboarding_payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "meta_ad_account_id" "text",
    "meta_account_name" "text",
    "meta_graph_api_version" "text" DEFAULT 'v23.0'::"text",
    "meta_token_strategy" "text" DEFAULT 'agency'::"text",
    "meta_ad_accounts" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "google_ads_accounts" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "google_manager_customer_id" "text",
    "google_token_strategy" "text" DEFAULT 'agency_oauth'::"text",
    "google_ads_api_version" "text" DEFAULT 'v24'::"text",
    "meta_enabled" boolean DEFAULT true,
    "meta_standard_enabled" boolean DEFAULT true,
    "meta_whatsapp_enabled" boolean DEFAULT true,
    "meta_dataset_id" "text",
    "meta_waba_id" "text",
    "default_currency" "text" DEFAULT 'BRL'::"text",
    "meta_test_event_code" "text",
    "google_conversion_action_lead" "text",
    "google_conversion_action_agendado" "text",
    "google_conversion_action_ganho" "text",
    "google_offline_enabled" boolean DEFAULT true,
    "google_enhanced_conversions_enabled" boolean DEFAULT true,
    "google_ads_dispatch_method" "text" DEFAULT 'data_manager_api'::"text",
    "google_data_manager_enabled" boolean DEFAULT true,
    "google_data_manager_api_version" "text" DEFAULT 'v1'::"text",
    "google_data_manager_destination_id" "text",
    "google_data_manager_settings" "jsonb" DEFAULT '{}'::"jsonb",
    "enable_tiktok_tracking" boolean DEFAULT false,
    "tiktok_dispatch_method" "text" DEFAULT 'events_api'::"text",
    "tiktok_pixel_id" "text",
    "tiktok_access_token" "text",
    "tiktok_ad_account_id" "text",
    "tiktok_api_version" "text" DEFAULT 'v1.3'::"text",
    "tiktok_event_lead" "text" DEFAULT 'SubmitForm'::"text",
    "tiktok_event_agendado" "text" DEFAULT 'CompleteRegistration'::"text",
    "tiktok_event_ganho" "text" DEFAULT 'CompletePayment'::"text",
    "tiktok_settings" "jsonb" DEFAULT '{}'::"jsonb",
    "client_slug" "text",
    "currency" "text" DEFAULT 'BRL'::"text",
    "tracking_status" "text" DEFAULT 'pending_config'::"text",
    "tracking_ready" boolean DEFAULT false,
    "meta_ready" boolean DEFAULT false,
    "google_ads_ready" boolean DEFAULT false,
    "meta_ads_sync_ready" boolean DEFAULT false,
    "google_ads_sync_ready" boolean DEFAULT false,
    "sync_ready" boolean DEFAULT false,
    "missing_fields" "jsonb" DEFAULT '[]'::"jsonb",
    "meta_credential_ref" "text",
    "meta_business_id" "text",
    "enable_meta_ads_sync" boolean DEFAULT true,
    "meta_sync_lookback_days" integer DEFAULT 3,
    "google_ads_credential_ref" "text",
    "google_ads_login_customer_id" "text",
    "enable_google_ads_sync" boolean DEFAULT true,
    "google_sync_lookback_days" integer DEFAULT 3,
    "google_conversion_actions_status" "text" DEFAULT 'pending_sync'::"text",
    "meta_ads_sync_accounts" "jsonb" DEFAULT '[]'::"jsonb",
    "meta_ads_sync_accounts_count" integer DEFAULT 0,
    "meta_ads_last_backfill_at" timestamp with time zone,
    "google_ads_last_backfill_at" timestamp with time zone,
    "meta_ads_last_sync_at" timestamp with time zone,
    "google_ads_last_sync_at" timestamp with time zone,
    "media_backfill_status" "text" DEFAULT 'pending'::"text",
    "media_backfill_error" "jsonb",
    "google_ads_backfill_status" "text" DEFAULT 'pending'::"text",
    "google_ads_backfill_error" "jsonb",
    "crm_emits_conversions" boolean DEFAULT false NOT NULL,
    "crm_feeds_dashboard" boolean DEFAULT true NOT NULL,
    "form_intake_token" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."clients_base" OWNER TO "postgres";


COMMENT ON COLUMN "public"."clients_base"."crm_emits_conversions" IS 'Quando true, movimentos de etapa no schema crm emitem conversao. Mantenha false enquanto o cliente emitir pelo GHL: os dois caminhos juntos duplicam a conversao na Meta.';



COMMENT ON COLUMN "public"."clients_base"."crm_feeds_dashboard" IS 'Quando true, movimentos do CRM alimentam events_normalized. Deve permanecer false em clientes cujo GHL ja alimenta o dashboard, para evitar duplicacao.';



CREATE TABLE IF NOT EXISTS "public"."meta_ads_daily" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "account_id" "text" NOT NULL,
    "account_name" "text",
    "campaign_id" "text" NOT NULL,
    "campaign_name" "text",
    "adset_id" "text" NOT NULL,
    "adset_name" "text",
    "ad_id" "text" NOT NULL,
    "ad_name" "text",
    "impressions" integer DEFAULT 0,
    "reach" integer DEFAULT 0,
    "frequency" numeric DEFAULT 0,
    "clicks" integer DEFAULT 0,
    "inline_link_clicks" integer DEFAULT 0,
    "unique_clicks" integer DEFAULT 0,
    "spend" numeric DEFAULT 0,
    "cpc" numeric DEFAULT 0,
    "cpm" numeric DEFAULT 0,
    "ctr" numeric DEFAULT 0,
    "leads" numeric DEFAULT 0,
    "purchases" numeric DEFAULT 0,
    "purchase_value" numeric DEFAULT 0,
    "conversions_count" numeric DEFAULT 0,
    "conversions_value" numeric DEFAULT 0,
    "actions_raw" "jsonb",
    "action_values_raw" "jsonb",
    "conversions_raw" "jsonb",
    "conversion_values_raw" "jsonb",
    "source_payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "creative_id" "text",
    "creative_name" "text",
    "ad_status" "text",
    "ad_effective_status" "text",
    "effective_object_story_id" "text",
    "thumbnail_url" "text",
    "image_url" "text",
    "creative_url" "text",
    "destination_url" "text",
    "primary_text" "text",
    "headline" "text",
    "image_hash" "text",
    "video_id" "text",
    "url_tags" "text",
    "object_story_spec" "jsonb",
    "asset_feed_spec" "jsonb",
    "creative_raw" "jsonb",
    "ad_raw" "jsonb",
    "lead_forms" numeric DEFAULT 0,
    "messaging_conversations_started" numeric DEFAULT 0,
    "pixel_leads" numeric DEFAULT 0,
    "custom_conversions" numeric DEFAULT 0,
    "platform_results" numeric DEFAULT 0,
    "platform_result_type" "text",
    "meta_lead_forms" numeric DEFAULT 0,
    "meta_messaging_conversations_started" numeric DEFAULT 0,
    "meta_platform_conversions" numeric DEFAULT 0
);


ALTER TABLE "public"."meta_ads_daily" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_meta_ads_v2" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "id",
    "client_id",
    "client_name",
    "client_slug",
    "date",
    "account_id",
    "account_name",
    "campaign_id",
    "campaign_name",
    "adset_id",
    "adset_name",
    "ad_id",
    "ad_name",
    "ad_status",
    "ad_effective_status",
    "creative_id",
    "creative_name",
    "effective_object_story_id",
    "thumbnail_url",
    "image_url",
    "creative_url",
    "destination_url",
    "primary_text",
    "headline",
    "image_hash",
    "impressions",
    "reach",
    "frequency",
    "clicks",
    "inline_link_clicks",
    "unique_clicks",
    "spend",
    "cpc",
    "cpm",
    "ctr",
    "leads",
    "purchases",
    "purchase_value",
    "conversions_count",
    "conversions_value",
    "created_at",
    "updated_at"
   FROM ( SELECT "md"."id",
            "md"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "md"."date",
            "md"."account_id",
            "md"."account_name",
            "md"."campaign_id",
            "md"."campaign_name",
            "md"."adset_id",
            "md"."adset_name",
            "md"."ad_id",
            "md"."ad_name",
            "md"."ad_status",
            "md"."ad_effective_status",
            "md"."creative_id",
            "md"."creative_name",
            "md"."effective_object_story_id",
            "md"."thumbnail_url",
            "md"."image_url",
            "md"."creative_url",
            "md"."destination_url",
            "md"."primary_text",
            "md"."headline",
            "md"."image_hash",
            "md"."impressions",
            "md"."reach",
            "md"."frequency",
            "md"."clicks",
            "md"."inline_link_clicks",
            "md"."unique_clicks",
            "md"."spend",
            "md"."cpc",
            "md"."cpm",
            "md"."ctr",
            "md"."leads",
            "md"."purchases",
            "md"."purchase_value",
            "md"."conversions_count",
            "md"."conversions_value",
            "md"."created_at",
            "md"."updated_at"
           FROM ("public"."meta_ads_daily" "md"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "md"."client_id")))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_meta_ads_v2" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_meta_ads_v2" IS 'CANONICAL: fonte detalhada Meta Ads por anúncio e dia.';



CREATE OR REPLACE VIEW "public"."v_crm_cards_v1" WITH ("security_invoker"='true') AS
 SELECT "o"."tenant_id" AS "client_id",
    "o"."id" AS "opportunity_id",
    "o"."contact_id",
    "c"."full_name" AS "contact_name",
    "c"."phone_normalized",
        CASE
            WHEN ("c"."phone_normalized" IS NOT NULL) THEN ('https://wa.me/'::"text" || "c"."phone_normalized")
            ELSE NULL::"text"
        END AS "whatsapp_url",
    "o"."title",
    "s"."code" AS "stage_code",
    "s"."label" AS "stage_label",
    "s"."position" AS "stage_position",
    "s"."is_terminal",
    "o"."status",
    "o"."stage_version",
    "o"."crc_owner_profile_id",
    "crc"."display_name" AS "crc_owner_name",
    "o"."sales_owner_profile_id",
    "sales"."display_name" AS "sales_owner_name",
    "o"."opened_at",
    "o"."closed_at",
    ( SELECT "max"("a"."created_at") AS "max"
           FROM "crm"."activities" "a"
          WHERE (("a"."tenant_id" = "o"."tenant_id") AND ("a"."contact_id" = "o"."contact_id"))) AS "last_activity_at",
        CASE
            WHEN (("o"."conversion_source" IS NOT NULL) OR ("o"."ctwa_clid" IS NOT NULL) OR ("o"."meta_ad_id" IS NOT NULL)) THEN 'anuncio'::"text"
            ELSE 'organico'::"text"
        END AS "origem",
    "o"."meta_ad_id",
    "ad"."ad_name",
    "ad"."adset_name",
    "ad"."campaign_name",
    "ad"."creative_name",
    "ad"."thumbnail_url",
    "o"."ctwa_clid",
    "o"."conversion_source",
    "o"."entry_point_conversion_source",
    "o"."source_url",
    "o"."ad_title"
   FROM ((((("crm"."opportunities" "o"
     JOIN "crm"."contacts" "c" ON ((("c"."tenant_id" = "o"."tenant_id") AND ("c"."id" = "o"."contact_id"))))
     JOIN "crm"."global_pipeline_stages" "s" ON (("s"."id" = "o"."current_stage_id")))
     LEFT JOIN "crm"."profiles" "crc" ON (("crc"."id" = "o"."crc_owner_profile_id")))
     LEFT JOIN "crm"."profiles" "sales" ON (("sales"."id" = "o"."sales_owner_profile_id")))
     LEFT JOIN LATERAL ( SELECT "m"."ad_name",
            "m"."adset_name",
            "m"."campaign_name",
            "m"."creative_name",
            "m"."thumbnail_url"
           FROM "public"."v_meta_ads_v2" "m"
          WHERE (("m"."client_id" = "o"."tenant_id") AND ("m"."ad_id" = "o"."meta_ad_id"))
          ORDER BY "m"."date" DESC
         LIMIT 1) "ad" ON (("o"."meta_ad_id" IS NOT NULL)));


ALTER VIEW "public"."v_crm_cards_v1" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crm_move_stage"("p_opportunity_id" "uuid", "p_to_stage_code" "text", "p_expected_stage_version" integer, "p_reason" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."v_crm_cards_v1"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_tenant uuid;
  v_from_pos smallint; v_from_id uuid; v_status text; v_version integer;
  v_to_id uuid; v_to_pos smallint; v_pipeline uuid;
  v_milestone text;
begin
  v_tenant := public.crm_guard(p_opportunity_id);

  select o.current_stage_id, o.status, o.stage_version, o.pipeline_version_id
    into v_from_id, v_status, v_version, v_pipeline
    from crm.opportunities o where o.id = p_opportunity_id;

  if v_version is distinct from p_expected_stage_version then
    raise exception 'CRM_STAGE_CONFLICT: o card foi movido por outra pessoa';
  end if;
  if v_status <> 'open' then
    raise exception 'CRM_TERMINAL: oportunidade ja encerrada';
  end if;
  if p_to_stage_code in ('ganho', 'perdido') then
    raise exception 'CRM_USE_OUTCOME_RPC: use crm_register_won ou crm_register_lost';
  end if;

  select s.id, s.position into v_to_id, v_to_pos
    from crm.global_pipeline_stages s
   where s.pipeline_version_id = v_pipeline and s.code = p_to_stage_code;
  if v_to_id is null then
    raise exception 'CRM_INVALID_STAGE: etapa desconhecida';
  end if;

  select s.position into v_from_pos
    from crm.global_pipeline_stages s where s.id = v_from_id;

  if v_to_pos < v_from_pos
     and pg_catalog.length(pg_catalog.btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'CRM_REASON_REQUIRED: regressao exige motivo';
  end if;

  insert into crm.opportunity_stage_history
    (tenant_id, opportunity_id, from_stage_id, to_stage_id,
     transition_type, origin, actor_profile_id, reason, occurred_at)
  values
    (v_tenant, p_opportunity_id, v_from_id, v_to_id,
     'manual', 'manual', auth.uid(), p_reason, pg_catalog.now());

  update crm.opportunities o
     set current_stage_id = v_to_id,
         stage_version = o.stage_version + 1,
         updated_at = pg_catalog.now()
   where o.id = p_opportunity_id;

  v_milestone := case p_to_stage_code
                   when 'agendado' then 'appointment'
                   when 'compareceu' then 'attendance' end;

  if v_milestone is not null then
    insert into crm.opportunity_milestones
      (tenant_id, opportunity_id, kind, origin, actor_profile_id, evidence, occurred_at)
    values
      (v_tenant, p_opportunity_id, v_milestone, 'manual', auth.uid(),
       coalesce(p_reason, 'movimento manual pelo painel'), pg_catalog.now());
  end if;

  return query select * from public.v_crm_cards_v1 c
                where c.opportunity_id = p_opportunity_id;
end;
$$;


ALTER FUNCTION "public"."crm_move_stage"("p_opportunity_id" "uuid", "p_to_stage_code" "text", "p_expected_stage_version" integer, "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crm_register_lost"("p_opportunity_id" "uuid", "p_loss_reason_code" "text", "p_expected_stage_version" integer, "p_note" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."v_crm_cards_v1"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_tenant uuid; v_from_id uuid; v_status text; v_version integer; v_pipeline uuid;
  v_perdido uuid; v_reason_id uuid; v_requires_note boolean; v_label text; v_evidence text;
begin
  v_tenant := public.crm_guard(p_opportunity_id);

  select o.current_stage_id, o.status, o.stage_version, o.pipeline_version_id
    into v_from_id, v_status, v_version, v_pipeline
    from crm.opportunities o where o.id = p_opportunity_id;

  if v_version is distinct from p_expected_stage_version then
    raise exception 'CRM_STAGE_CONFLICT: o card foi movido por outra pessoa';
  end if;
  if v_status <> 'open' then
    raise exception 'CRM_TERMINAL: oportunidade ja encerrada';
  end if;

  select r.id, r.requires_note, r.label
    into v_reason_id, v_requires_note, v_label
    from crm.canonical_loss_reasons r
   where r.code = p_loss_reason_code and r.active;
  if v_reason_id is null then
    raise exception 'CRM_INVALID_REASON: motivo de perda desconhecido ou inativo';
  end if;

  if v_requires_note
     and pg_catalog.length(pg_catalog.btrim(coalesce(p_note, ''))) = 0 then
    raise exception 'CRM_NOTE_REQUIRED: este motivo exige observacao';
  end if;

  -- origin='manual' exige evidence nao-vazio tambem aqui.
  v_evidence := coalesce(nullif(pg_catalog.btrim(coalesce(p_note, '')), ''), v_label);

  select s.id into v_perdido from crm.global_pipeline_stages s
   where s.pipeline_version_id = v_pipeline and s.code = 'perdido';

  insert into crm.opportunity_stage_history
    (tenant_id, opportunity_id, from_stage_id, to_stage_id,
     transition_type, origin, actor_profile_id, reason, occurred_at)
  values
    (v_tenant, p_opportunity_id, v_from_id, v_perdido,
     'manual', 'manual', auth.uid(), v_evidence, pg_catalog.now());

  update crm.opportunities o
     set current_stage_id = v_perdido, status = 'lost',
         closed_at = pg_catalog.now(),
         stage_version = o.stage_version + 1,
         updated_at = pg_catalog.now()
   where o.id = p_opportunity_id;

  -- Perda obriga value_status='pending'. Nao existe perdido com valor.
  insert into crm.commercial_outcomes
    (tenant_id, opportunity_id, outcome, origin, actor_profile_id,
     loss_reason_id, evidence, value, value_status, currency, is_current, occurred_at)
  values
    (v_tenant, p_opportunity_id, 'lost', 'manual', auth.uid(),
     v_reason_id, v_evidence, null, 'pending', null, true, pg_catalog.now());

  return query select * from public.v_crm_cards_v1 c
                where c.opportunity_id = p_opportunity_id;
end;
$$;


ALTER FUNCTION "public"."crm_register_lost"("p_opportunity_id" "uuid", "p_loss_reason_code" "text", "p_expected_stage_version" integer, "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crm_register_won"("p_opportunity_id" "uuid", "p_evidence" "text", "p_expected_stage_version" integer, "p_value" numeric DEFAULT NULL::numeric, "p_currency" "text" DEFAULT 'BRL'::"text") RETURNS SETOF "public"."v_crm_cards_v1"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_tenant uuid; v_from_id uuid; v_status text; v_version integer; v_pipeline uuid;
  v_ganho uuid; v_value numeric; v_value_status text; v_currency text;
begin
  v_tenant := public.crm_guard(p_opportunity_id);

  select o.current_stage_id, o.status, o.stage_version, o.pipeline_version_id
    into v_from_id, v_status, v_version, v_pipeline
    from crm.opportunities o where o.id = p_opportunity_id;

  if v_version is distinct from p_expected_stage_version then
    raise exception 'CRM_STAGE_CONFLICT: o card foi movido por outra pessoa';
  end if;
  if v_status <> 'open' then
    raise exception 'CRM_TERMINAL: oportunidade ja encerrada';
  end if;
  if pg_catalog.length(pg_catalog.btrim(coalesce(p_evidence, ''))) = 0 then
    raise exception 'CRM_EVIDENCE_REQUIRED: observacao obrigatoria no ganho';
  end if;

  -- Valor ausente permanece pendente, nunca zero.
  if p_value is null then
    v_value := null; v_value_status := 'pending'; v_currency := null;
  elsif p_value > 0 then
    v_value := p_value; v_value_status := 'valid'; v_currency := coalesce(p_currency, 'BRL');
  else
    raise exception 'CRM_INVALID_VALUE: valor deve ser positivo ou nao informado';
  end if;

  select s.id into v_ganho from crm.global_pipeline_stages s
   where s.pipeline_version_id = v_pipeline and s.code = 'ganho';

  insert into crm.opportunity_stage_history
    (tenant_id, opportunity_id, from_stage_id, to_stage_id,
     transition_type, origin, actor_profile_id, occurred_at)
  values
    (v_tenant, p_opportunity_id, v_from_id, v_ganho,
     'manual', 'manual', auth.uid(), pg_catalog.now());

  update crm.opportunities o
     set current_stage_id = v_ganho, status = 'won',
         closed_at = pg_catalog.now(),
         stage_version = o.stage_version + 1,
         updated_at = pg_catalog.now()
   where o.id = p_opportunity_id;

  insert into crm.commercial_outcomes
    (tenant_id, opportunity_id, outcome, origin, actor_profile_id,
     evidence, value, value_status, currency, is_current, occurred_at)
  values
    (v_tenant, p_opportunity_id, 'won', 'manual', auth.uid(),
     p_evidence, v_value, v_value_status, v_currency, true, pg_catalog.now());

  insert into crm.opportunity_milestones
    (tenant_id, opportunity_id, kind, origin, actor_profile_id, evidence, occurred_at)
  values
    (v_tenant, p_opportunity_id, 'sale', 'manual', auth.uid(), p_evidence, pg_catalog.now());

  if v_value is not null then
    insert into crm.opportunity_milestones
      (tenant_id, opportunity_id, kind, origin, actor_profile_id, evidence, occurred_at)
    values
      (v_tenant, p_opportunity_id, 'revenue', 'manual', auth.uid(),
       v_currency || ' ' || v_value::text, pg_catalog.now());
  end if;

  return query select * from public.v_crm_cards_v1 c
                where c.opportunity_id = p_opportunity_id;
end;
$$;


ALTER FUNCTION "public"."crm_register_won"("p_opportunity_id" "uuid", "p_evidence" "text", "p_expected_stage_version" integer, "p_value" numeric, "p_currency" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crm_set_owner"("p_opportunity_id" "uuid", "p_role" "text", "p_owner_profile_id" "uuid") RETURNS SETOF "public"."v_crm_cards_v1"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_tenant uuid;
begin
  v_tenant := public.crm_guard(p_opportunity_id);

  if p_role not in ('crc', 'sales') then
    raise exception 'CRM_INVALID_OWNER_ROLE: papel de dono deve ser crc ou sales';
  end if;

  if p_owner_profile_id is not null and not exists (
    select 1
      from crm.tenant_memberships tm
     where tm.tenant_id = v_tenant
       and tm.profile_id = p_owner_profile_id
       and tm.status = 'active'
       and tm.is_assignable
  ) then
    raise exception 'CRM_INVALID_OWNER: pessoa nao pode ser dona deste card';
  end if;

  if p_role = 'crc' then
    update crm.opportunities o
       set crc_owner_profile_id = p_owner_profile_id,
           updated_at = pg_catalog.now()
     where o.id = p_opportunity_id;
  else
    update crm.opportunities o
       set sales_owner_profile_id = p_owner_profile_id,
           updated_at = pg_catalog.now()
     where o.id = p_opportunity_id;
  end if;

  return query select * from public.v_crm_cards_v1 c
                where c.opportunity_id = p_opportunity_id;
end;
$$;


ALTER FUNCTION "public"."crm_set_owner"("p_opportunity_id" "uuid", "p_role" "text", "p_owner_profile_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_external_raw_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."fn_external_raw_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_stevo_events_raw_slim"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  new.payload := new.payload - 'instanceToken';

  if new.payload #> '{data,Message}' is not null then
    new.payload := jsonb_set(
      new.payload,
      '{data,Message}',
      (new.payload #> '{data,Message}') - 'base64' - 'messageContextInfo'
    );
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."fn_stevo_events_raw_slim"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_workflow_execution_logs_set_duration"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.finished_at is not null then
    new.duration_ms := extract(epoch from (new.finished_at - new.started_at)) * 1000;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."fn_workflow_execution_logs_set_duration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_client_overview_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date") RETURNS TABLE("client_id" "uuid", "client_name" "text", "client_slug" "text", "period_start" "date", "period_end" "date", "media_days" bigint, "investment" numeric, "investment_is_complete" boolean, "leads" bigint, "paid_attributed_leads" bigint, "meta_ads_leads" bigint, "google_ads_leads" bigint, "unattributed_leads" bigint, "attribution_conflicts" bigint, "primeiras_conversas" bigint, "agendados" bigint, "crm_ganhos" bigint, "acquisition_buying_contacts" bigint, "acquisition_sales" bigint, "cohort_total_sales" bigint, "cohort_sales_without_own_lead" bigint, "acquisition_revenue" numeric, "total_cohort_revenue" numeric, "acquisition_revenue_is_complete" boolean, "cohort_revenue_is_complete" boolean, "closed_sales" bigint, "closed_buying_contacts" bigint, "closed_revenue" numeric, "closed_revenue_is_complete" boolean, "cpl_paid" numeric, "cac_acquisition" numeric, "roas_acquisition" numeric, "roas_total_cohort" numeric)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$

with period_data as (

  select *
  from public.v_client_performance_daily_v2 p

  where p.client_id = p_client_id
    and p.date between p_start_date and p_end_date
),

aggregated as (

  select

    count(*) filter (
      where platform_rows is not null
    )::bigint as media_days,

    sum(reported_spend)
      as investment,

    case
      when count(*) filter (
        where platform_rows is not null
      ) = 0
        then null

      else bool_and(spend_is_complete) filter (
        where platform_rows is not null
      )
    end as investment_is_complete,

    coalesce(
      sum(cohort_leads),
      0
    )::bigint as leads,

    coalesce(
      sum(cohort_paid_attributed_leads),
      0
    )::bigint as paid_attributed_leads,

    coalesce(
      sum(cohort_meta_ads_leads),
      0
    )::bigint as meta_ads_leads,

    coalesce(
      sum(cohort_google_ads_leads),
      0
    )::bigint as google_ads_leads,

    coalesce(
      sum(cohort_unattributed_leads),
      0
    )::bigint as unattributed_leads,

    coalesce(
      sum(cohort_attribution_conflicts),
      0
    )::bigint as attribution_conflicts,

    coalesce(
      sum(cohort_primeiras_conversas),
      0
    )::bigint as primeiras_conversas,

    coalesce(
      sum(cohort_agendados),
      0
    )::bigint as agendados,

    coalesce(
      sum(acquisition_won_contacts),
      0
    )::bigint as acquisition_buying_contacts,

    coalesce(
      sum(acquisition_won_opportunities),
      0
    )::bigint as acquisition_sales,

    coalesce(
      sum(cohort_total_sales),
      0
    )::bigint as cohort_total_sales,

    coalesce(
      sum(cohort_sales_without_own_lead),
      0
    )::bigint as cohort_sales_without_own_lead,

    sum(cohort_confirmed_acquisition_revenue)
      as acquisition_revenue,

    sum(cohort_confirmed_revenue)
      as total_cohort_revenue,

    case
      when coalesce(
        sum(cohort_acquisition_sales),
        0
      ) = 0
        then null

      else bool_and(
        cohort_acquisition_revenue_is_complete
      ) filter (
        where cohort_acquisition_sales > 0
      )
    end as acquisition_revenue_is_complete,

    case
      when coalesce(
        sum(cohort_total_sales),
        0
      ) = 0
        then null

      else bool_and(
        cohort_revenue_is_complete
      ) filter (
        where cohort_total_sales > 0
      )
    end as cohort_revenue_is_complete,

    coalesce(
      sum(closed_sales),
      0
    )::bigint as closed_sales,

    coalesce(
      sum(closed_buying_contacts),
      0
    )::bigint as closed_buying_contacts,

    sum(closed_confirmed_revenue)
      as closed_revenue,

    case
      when coalesce(
        sum(closed_sales),
        0
      ) = 0
        then null

      else bool_and(
        closed_revenue_is_complete
      ) filter (
        where closed_sales > 0
      )
    end as closed_revenue_is_complete

  from period_data
),

journey as (

  select
    count(*) filter (
      where l.has_ganho is true
    )::bigint as crm_ganhos

  from public.v_client_leads_by_stage_v2 l

  where l.client_id = p_client_id
    and l.lead_date between p_start_date and p_end_date
),

metrics as (

  select
    a.*,

    case
      when a.investment_is_complete is true
       and a.investment is not null
       and a.paid_attributed_leads > 0
        then a.investment
             / a.paid_attributed_leads
    end as cpl_paid,

    case
      when a.investment_is_complete is true
       and a.investment is not null
       and a.acquisition_buying_contacts > 0
        then a.investment
             / a.acquisition_buying_contacts
    end as cac_acquisition,

    case
      when a.investment_is_complete is true
       and a.acquisition_revenue_is_complete is true
       and a.investment > 0
        then a.acquisition_revenue
             / a.investment
    end as roas_acquisition,

    case
      when a.investment_is_complete is true
       and a.cohort_revenue_is_complete is true
       and a.investment > 0
        then a.total_cohort_revenue
             / a.investment
    end as roas_total_cohort

  from aggregated a
)

select
  cb.id as client_id,
  cb.client_name,
  cb.client_slug,

  p_start_date as period_start,
  p_end_date as period_end,

  m.media_days,
  m.investment,
  m.investment_is_complete,

  m.leads,
  m.paid_attributed_leads,
  m.meta_ads_leads,
  m.google_ads_leads,
  m.unattributed_leads,
  m.attribution_conflicts,

  m.primeiras_conversas,
  m.agendados,
  j.crm_ganhos,

  m.acquisition_buying_contacts,
  m.acquisition_sales,

  m.cohort_total_sales,
  m.cohort_sales_without_own_lead,

  m.acquisition_revenue,
  m.total_cohort_revenue,

  m.acquisition_revenue_is_complete,
  m.cohort_revenue_is_complete,

  m.closed_sales,
  m.closed_buying_contacts,
  m.closed_revenue,
  m.closed_revenue_is_complete,

  m.cpl_paid,
  m.cac_acquisition,
  m.roas_acquisition,
  m.roas_total_cohort

from public.clients_base cb
cross join metrics m
cross join journey j

where cb.id = p_client_id;

$$;


ALTER FUNCTION "public"."get_client_overview_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_client_overview_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date") IS 'Resumo executivo oficial V2 por cliente e coorte de leads. Retorna mídia, leads, primeiras conversas, agendados, crm_ganhos, compradores, vendas, receita, completude financeira, CPL, CAC e ROAS. crm_ganhos conta contatos da coorte com has_ganho=true e não deve ser substituído por compradores ou vendas. Datas inclusivas.';



CREATE OR REPLACE FUNCTION "public"."get_google_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text" DEFAULT 'account'::"text") RETURNS TABLE("dimension" "text", "group_id" "text", "group_name" "text", "account_id" "text", "account_name" "text", "campaign_id" "text", "campaign_name" "text", "ad_group_id" "text", "ad_group_name" "text", "ad_id" "text", "ad_name" "text", "ad_type" "text", "spend" numeric, "impressions" bigint, "clicks" bigint, "ctr" numeric, "cpc" numeric, "crm_leads" bigint, "crm_primeiras_conversas" bigint, "crm_agendados" bigint, "crm_ganhos" bigint, "acquisition_buying_contacts" bigint, "acquisition_sales" bigint, "acquisition_revenue" numeric, "acquisition_sales_with_valid_value" bigint, "acquisition_sales_without_valid_value" bigint, "acquisition_revenue_is_complete" boolean, "cohort_buying_contacts" bigint, "cohort_total_sales" bigint, "cohort_sales_without_own_lead" bigint, "total_cohort_revenue" numeric, "cohort_sales_with_valid_value" bigint, "cohort_sales_without_valid_value" bigint, "cohort_revenue_is_complete" boolean, "cpl" numeric, "cost_per_agendado" numeric, "cost_per_gain" numeric, "cac_acquisition" numeric, "roas_acquisition" numeric, "roas_total_cohort" numeric)
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
#variable_conflict use_column
begin
  if p_client_id is null then
    raise exception using
      errcode = '22004',
      message = 'p_client_id não pode ser NULL';
  end if;

  if p_start_date is null or p_end_date is null then
    raise exception using
      errcode = '22004',
      message = 'p_start_date e p_end_date não podem ser NULL';
  end if;

  if p_start_date > p_end_date then
    raise exception using
      errcode = '22007',
      message = 'p_start_date não pode ser posterior a p_end_date';
  end if;

  if p_dimension is null
     or p_dimension not in ('account', 'campaign') then
    raise exception using
      errcode = '22023',
      message = format(
        'p_dimension inválida: %s. Valores aceitos: account, campaign',
        coalesce(p_dimension, 'NULL')
      );
  end if;

  return query
  with

  -- Última hierarquia conhecida para resolver nomes e conta de campanhas
  -- atribuídas no CRM, mesmo sem entrega dentro do período solicitado.
  campaign_hierarchy_latest as (
    select distinct on (m.campaign_id)
      m.campaign_id,
      m.campaign_name,
      m.customer_id,
      m.customer_name,
      m.date,
      m.updated_at,
      m.created_at,
      m.id
    from public.google_ads_campaign_daily m
    where m.client_id = p_client_id
      and m.campaign_id is not null
    order by
      m.campaign_id,
      m.date desc nulls last,
      m.updated_at desc nulls last,
      m.created_at desc nulls last,
      m.id desc
  ),

  -- Mídia real no período.
  media_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(m.customer_id, '__google_unmapped_account__')

        when 'campaign' then
          case
            when m.campaign_id is null then '__google_unmapped_campaign__'
            else concat_ws(
              '|',
              coalesce(m.customer_id, '__no_account__'),
              m.campaign_id
            )
          end
      end as group_id,

      case p_dimension
        when 'account' then
          coalesce(
            m.customer_name,
            m.customer_id,
            'Conta não identificada'
          )

        when 'campaign' then
          coalesce(
            m.campaign_name,
            m.campaign_id,
            'Campanha não identificada'
          )
      end as group_name,

      m.customer_id as account_id,
      m.customer_name as account_name,

      case
        when p_dimension = 'campaign' then m.campaign_id
      end as campaign_id,

      case
        when p_dimension = 'campaign' then m.campaign_name
      end as campaign_name,

      m.date::timestamp without time zone as sort_at,
      1::integer as source_priority,

      coalesce(m.cost, 0::numeric) as spend,
      coalesce(m.impressions, 0)::bigint as impressions,
      coalesce(m.clicks, 0)::bigint as clicks

    from public.google_ads_campaign_daily m
    where m.client_id = p_client_id
      and m.date between p_start_date and p_end_date
  ),

  -- Jornada CRM atribuída tecnicamente ao Google Ads.
  lead_resolved as (
    select
      l.*,

      ch.customer_id as resolved_account_id,
      ch.customer_name as resolved_account_name,

      coalesce(
        l.google_campaign_id,
        ch.campaign_id
      ) as resolved_campaign_id,

      ch.campaign_name as resolved_campaign_name

    from public.v_client_leads_by_stage_v2 l

    left join campaign_hierarchy_latest ch
      on ch.campaign_id = l.google_campaign_id

    where l.client_id = p_client_id
      and l.lead_date between p_start_date and p_end_date
      and l.attribution_platform = 'Google Ads'
  ),

  lead_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(
            lr.resolved_account_id,
            '__google_unmapped_account__'
          )

        when 'campaign' then
          case
            when lr.resolved_campaign_id is null
              then '__google_unmapped_campaign__'
            else concat_ws(
              '|',
              coalesce(
                lr.resolved_account_id,
                '__no_account__'
              ),
              lr.resolved_campaign_id
            )
          end
      end as group_id,

      case p_dimension
        when 'account' then
          coalesce(
            lr.resolved_account_name,
            lr.resolved_account_id,
            'Conta não identificada'
          )

        when 'campaign' then
          coalesce(
            lr.resolved_campaign_name,
            lr.resolved_campaign_id,
            'Campanha não identificada'
          )
      end as group_name,

      lr.resolved_account_id as account_id,
      lr.resolved_account_name as account_name,

      case
        when p_dimension = 'campaign'
          then lr.resolved_campaign_id
      end as campaign_id,

      case
        when p_dimension = 'campaign'
          then lr.resolved_campaign_name
      end as campaign_name,

      lr.lead_date::timestamp without time zone as sort_at,
      2::integer as source_priority,

      lr.contact_id,
      lr.has_primeira_conversa,
      lr.has_agendado,
      lr.has_ganho

    from lead_resolved lr
  ),

  -- Vendas oficiais ligadas à coorte Google Ads.
  sale_resolved as (
    select
      s.*,

      ch.customer_id as resolved_account_id,
      ch.customer_name as resolved_account_name,

      coalesce(
        s.google_campaign_id,
        ch.campaign_id
      ) as resolved_campaign_id,

      ch.campaign_name as resolved_campaign_name

    from public.v_crm_sales_v2 s

    left join campaign_hierarchy_latest ch
      on ch.campaign_id = s.google_campaign_id

    where s.client_id = p_client_id
      and s.contact_lead_date between p_start_date and p_end_date
      and s.is_cohort_linkable is true
      and s.attribution_platform = 'Google Ads'
  ),

  sale_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(
            sr.resolved_account_id,
            '__google_unmapped_account__'
          )

        when 'campaign' then
          case
            when sr.resolved_campaign_id is null
              then '__google_unmapped_campaign__'
            else concat_ws(
              '|',
              coalesce(
                sr.resolved_account_id,
                '__no_account__'
              ),
              sr.resolved_campaign_id
            )
          end
      end as group_id,

      case p_dimension
        when 'account' then
          coalesce(
            sr.resolved_account_name,
            sr.resolved_account_id,
            'Conta não identificada'
          )

        when 'campaign' then
          coalesce(
            sr.resolved_campaign_name,
            sr.resolved_campaign_id,
            'Campanha não identificada'
          )
      end as group_name,

      sr.resolved_account_id as account_id,
      sr.resolved_account_name as account_name,

      case
        when p_dimension = 'campaign'
          then sr.resolved_campaign_id
      end as campaign_id,

      case
        when p_dimension = 'campaign'
          then sr.resolved_campaign_name
      end as campaign_name,

      sr.contact_lead_date::timestamp without time zone as sort_at,
      3::integer as source_priority,

      sr.opportunity_id,
      sr.contact_id,
      sr.is_acquisition_sale,
      sr.has_valid_value,
      sr.valor_ganho

    from sale_resolved sr
  ),

  -- Catálogo unificado: mantém grupos que só tenham mídia, CRM ou venda.
  catalog_rows as (
    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      sort_at,
      source_priority
    from media_tagged

    union all

    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      sort_at,
      source_priority
    from lead_tagged

    union all

    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      sort_at,
      source_priority
    from sale_tagged
  ),

  dimension_catalog as (
    select
      cr.group_id,

      (
        array_agg(
          cr.group_name
          order by
            cr.sort_at desc nulls last,
            cr.source_priority
        )
        filter (where cr.group_name is not null)
      )[1] as group_name,

      (
        array_agg(
          cr.account_id
          order by
            cr.sort_at desc nulls last,
            cr.source_priority
        )
        filter (where cr.account_id is not null)
      )[1] as account_id,

      (
        array_agg(
          cr.account_name
          order by
            cr.sort_at desc nulls last,
            cr.source_priority
        )
        filter (where cr.account_name is not null)
      )[1] as account_name,

      (
        array_agg(
          cr.campaign_id
          order by
            cr.sort_at desc nulls last,
            cr.source_priority
        )
        filter (where cr.campaign_id is not null)
      )[1] as campaign_id,

      (
        array_agg(
          cr.campaign_name
          order by
            cr.sort_at desc nulls last,
            cr.source_priority
        )
        filter (where cr.campaign_name is not null)
      )[1] as campaign_name

    from catalog_rows cr
    group by cr.group_id
  ),

  media_agg as (
    select
      mt.group_id,
      sum(mt.spend)::numeric as spend,
      sum(mt.impressions)::bigint as impressions,
      sum(mt.clicks)::bigint as clicks
    from media_tagged mt
    group by mt.group_id
  ),

  lead_agg as (
    select
      lt.group_id,

      count(*)::bigint as crm_leads,

      count(*) filter (
        where lt.has_primeira_conversa is true
      )::bigint as crm_primeiras_conversas,

      count(*) filter (
        where lt.has_agendado is true
      )::bigint as crm_agendados,

      count(*) filter (
        where lt.has_ganho is true
      )::bigint as crm_ganhos

    from lead_tagged lt
    group by lt.group_id
  ),

  sale_agg as (
    select
      st.group_id,

      count(distinct st.contact_id) filter (
        where st.is_acquisition_sale is true
      )::bigint as acquisition_buying_contacts,

      count(*) filter (
        where st.is_acquisition_sale is true
      )::bigint as acquisition_sales,

      sum(st.valor_ganho) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is true
      )::numeric as acquisition_revenue,

      count(*) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is true
      )::bigint as acquisition_sales_with_valid_value,

      count(*) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is not true
      )::bigint as acquisition_sales_without_valid_value,

      count(distinct st.contact_id)::bigint
        as cohort_buying_contacts,

      count(*)::bigint
        as cohort_total_sales,

      count(*) filter (
        where st.is_acquisition_sale is not true
      )::bigint as cohort_sales_without_own_lead,

      sum(st.valor_ganho) filter (
        where st.has_valid_value is true
      )::numeric as total_cohort_revenue,

      count(*) filter (
        where st.has_valid_value is true
      )::bigint as cohort_sales_with_valid_value,

      count(*) filter (
        where st.has_valid_value is not true
      )::bigint as cohort_sales_without_valid_value

    from sale_tagged st
    group by st.group_id
  ),

  assembled as (
    select
      dc.group_id,
      dc.group_name,
      dc.account_id,
      dc.account_name,
      dc.campaign_id,
      dc.campaign_name,

      coalesce(ma.spend, 0::numeric) as spend,
      coalesce(ma.impressions, 0)::bigint as impressions,
      coalesce(ma.clicks, 0)::bigint as clicks,

      coalesce(la.crm_leads, 0)::bigint as crm_leads,
      coalesce(
        la.crm_primeiras_conversas,
        0
      )::bigint as crm_primeiras_conversas,
      coalesce(la.crm_agendados, 0)::bigint as crm_agendados,
      coalesce(la.crm_ganhos, 0)::bigint as crm_ganhos,

      coalesce(
        sa.acquisition_buying_contacts,
        0
      )::bigint as acquisition_buying_contacts,

      coalesce(
        sa.acquisition_sales,
        0
      )::bigint as acquisition_sales,

      sa.acquisition_revenue,

      coalesce(
        sa.acquisition_sales_with_valid_value,
        0
      )::bigint as acquisition_sales_with_valid_value,

      coalesce(
        sa.acquisition_sales_without_valid_value,
        0
      )::bigint as acquisition_sales_without_valid_value,

      coalesce(
        sa.cohort_buying_contacts,
        0
      )::bigint as cohort_buying_contacts,

      coalesce(
        sa.cohort_total_sales,
        0
      )::bigint as cohort_total_sales,

      coalesce(
        sa.cohort_sales_without_own_lead,
        0
      )::bigint as cohort_sales_without_own_lead,

      sa.total_cohort_revenue,

      coalesce(
        sa.cohort_sales_with_valid_value,
        0
      )::bigint as cohort_sales_with_valid_value,

      coalesce(
        sa.cohort_sales_without_valid_value,
        0
      )::bigint as cohort_sales_without_valid_value

    from dimension_catalog dc

    left join media_agg ma
      on ma.group_id = dc.group_id

    left join lead_agg la
      on la.group_id = dc.group_id

    left join sale_agg sa
      on sa.group_id = dc.group_id
  )

  select
    p_dimension::text as dimension,
    a.group_id,
    a.group_name,

    a.account_id,
    a.account_name,
    a.campaign_id,
    a.campaign_name,

    null::text as ad_group_id,
    null::text as ad_group_name,
    null::text as ad_id,
    null::text as ad_name,
    null::text as ad_type,

    a.spend,
    a.impressions,
    a.clicks,

    case
      when a.impressions > 0
        then a.clicks::numeric
             / a.impressions::numeric
    end as ctr,

    case
      when a.clicks > 0
        then a.spend
             / a.clicks::numeric
    end as cpc,

    a.crm_leads,
    a.crm_primeiras_conversas,
    a.crm_agendados,
    a.crm_ganhos,

    a.acquisition_buying_contacts,
    a.acquisition_sales,
    a.acquisition_revenue,
    a.acquisition_sales_with_valid_value,
    a.acquisition_sales_without_valid_value,

    case
      when a.acquisition_sales = 0 then null
      when a.acquisition_sales_without_valid_value = 0 then true
      else false
    end as acquisition_revenue_is_complete,

    a.cohort_buying_contacts,
    a.cohort_total_sales,
    a.cohort_sales_without_own_lead,
    a.total_cohort_revenue,
    a.cohort_sales_with_valid_value,
    a.cohort_sales_without_valid_value,

    case
      when a.cohort_total_sales = 0 then null
      when a.cohort_sales_without_valid_value = 0 then true
      else false
    end as cohort_revenue_is_complete,

    case
      when a.spend > 0
       and a.crm_leads > 0
        then a.spend / a.crm_leads::numeric
    end as cpl,

    case
      when a.spend > 0
       and a.crm_agendados > 0
        then a.spend / a.crm_agendados::numeric
    end as cost_per_agendado,

    case
      when a.spend > 0
       and a.crm_ganhos > 0
        then a.spend / a.crm_ganhos::numeric
    end as cost_per_gain,

    case
      when a.spend > 0
       and a.acquisition_buying_contacts > 0
        then a.spend
             / a.acquisition_buying_contacts::numeric
    end as cac_acquisition,

    case
      when a.spend > 0
       and a.acquisition_sales > 0
       and a.acquisition_sales_without_valid_value = 0
        then a.acquisition_revenue / a.spend
    end as roas_acquisition,

    case
      when a.spend > 0
       and a.cohort_total_sales > 0
       and a.cohort_sales_without_valid_value = 0
        then a.total_cohort_revenue / a.spend
    end as roas_total_cohort

  from assembled a

  order by
    a.spend desc,
    a.group_name nulls last,
    a.group_id;

end;
$$;


ALTER FUNCTION "public"."get_google_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_google_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text") IS 'Resumo full-funnel oficial Google Ads V2 no grão account ou campaign. Mídia vem exclusivamente de google_ads_campaign_daily. CRM e vendas usam coorte do lead e atribuição técnica por google_campaign_id. Colunas de grupo e anúncio permanecem no retorno por compatibilidade, mas são NULL.';



CREATE OR REPLACE FUNCTION "public"."get_internal_agency_overview"("p_start_date" "date" DEFAULT (CURRENT_DATE - 29), "p_end_date" "date" DEFAULT CURRENT_DATE, "p_client_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_include_not_ready" boolean DEFAULT true, "p_search" "text" DEFAULT NULL::"text", "p_sort_by" "text" DEFAULT 'investment'::"text", "p_sort_direction" "text" DEFAULT 'desc'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'private'
    AS $$
declare
  v_result jsonb;
begin
  if not private.is_agency_user() then
    raise exception 'Acesso restrito à equipe interna da agência.'
      using errcode = '42501';
  end if;

  if p_start_date is null or p_end_date is null or p_start_date > p_end_date then
    raise exception 'Período inválido.' using errcode = '22023';
  end if;

  if p_sort_by not in (
    'client_name','investment','leads','primeiras_conversas','agendados',
    'acquisition_sales','closed_sales','acquisition_revenue','closed_revenue',
    'cpl_paid','cac_acquisition','roas_acquisition'
  ) then
    raise exception 'p_sort_by inválido.' using errcode = '22023';
  end if;

  if lower(p_sort_direction) not in ('asc','desc') then
    raise exception 'p_sort_direction inválido.' using errcode = '22023';
  end if;

  with selected_clients as (
    select
      cb.id,
      cb.client_name,
      cb.client_slug,
      cb.status,
      cb.tracking_ready,
      cb.sync_ready,
      cb.meta_ready,
      cb.google_ads_ready,
      cb.meta_ads_sync_ready,
      cb.google_ads_sync_ready
    from public.clients_base cb
    where cb.status = 'active'
      and (p_client_ids is null or cb.id = any(p_client_ids))
      and (
        p_include_not_ready
        or (coalesce(cb.tracking_ready, false) and coalesce(cb.sync_ready, false))
      )
      and (
        nullif(btrim(coalesce(p_search, '')), '') is null
        or concat_ws(' ', cb.client_name, cb.client_slug) ilike '%' || btrim(p_search) || '%'
      )
  ), client_metrics as (
    select
      sc.*,
      ov.media_days,
      ov.investment,
      ov.investment_is_complete,
      ov.leads,
      ov.paid_attributed_leads,
      ov.meta_ads_leads,
      ov.google_ads_leads,
      ov.unattributed_leads,
      ov.attribution_conflicts,
      ov.primeiras_conversas,
      ov.agendados,
      ov.crm_ganhos,
      ov.acquisition_buying_contacts,
      ov.acquisition_sales,
      ov.cohort_total_sales,
      ov.cohort_sales_without_own_lead,
      ov.acquisition_revenue,
      ov.total_cohort_revenue,
      ov.acquisition_revenue_is_complete,
      ov.cohort_revenue_is_complete,
      ov.closed_sales,
      ov.closed_buying_contacts,
      ov.closed_revenue,
      ov.closed_revenue_is_complete,
      ov.cpl_paid,
      ov.cac_acquisition,
      ov.roas_acquisition,
      ov.roas_total_cohort,
      case
        when coalesce(sc.tracking_ready, false) is false or coalesce(sc.sync_ready, false) is false then 'setup_pending'
        when ov.investment_is_complete is false then 'investment_incomplete'
        when ov.closed_sales > 0 and ov.closed_revenue_is_complete is false then 'revenue_incomplete'
        when ov.acquisition_sales > 0 and ov.acquisition_revenue_is_complete is false then 'acquisition_revenue_incomplete'
        when ov.attribution_conflicts > 0 then 'attribution_conflict'
        else 'ok'
      end as quality_status
    from selected_clients sc
    cross join lateral public.get_client_overview_v2(sc.id, p_start_date, p_end_date) ov
  ), portfolio as (
    select
      count(*)::bigint as clients_count,
      count(*) filter (where tracking_ready and sync_ready)::bigint as ready_clients,
      count(*) filter (where not tracking_ready or not sync_ready)::bigint as not_ready_clients,
      sum(investment) as investment,
      case
        when count(*) filter (where investment is not null) = 0 then null
        else bool_and(investment_is_complete) filter (where investment is not null)
      end as investment_is_complete,
      coalesce(sum(leads),0)::bigint as leads,
      coalesce(sum(paid_attributed_leads),0)::bigint as paid_attributed_leads,
      coalesce(sum(meta_ads_leads),0)::bigint as meta_ads_leads,
      coalesce(sum(google_ads_leads),0)::bigint as google_ads_leads,
      coalesce(sum(unattributed_leads),0)::bigint as unattributed_leads,
      coalesce(sum(attribution_conflicts),0)::bigint as attribution_conflicts,
      coalesce(sum(primeiras_conversas),0)::bigint as primeiras_conversas,
      coalesce(sum(agendados),0)::bigint as agendados,
      coalesce(sum(crm_ganhos),0)::bigint as crm_ganhos,
      coalesce(sum(acquisition_buying_contacts),0)::bigint as acquisition_buying_contacts,
      coalesce(sum(acquisition_sales),0)::bigint as acquisition_sales,
      coalesce(sum(closed_sales),0)::bigint as closed_sales,
      coalesce(sum(closed_buying_contacts),0)::bigint as closed_buying_contacts,
      sum(acquisition_revenue) as acquisition_revenue,
      sum(closed_revenue) as closed_revenue,
      case
        when coalesce(sum(acquisition_sales),0) = 0 then null
        else bool_and(acquisition_revenue_is_complete) filter (where acquisition_sales > 0)
      end as acquisition_revenue_is_complete,
      case
        when coalesce(sum(closed_sales),0) = 0 then null
        else bool_and(closed_revenue_is_complete) filter (where closed_sales > 0)
      end as closed_revenue_is_complete
    from client_metrics
  ), portfolio_metrics as (
    select
      p.*,
      case
        when p.investment_is_complete is true
         and p.investment is not null
         and p.paid_attributed_leads > 0
          then p.investment / p.paid_attributed_leads
      end as cpl_paid,
      case
        when p.investment_is_complete is true
         and p.investment is not null
         and p.acquisition_buying_contacts > 0
          then p.investment / p.acquisition_buying_contacts
      end as cac_acquisition,
      case
        when p.investment_is_complete is true
         and p.acquisition_revenue_is_complete is true
         and p.investment > 0
          then p.acquisition_revenue / p.investment
      end as roas_acquisition
    from portfolio p
  ), ordered_clients as (
    select cm.*
    from client_metrics cm
    order by
      case when p_sort_by = 'client_name' and lower(p_sort_direction) = 'asc' then cm.client_name end asc,
      case when p_sort_by = 'client_name' and lower(p_sort_direction) = 'desc' then cm.client_name end desc,
      case when p_sort_by = 'investment' and lower(p_sort_direction) = 'asc' then cm.investment end asc nulls last,
      case when p_sort_by = 'investment' and lower(p_sort_direction) = 'desc' then cm.investment end desc nulls last,
      case when p_sort_by = 'leads' and lower(p_sort_direction) = 'asc' then cm.leads end asc nulls last,
      case when p_sort_by = 'leads' and lower(p_sort_direction) = 'desc' then cm.leads end desc nulls last,
      case when p_sort_by = 'primeiras_conversas' and lower(p_sort_direction) = 'asc' then cm.primeiras_conversas end asc nulls last,
      case when p_sort_by = 'primeiras_conversas' and lower(p_sort_direction) = 'desc' then cm.primeiras_conversas end desc nulls last,
      case when p_sort_by = 'agendados' and lower(p_sort_direction) = 'asc' then cm.agendados end asc nulls last,
      case when p_sort_by = 'agendados' and lower(p_sort_direction) = 'desc' then cm.agendados end desc nulls last,
      case when p_sort_by = 'acquisition_sales' and lower(p_sort_direction) = 'asc' then cm.acquisition_sales end asc nulls last,
      case when p_sort_by = 'acquisition_sales' and lower(p_sort_direction) = 'desc' then cm.acquisition_sales end desc nulls last,
      case when p_sort_by = 'closed_sales' and lower(p_sort_direction) = 'asc' then cm.closed_sales end asc nulls last,
      case when p_sort_by = 'closed_sales' and lower(p_sort_direction) = 'desc' then cm.closed_sales end desc nulls last,
      case when p_sort_by = 'acquisition_revenue' and lower(p_sort_direction) = 'asc' then cm.acquisition_revenue end asc nulls last,
      case when p_sort_by = 'acquisition_revenue' and lower(p_sort_direction) = 'desc' then cm.acquisition_revenue end desc nulls last,
      case when p_sort_by = 'closed_revenue' and lower(p_sort_direction) = 'asc' then cm.closed_revenue end asc nulls last,
      case when p_sort_by = 'closed_revenue' and lower(p_sort_direction) = 'desc' then cm.closed_revenue end desc nulls last,
      case when p_sort_by = 'cpl_paid' and lower(p_sort_direction) = 'asc' then cm.cpl_paid end asc nulls last,
      case when p_sort_by = 'cpl_paid' and lower(p_sort_direction) = 'desc' then cm.cpl_paid end desc nulls last,
      case when p_sort_by = 'cac_acquisition' and lower(p_sort_direction) = 'asc' then cm.cac_acquisition end asc nulls last,
      case when p_sort_by = 'cac_acquisition' and lower(p_sort_direction) = 'desc' then cm.cac_acquisition end desc nulls last,
      case when p_sort_by = 'roas_acquisition' and lower(p_sort_direction) = 'asc' then cm.roas_acquisition end asc nulls last,
      case when p_sort_by = 'roas_acquisition' and lower(p_sort_direction) = 'desc' then cm.roas_acquisition end desc nulls last,
      cm.client_name asc
  )
  select jsonb_build_object(
    'filters', jsonb_build_object(
      'start_date', p_start_date,
      'end_date', p_end_date,
      'client_ids', p_client_ids,
      'include_not_ready', p_include_not_ready,
      'search', p_search,
      'sort_by', p_sort_by,
      'sort_direction', lower(p_sort_direction)
    ),
    'portfolio', to_jsonb(pm),
    'quality', jsonb_build_object(
      'ok_clients', (select count(*) from client_metrics where quality_status = 'ok'),
      'setup_pending_clients', (select count(*) from client_metrics where quality_status = 'setup_pending'),
      'investment_incomplete_clients', (select count(*) from client_metrics where quality_status = 'investment_incomplete'),
      'revenue_incomplete_clients', (select count(*) from client_metrics where quality_status in ('revenue_incomplete','acquisition_revenue_incomplete')),
      'attribution_conflict_clients', (select count(*) from client_metrics where quality_status = 'attribution_conflict')
    ),
    'clients', coalesce((select jsonb_agg(to_jsonb(oc)) from ordered_clients oc), '[]'::jsonb)
  )
  into v_result
  from portfolio_metrics pm;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."get_internal_agency_overview"("p_start_date" "date", "p_end_date" "date", "p_client_ids" "uuid"[], "p_include_not_ready" boolean, "p_search" "text", "p_sort_by" "text", "p_sort_direction" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_internal_agency_overview"("p_start_date" "date", "p_end_date" "date", "p_client_ids" "uuid"[], "p_include_not_ready" boolean, "p_search" "text", "p_sort_by" "text", "p_sort_direction" "text") IS 'Dashboard executivo interno da agência. Consolida KPIs do portfólio e uma linha por cliente usando exclusivamente get_client_overview_v2, sem médias incorretas de CPL/CAC/ROAS.';



CREATE OR REPLACE FUNCTION "public"."get_internal_operations_feed"("p_section" "text" DEFAULT 'events_tracking'::"text", "p_event_layer" "text" DEFAULT NULL::"text", "p_client_id" "uuid" DEFAULT NULL::"uuid", "p_start_date" "date" DEFAULT (CURRENT_DATE - 14), "p_end_date" "date" DEFAULT CURRENT_DATE, "p_status" "text" DEFAULT NULL::"text", "p_search" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 100, "p_offset" integer DEFAULT 0) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'private'
    AS $$
declare
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_limit integer;
  v_offset integer;
  v_result jsonb;
begin
  if not private.is_agency_user() then
    raise exception 'Acesso restrito à equipe interna da agência.'
      using errcode = '42501';
  end if;

  if p_section not in ('onboarding', 'events_tracking', 'syncs') then
    raise exception 'p_section inválido: use onboarding, events_tracking ou syncs.'
      using errcode = '22023';
  end if;

  if p_event_layer is not null
     and p_event_layer not in ('raw', 'normalized', 'tracking', 'n8n_tracking') then
    raise exception 'p_event_layer inválido: use raw, normalized, tracking ou n8n_tracking.'
      using errcode = '22023';
  end if;

  if p_status is not null
     and p_status not in ('ok', 'info', 'pending', 'warning', 'error') then
    raise exception 'p_status inválido: use ok, info, pending, warning ou error.'
      using errcode = '22023';
  end if;

  if p_start_date is null or p_end_date is null or p_start_date > p_end_date then
    raise exception 'Período inválido.' using errcode = '22023';
  end if;

  v_limit := greatest(1, least(coalesce(p_limit, 100), 500));
  v_offset := greatest(coalesce(p_offset, 0), 0);
  v_start_at := p_start_date::timestamp at time zone 'America/Sao_Paulo';
  v_end_at := (p_end_date + 1)::timestamp at time zone 'America/Sao_Paulo';

  with all_rows as (
    select
      er.received_at as event_at,
      (er.received_at at time zone 'America/Sao_Paulo')::date as event_date,
      'client'::text as event_domain,
      'raw'::text as event_group,
      'events_raw'::text as source_relation,
      er.id::text as source_id,
      cb.id as client_id,
      cb.client_name,
      cb.client_slug,
      er.processing_status as source_status,
      case
        when er.processing_error is not null then 'error'
        when er.processing_status = 'client_not_found' then 'error'
        when er.processing_status = 'normalized' then 'ok'
        when er.processing_status = 'excluded_from_normalized' then 'info'
        when er.processing_status = 'received' and er.received_at < clock_timestamp() - interval '2 hours' then 'warning'
        when er.processing_status = 'received' then 'pending'
        else 'warning'
      end as health_status,
      coalesce(er.event_type, 'raw_event') as summary,
      er.event_type as event_code,
      er.contact_id,
      null::text as contact_name,
      null::text as opportunity_id,
      er.id::text as correlation_id,
      null::text as platform,
      null::text as route,
      null::integer as attempts,
      null::text as workflow_key,
      null::text as workflow_name,
      null::text as workflow_category,
      null::text as n8n_execution_id,
      null::text as stage,
      null::integer as duration_ms,
      null::integer as items_processed,
      null::integer as items_failed,
      jsonb_strip_nulls(jsonb_build_object(
        'source_system', er.source_system,
        'location_id', er.location_id,
        'location_name', er.location_name,
        'processed_at', er.processed_at,
        'processing_error', er.processing_error,
        'request_path', er.request_path
      )) as details
    from public.events_raw er
    left join public.clients_base cb
      on cb.ghl_location_id = er.location_id
    where er.received_at >= v_start_at
      and er.received_at < v_end_at

    union all

    select
      coalesce(en.event_datetime, en.received_at, en.created_at) as event_at,
      (coalesce(en.event_datetime, en.received_at, en.created_at) at time zone coalesce(nullif(cb.timezone, ''), 'America/Sao_Paulo'))::date as event_date,
      'client'::text as event_domain,
      'normalized'::text as event_group,
      'events_normalized'::text as source_relation,
      en.id::text as source_id,
      en.client_id,
      cb.client_name,
      cb.client_slug,
      en.normalization_status as source_status,
      case
        when en.normalization_error is not null then 'error'
        when en.normalization_status = 'normalized' then 'ok'
        else 'warning'
      end as health_status,
      coalesce(en.event_name, en.event_code) as summary,
      en.event_code,
      en.contact_id,
      en.full_name as contact_name,
      en.opportunity_id,
      en.raw_event_id::text as correlation_id,
      null::text as platform,
      null::text as route,
      null::integer as attempts,
      en.source_workflow_id as workflow_key,
      en.source_workflow_name as workflow_name,
      null::text as workflow_category,
      null::text as n8n_execution_id,
      en.pipeline_stage as stage,
      null::integer as duration_ms,
      null::integer as items_processed,
      null::integer as items_failed,
      jsonb_strip_nulls(jsonb_build_object(
        'raw_event_id', en.raw_event_id,
        'source_system', en.source_system,
        'source_event_type', en.source_event_type,
        'received_at', en.received_at,
        'pipeline_name', en.pipeline_name,
        'pipeline_stage', en.pipeline_stage,
        'crm_status', en.status,
        'lead_origem', en.lead_origem,
        'lead_entrada', en.lead_entrada,
        'source_id', en.source_id,
        'google_campaign_id', en.google_campaign_id,
        'normalization_error', en.normalization_error
      )) as details
    from public.events_normalized en
    join public.clients_base cb
      on cb.id = en.client_id
    where coalesce(en.event_datetime, en.received_at, en.created_at) >= v_start_at
      and coalesce(en.event_datetime, en.received_at, en.created_at) < v_end_at

    union all

    select
      co.created_at as event_at,
      (co.created_at at time zone coalesce(nullif(cb.timezone, ''), 'America/Sao_Paulo'))::date as event_date,
      'client'::text as event_domain,
      'tracking'::text as event_group,
      'conversion_outbox'::text as source_relation,
      co.id::text as source_id,
      coalesce(en.client_id, cb.id) as client_id,
      coalesce(cb.client_name, en.client_name) as client_name,
      cb.client_slug,
      co.status as source_status,
      case
        when co.status = 'sent' then 'ok'
        when co.status = 'skipped' then 'info'
        when co.status = 'failed' then 'error'
        when co.status = 'pending' and co.created_at < clock_timestamp() - interval '24 hours' then 'warning'
        when co.status = 'pending' then 'pending'
        else 'warning'
      end as health_status,
      concat_ws(' · ', co.event_code, co.platform, co.route) as summary,
      co.event_code,
      co.contact_id,
      en.full_name as contact_name,
      en.opportunity_id,
      co.normalized_event_id::text as correlation_id,
      co.platform,
      co.route,
      co.attempts,
      null::text as workflow_key,
      null::text as workflow_name,
      'dispatch'::text as workflow_category,
      co.external_job_id as n8n_execution_id,
      null::text as stage,
      null::integer as duration_ms,
      null::integer as items_processed,
      null::integer as items_failed,
      jsonb_strip_nulls(jsonb_build_object(
        'normalized_event_id', co.normalized_event_id,
        'sent_at', co.sent_at,
        'next_attempt_at', co.next_attempt_at,
        'platform_event_name', co.platform_event_name,
        'platform_conversion_action', co.platform_conversion_action,
        'dispatch_method', co.dispatch_method,
        'http_status', co.http_status,
        'error_code', co.error_code,
        'error_subcode', co.error_subcode,
        'last_error', co.last_error,
        'external_request_id', co.external_request_id
      )) as details
    from public.conversion_outbox co
    left join public.events_normalized en
      on en.id = co.normalized_event_id
    left join public.clients_base cb
      on cb.id = en.client_id
      or cb.ghl_location_id = co.ghl_location_id
    where co.created_at >= v_start_at
      and co.created_at < v_end_at

    union all

    select
      wl.started_at as event_at,
      (wl.started_at at time zone 'America/Sao_Paulo')::date as event_date,
      'n8n'::text as event_domain,
      case
        when wl.workflow_category = 'onboarding' then 'onboarding'
        when wl.workflow_category in ('media_sync', 'backfill') then 'sync'
        when wl.workflow_category in ('events', 'dispatch') then 'n8n_tracking'
        else 'other'
      end as event_group,
      'workflow_execution_logs'::text as source_relation,
      wl.id::text as source_id,
      coalesce(wl.client_id, cb.id) as client_id,
      coalesce(wl.client_name, cb.client_name) as client_name,
      coalesce(wl.client_slug, cb.client_slug) as client_slug,
      wl.status as source_status,
      case
        when wl.status = 'success' then 'ok'
        when wl.status = 'skipped' then 'info'
        when wl.status = 'error' then 'error'
        when wl.status = 'partial' then 'warning'
        when wl.status = 'running' and wl.started_at < clock_timestamp() - interval '2 hours' then 'warning'
        when wl.status = 'running' then 'pending'
        else 'warning'
      end as health_status,
      wl.workflow_name as summary,
      null::text as event_code,
      null::text as contact_id,
      null::text as contact_name,
      null::text as opportunity_id,
      wl.n8n_execution_id as correlation_id,
      null::text as platform,
      null::text as route,
      null::integer as attempts,
      wl.workflow_key,
      wl.workflow_name,
      wl.workflow_category,
      wl.n8n_execution_id,
      wl.stage,
      wl.duration_ms,
      wl.items_processed,
      wl.items_failed,
      jsonb_strip_nulls(jsonb_build_object(
        'started_at', wl.started_at,
        'finished_at', wl.finished_at,
        'ghl_location_id', wl.ghl_location_id,
        'error_message', wl.error_message,
        'error_node', wl.error_node,
        'stages', wl.stages,
        'metadata', wl.metadata
      )) as details
    from public.workflow_execution_logs wl
    left join public.clients_base cb
      on cb.ghl_location_id = wl.ghl_location_id
    where wl.started_at >= v_start_at
      and wl.started_at < v_end_at
  ), scoped as (
    select *
    from all_rows r
    where (
      (p_section = 'onboarding' and r.event_domain = 'n8n' and r.event_group = 'onboarding')
      or
      (p_section = 'syncs' and r.event_domain = 'n8n' and r.event_group = 'sync')
      or
      (p_section = 'events_tracking' and (
        (r.event_domain = 'client' and r.event_group in ('raw', 'normalized', 'tracking'))
        or (r.event_domain = 'n8n' and r.event_group = 'n8n_tracking')
      ))
    )
      and (p_event_layer is null or r.event_group = p_event_layer)
      and (p_client_id is null or r.client_id = p_client_id)
      and (p_status is null or r.health_status = p_status)
      and (
        nullif(btrim(coalesce(p_search, '')), '') is null
        or concat_ws(' ',
          r.summary,
          r.client_name,
          r.event_code,
          r.contact_id,
          r.contact_name,
          r.opportunity_id,
          r.source_id,
          r.correlation_id,
          r.workflow_name,
          r.n8n_execution_id
        ) ilike '%' || btrim(p_search) || '%'
      )
  ), summary as (
    select
      count(*) as total,
      count(*) filter (where health_status = 'ok') as ok_count,
      count(*) filter (where health_status = 'info') as info_count,
      count(*) filter (where health_status = 'pending') as pending_count,
      count(*) filter (where health_status = 'warning') as warning_count,
      count(*) filter (where health_status = 'error') as error_count,
      max(event_at) as last_event_at,
      jsonb_object_agg(event_group, group_count) as by_group
    from (
      select
        s.*,
        count(*) over (partition by event_group) as group_count
      from scoped s
    ) x
  ), paged as (
    select *
    from scoped
    order by event_at desc, source_relation, source_id
    limit v_limit
    offset v_offset
  )
  select jsonb_build_object(
    'filters', jsonb_build_object(
      'section', p_section,
      'event_layer', p_event_layer,
      'client_id', p_client_id,
      'start_date', p_start_date,
      'end_date', p_end_date,
      'status', p_status,
      'search', p_search
    ),
    'summary', jsonb_build_object(
      'total', coalesce(s.total, 0),
      'ok', coalesce(s.ok_count, 0),
      'info', coalesce(s.info_count, 0),
      'pending', coalesce(s.pending_count, 0),
      'warning', coalesce(s.warning_count, 0),
      'error', coalesce(s.error_count, 0),
      'last_event_at', s.last_event_at,
      'by_group', coalesce(s.by_group, '{}'::jsonb)
    ),
    'pagination', jsonb_build_object(
      'limit', v_limit,
      'offset', v_offset,
      'returned', (select count(*) from paged),
      'total', coalesce(s.total, 0),
      'has_more', (v_offset + (select count(*) from paged)) < coalesce(s.total, 0)
    ),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.event_at desc, p.source_relation, p.source_id)
      from paged p
    ), '[]'::jsonb)
  )
  into v_result
  from summary s;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."get_internal_operations_feed"("p_section" "text", "p_event_layer" "text", "p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_status" "text", "p_search" "text", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_internal_operations_feed"("p_section" "text", "p_event_layer" "text", "p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_status" "text", "p_search" "text", "p_limit" integer, "p_offset" integer) IS 'Feed operacional interno da ImpulsHub. Entrega resumo, paginação e linhas detalhadas para as abas Onboarding, Eventos e Tracking e Syncs. Acesso exclusivo de usuários com role agency.';



CREATE OR REPLACE FUNCTION "public"."get_meta_account_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") RETURNS TABLE("account_id" "text", "account_name" "text", "spend" numeric, "meta_conversions" numeric, "crm_leads" bigint, "crm_agendados" bigint, "crm_ganhos" bigint, "receita" numeric)
    LANGUAGE "sql" STABLE
    AS $$
  WITH midia AS (
    SELECT
      m.account_id, m.account_name,
      SUM(m.spend) AS spend,
      SUM(COALESCE(m.meta_platform_conversions, 0)) AS meta_conversions
    FROM meta_ads_daily m
    WHERE m.client_id = p_client_id AND m.date BETWEEN p_start AND p_end
    GROUP BY m.account_id, m.account_name
  ),
  ad_para_conta AS (
    SELECT DISTINCT m.ad_id, m.account_id
    FROM meta_ads_daily m
    WHERE m.client_id = p_client_id AND m.date BETWEEN p_start AND p_end
  ),
  crm AS (
    SELECT
      a.account_id,
      COUNT(*) FILTER (WHERE e.event_code = 'lead')     AS crm_leads,
      COUNT(*) FILTER (WHERE e.event_code = 'agendado') AS crm_agendados,
      COUNT(*) FILTER (WHERE e.event_code = 'ganho' OR e.status = 'won') AS crm_ganhos,
      COALESCE(SUM(e.valor_ganho) FILTER (WHERE e.event_code = 'ganho' OR e.status = 'won'), 0) AS receita
    FROM v_crm_events_enriched e
    JOIN ad_para_conta a ON a.ad_id = e.meta_ad_id
    WHERE e.client_id = p_client_id AND e.event_date BETWEEN p_start AND p_end
      AND e.meta_ad_id IS NOT NULL
    GROUP BY a.account_id
  )
  SELECT
    mid.account_id, mid.account_name, mid.spend, mid.meta_conversions,
    COALESCE(c.crm_leads, 0), COALESCE(c.crm_agendados, 0),
    COALESCE(c.crm_ganhos, 0), COALESCE(c.receita, 0)
  FROM midia mid
  LEFT JOIN crm c ON c.account_id = mid.account_id;
$$;


ALTER FUNCTION "public"."get_meta_account_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_meta_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text" DEFAULT 'account'::"text") RETURNS TABLE("dimension" "text", "group_id" "text", "group_name" "text", "account_id" "text", "account_name" "text", "campaign_id" "text", "campaign_name" "text", "adset_id" "text", "adset_name" "text", "ad_id" "text", "ad_name" "text", "creative_id" "text", "creative_name" "text", "thumbnail_url" "text", "image_url" "text", "creative_url" "text", "headline" "text", "primary_text" "text", "spend" numeric, "impressions" bigint, "clicks" bigint, "ctr" numeric, "cpc" numeric, "crm_leads" bigint, "crm_primeiras_conversas" bigint, "crm_agendados" bigint, "crm_ganhos" bigint, "acquisition_buying_contacts" bigint, "acquisition_sales" bigint, "acquisition_revenue" numeric, "acquisition_sales_with_valid_value" bigint, "acquisition_sales_without_valid_value" bigint, "acquisition_revenue_is_complete" boolean, "cohort_buying_contacts" bigint, "cohort_total_sales" bigint, "cohort_sales_without_own_lead" bigint, "total_cohort_revenue" numeric, "cohort_sales_with_valid_value" bigint, "cohort_sales_without_valid_value" bigint, "cohort_revenue_is_complete" boolean, "cpl" numeric, "cost_per_agendado" numeric, "cost_per_gain" numeric, "cac_acquisition" numeric, "roas_acquisition" numeric, "roas_total_cohort" numeric)
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public', 'pg_temp'
    SET "work_mem" TO '16MB'
    AS $$
#variable_conflict use_column
begin
  if p_client_id is null then
    raise exception using
      errcode = '22004',
      message = 'p_client_id não pode ser NULL';
  end if;

  if p_start_date is null or p_end_date is null then
    raise exception using
      errcode = '22004',
      message = 'p_start_date e p_end_date não podem ser NULL';
  end if;

  if p_start_date > p_end_date then
    raise exception using
      errcode = '22007',
      message = 'p_start_date não pode ser posterior a p_end_date';
  end if;

  if p_dimension is null
     or p_dimension not in ('account', 'campaign', 'adset', 'ad', 'creative') then
    raise exception using
      errcode = '22023',
      message = format(
        'p_dimension inválida: %s. Valores aceitos: account, campaign, adset, ad, creative',
        coalesce(p_dimension, 'NULL')
      );
  end if;

  return query
  with
  -- --------------------------------------------------------------------------
  -- Mapa histórico e determinístico do anúncio.
  -- Para creative, aplica a decisão oficial: vale o último criativo conhecido.
  -- --------------------------------------------------------------------------
  ad_hierarchy_latest as (
    select distinct on (m.ad_id)
      m.ad_id,
      m.ad_name,
      m.account_id,
      m.account_name,
      m.campaign_id,
      m.campaign_name,
      m.adset_id,
      m.adset_name,
      m.creative_id,
      m.creative_name,
      m.thumbnail_url,
      m.image_url,
      m.creative_url,
      m.headline,
      m.primary_text,
      m.date,
      m.updated_at,
      m.created_at,
      m.id
    from public.v_meta_ads_v2 m
    where m.client_id = p_client_id
      and m.ad_id is not null
    order by
      m.ad_id,
      m.date desc nulls last,
      m.updated_at desc nulls last,
      m.created_at desc nulls last,
      m.id desc
  ),

  -- --------------------------------------------------------------------------
  -- Mídia real do período. No nível creative, usa o creative_id real da linha.
  -- --------------------------------------------------------------------------
  media_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(m.account_id, '__meta_unmapped_account__')
        when 'campaign' then
          case
            when m.campaign_id is null then '__meta_unmapped_campaign__'
            else concat_ws('|', coalesce(m.account_id, '__no_account__'), m.campaign_id)
          end
        when 'adset' then
          case
            when m.adset_id is null then '__meta_unmapped_adset__'
            else concat_ws(
              '|',
              coalesce(m.account_id, '__no_account__'),
              coalesce(m.campaign_id, '__no_campaign__'),
              m.adset_id
            )
          end
        when 'ad' then
          coalesce(m.ad_id, '__meta_unmapped_ad__')
        when 'creative' then
          coalesce(m.creative_id, '__meta_unmapped_creative__')
      end as group_id,

      case p_dimension
        when 'account' then coalesce(m.account_name, m.account_id, 'Conta não identificada')
        when 'campaign' then coalesce(m.campaign_name, m.campaign_id, 'Campanha não identificada')
        when 'adset' then coalesce(m.adset_name, m.adset_id, 'Conjunto não identificado')
        when 'ad' then coalesce(m.ad_name, m.ad_id, 'Anúncio não identificado')
        when 'creative' then coalesce(
          m.headline,
          m.creative_name,
          m.creative_id,
          'Sem criativo identificado'
        )
      end as group_name,

      m.account_id,
      m.account_name,

      case when p_dimension in ('campaign', 'adset', 'ad') then m.campaign_id end as campaign_id,
      case when p_dimension in ('campaign', 'adset', 'ad') then m.campaign_name end as campaign_name,

      case when p_dimension in ('adset', 'ad') then m.adset_id end as adset_id,
      case when p_dimension in ('adset', 'ad') then m.adset_name end as adset_name,

      case when p_dimension in ('ad', 'creative') then m.ad_id end as ad_id,
      case when p_dimension in ('ad', 'creative') then m.ad_name end as ad_name,

      case when p_dimension = 'creative' then m.creative_id end as creative_id,
      case when p_dimension = 'creative' then m.creative_name end as creative_name,

      case when p_dimension = 'creative' then m.thumbnail_url end as thumbnail_url,
      case when p_dimension = 'creative' then m.image_url end as image_url,
      case when p_dimension = 'creative' then m.creative_url end as creative_url,
      case when p_dimension = 'creative' then m.headline end as headline,
      case when p_dimension = 'creative' then m.primary_text end as primary_text,

      m.date::timestamp without time zone as sort_at,
      1::integer as source_priority,

      coalesce(m.spend, 0::numeric) as spend,
      coalesce(m.impressions, 0)::bigint as impressions,
      coalesce(m.clicks, 0)::bigint as clicks

    from public.v_meta_ads_v2 m
    where m.client_id = p_client_id
      and m.date between p_start_date and p_end_date
  ),

  -- --------------------------------------------------------------------------
  -- Leads da coorte e respectivos marcos cumulativos.
  -- --------------------------------------------------------------------------
  lead_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(h.account_id, '__meta_unmapped_account__')
        when 'campaign' then
          case
            when h.campaign_id is null then '__meta_unmapped_campaign__'
            else concat_ws('|', coalesce(h.account_id, '__no_account__'), h.campaign_id)
          end
        when 'adset' then
          case
            when h.adset_id is null then '__meta_unmapped_adset__'
            else concat_ws(
              '|',
              coalesce(h.account_id, '__no_account__'),
              coalesce(h.campaign_id, '__no_campaign__'),
              h.adset_id
            )
          end
        when 'ad' then
          coalesce(l.meta_ad_id, '__meta_unmapped_ad__')
        when 'creative' then
          coalesce(h.creative_id, '__meta_unmapped_creative__')
      end as group_id,

      case p_dimension
        when 'account' then coalesce(h.account_name, h.account_id, 'Conta não identificada')
        when 'campaign' then coalesce(h.campaign_name, h.campaign_id, 'Campanha não identificada')
        when 'adset' then coalesce(h.adset_name, h.adset_id, 'Conjunto não identificado')
        when 'ad' then coalesce(h.ad_name, l.meta_ad_id, 'Anúncio não identificado')
        when 'creative' then coalesce(
          h.headline,
          h.creative_name,
          h.creative_id,
          'Sem criativo identificado'
        )
      end as group_name,

      h.account_id,
      h.account_name,

      case when p_dimension in ('campaign', 'adset', 'ad') then h.campaign_id end as campaign_id,
      case when p_dimension in ('campaign', 'adset', 'ad') then h.campaign_name end as campaign_name,

      case when p_dimension in ('adset', 'ad') then h.adset_id end as adset_id,
      case when p_dimension in ('adset', 'ad') then h.adset_name end as adset_name,

      case when p_dimension in ('ad', 'creative') then l.meta_ad_id end as ad_id,
      case when p_dimension in ('ad', 'creative') then h.ad_name end as ad_name,

      case when p_dimension = 'creative' then h.creative_id end as creative_id,
      case when p_dimension = 'creative' then h.creative_name end as creative_name,

      case when p_dimension = 'creative' then h.thumbnail_url end as thumbnail_url,
      case when p_dimension = 'creative' then h.image_url end as image_url,
      case when p_dimension = 'creative' then h.creative_url end as creative_url,
      case when p_dimension = 'creative' then h.headline end as headline,
      case when p_dimension = 'creative' then h.primary_text end as primary_text,

      l.lead_date::timestamp without time zone as sort_at,
      2::integer as source_priority,

      l.contact_id,
      l.has_primeira_conversa,
      l.has_agendado,
      l.has_ganho

    from public.v_client_leads_by_stage_v2 l
    left join ad_hierarchy_latest h
      on h.ad_id = l.meta_ad_id
    where l.client_id = p_client_id
      and l.lead_date between p_start_date and p_end_date
      and l.attribution_platform = 'Meta Ads'
  ),

  -- --------------------------------------------------------------------------
  -- Vendas oficiais da coorte. Uma linha de origem = uma oportunidade ganha.
  -- --------------------------------------------------------------------------
  sale_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(h.account_id, '__meta_unmapped_account__')
        when 'campaign' then
          case
            when h.campaign_id is null then '__meta_unmapped_campaign__'
            else concat_ws('|', coalesce(h.account_id, '__no_account__'), h.campaign_id)
          end
        when 'adset' then
          case
            when h.adset_id is null then '__meta_unmapped_adset__'
            else concat_ws(
              '|',
              coalesce(h.account_id, '__no_account__'),
              coalesce(h.campaign_id, '__no_campaign__'),
              h.adset_id
            )
          end
        when 'ad' then
          coalesce(s.meta_ad_id, '__meta_unmapped_ad__')
        when 'creative' then
          coalesce(h.creative_id, '__meta_unmapped_creative__')
      end as group_id,

      case p_dimension
        when 'account' then coalesce(h.account_name, h.account_id, 'Conta não identificada')
        when 'campaign' then coalesce(h.campaign_name, h.campaign_id, 'Campanha não identificada')
        when 'adset' then coalesce(h.adset_name, h.adset_id, 'Conjunto não identificado')
        when 'ad' then coalesce(h.ad_name, s.meta_ad_id, 'Anúncio não identificado')
        when 'creative' then coalesce(
          h.headline,
          h.creative_name,
          h.creative_id,
          'Sem criativo identificado'
        )
      end as group_name,

      h.account_id,
      h.account_name,

      case when p_dimension in ('campaign', 'adset', 'ad') then h.campaign_id end as campaign_id,
      case when p_dimension in ('campaign', 'adset', 'ad') then h.campaign_name end as campaign_name,

      case when p_dimension in ('adset', 'ad') then h.adset_id end as adset_id,
      case when p_dimension in ('adset', 'ad') then h.adset_name end as adset_name,

      case when p_dimension in ('ad', 'creative') then s.meta_ad_id end as ad_id,
      case when p_dimension in ('ad', 'creative') then h.ad_name end as ad_name,

      case when p_dimension = 'creative' then h.creative_id end as creative_id,
      case when p_dimension = 'creative' then h.creative_name end as creative_name,

      case when p_dimension = 'creative' then h.thumbnail_url end as thumbnail_url,
      case when p_dimension = 'creative' then h.image_url end as image_url,
      case when p_dimension = 'creative' then h.creative_url end as creative_url,
      case when p_dimension = 'creative' then h.headline end as headline,
      case when p_dimension = 'creative' then h.primary_text end as primary_text,

      s.contact_lead_date::timestamp without time zone as sort_at,
      3::integer as source_priority,

      s.opportunity_id,
      s.contact_id,
      s.is_acquisition_sale,
      s.has_valid_value,
      s.valor_ganho

    from public.v_crm_sales_v2 s
    left join ad_hierarchy_latest h
      on h.ad_id = s.meta_ad_id
    where s.client_id = p_client_id
      and s.contact_lead_date between p_start_date and p_end_date
      and s.is_cohort_linkable is true
      and s.attribution_platform = 'Meta Ads'
  ),

  -- --------------------------------------------------------------------------
  -- Catálogo das dimensões: garante linhas de mídia e também linhas apenas CRM.
  -- --------------------------------------------------------------------------
  catalog_rows as (
    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      adset_id,
      adset_name,
      ad_id,
      ad_name,
      creative_id,
      creative_name,
      thumbnail_url,
      image_url,
      creative_url,
      headline,
      primary_text,
      sort_at,
      source_priority
    from media_tagged

    union all

    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      adset_id,
      adset_name,
      ad_id,
      ad_name,
      creative_id,
      creative_name,
      thumbnail_url,
      image_url,
      creative_url,
      headline,
      primary_text,
      sort_at,
      source_priority
    from lead_tagged

    union all

    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      adset_id,
      adset_name,
      ad_id,
      ad_name,
      creative_id,
      creative_name,
      thumbnail_url,
      image_url,
      creative_url,
      headline,
      primary_text,
      sort_at,
      source_priority
    from sale_tagged
  ),

  dimension_catalog as (
    select
      cr.group_id,
      (array_agg(cr.group_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.group_name is not null))[1] as group_name,

      (array_agg(cr.account_id order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.account_id is not null))[1] as account_id,
      (array_agg(cr.account_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.account_name is not null))[1] as account_name,

      (array_agg(cr.campaign_id order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.campaign_id is not null))[1] as campaign_id,
      (array_agg(cr.campaign_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.campaign_name is not null))[1] as campaign_name,

      (array_agg(cr.adset_id order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.adset_id is not null))[1] as adset_id,
      (array_agg(cr.adset_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.adset_name is not null))[1] as adset_name,

      (array_agg(cr.ad_id order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.ad_id is not null))[1] as ad_id,
      (array_agg(cr.ad_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.ad_name is not null))[1] as ad_name,

      (array_agg(cr.creative_id order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.creative_id is not null))[1] as creative_id,
      (array_agg(cr.creative_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.creative_name is not null))[1] as creative_name,

      (array_agg(cr.thumbnail_url order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.thumbnail_url is not null))[1] as thumbnail_url,
      (array_agg(cr.image_url order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.image_url is not null))[1] as image_url,
      (array_agg(cr.creative_url order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.creative_url is not null))[1] as creative_url,
      (array_agg(cr.headline order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.headline is not null))[1] as headline,
      (array_agg(cr.primary_text order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.primary_text is not null))[1] as primary_text

    from catalog_rows cr
    group by cr.group_id
  ),

  media_agg as (
    select
      mt.group_id,
      sum(mt.spend)::numeric as spend,
      sum(mt.impressions)::bigint as impressions,
      sum(mt.clicks)::bigint as clicks
    from media_tagged mt
    group by mt.group_id
  ),

  lead_agg as (
    select
      lt.group_id,
      count(*)::bigint as crm_leads,
      count(*) filter (where lt.has_primeira_conversa is true)::bigint
        as crm_primeiras_conversas,
      count(*) filter (where lt.has_agendado is true)::bigint
        as crm_agendados,
      count(*) filter (where lt.has_ganho is true)::bigint
        as crm_ganhos
    from lead_tagged lt
    group by lt.group_id
  ),

  sale_agg as (
    select
      st.group_id,

      count(distinct st.contact_id) filter (
        where st.is_acquisition_sale is true
      )::bigint as acquisition_buying_contacts,

      count(*) filter (
        where st.is_acquisition_sale is true
      )::bigint as acquisition_sales,

      sum(st.valor_ganho) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is true
      )::numeric as acquisition_revenue,

      count(*) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is true
      )::bigint as acquisition_sales_with_valid_value,

      count(*) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is not true
      )::bigint as acquisition_sales_without_valid_value,

      count(distinct st.contact_id)::bigint as cohort_buying_contacts,
      count(*)::bigint as cohort_total_sales,

      count(*) filter (
        where st.is_acquisition_sale is not true
      )::bigint as cohort_sales_without_own_lead,

      sum(st.valor_ganho) filter (
        where st.has_valid_value is true
      )::numeric as total_cohort_revenue,

      count(*) filter (
        where st.has_valid_value is true
      )::bigint as cohort_sales_with_valid_value,

      count(*) filter (
        where st.has_valid_value is not true
      )::bigint as cohort_sales_without_valid_value

    from sale_tagged st
    group by st.group_id
  ),

  assembled as (
    select
      dc.group_id,
      dc.group_name,
      dc.account_id,
      dc.account_name,
      dc.campaign_id,
      dc.campaign_name,
      dc.adset_id,
      dc.adset_name,
      dc.ad_id,
      dc.ad_name,
      dc.creative_id,
      dc.creative_name,
      dc.thumbnail_url,
      dc.image_url,
      dc.creative_url,
      dc.headline,
      dc.primary_text,

      coalesce(ma.spend, 0::numeric) as spend,
      coalesce(ma.impressions, 0)::bigint as impressions,
      coalesce(ma.clicks, 0)::bigint as clicks,

      coalesce(la.crm_leads, 0)::bigint as crm_leads,
      coalesce(la.crm_primeiras_conversas, 0)::bigint as crm_primeiras_conversas,
      coalesce(la.crm_agendados, 0)::bigint as crm_agendados,
      coalesce(la.crm_ganhos, 0)::bigint as crm_ganhos,

      coalesce(sa.acquisition_buying_contacts, 0)::bigint
        as acquisition_buying_contacts,
      coalesce(sa.acquisition_sales, 0)::bigint as acquisition_sales,
      sa.acquisition_revenue,
      coalesce(sa.acquisition_sales_with_valid_value, 0)::bigint
        as acquisition_sales_with_valid_value,
      coalesce(sa.acquisition_sales_without_valid_value, 0)::bigint
        as acquisition_sales_without_valid_value,

      coalesce(sa.cohort_buying_contacts, 0)::bigint as cohort_buying_contacts,
      coalesce(sa.cohort_total_sales, 0)::bigint as cohort_total_sales,
      coalesce(sa.cohort_sales_without_own_lead, 0)::bigint
        as cohort_sales_without_own_lead,
      sa.total_cohort_revenue,
      coalesce(sa.cohort_sales_with_valid_value, 0)::bigint
        as cohort_sales_with_valid_value,
      coalesce(sa.cohort_sales_without_valid_value, 0)::bigint
        as cohort_sales_without_valid_value

    from dimension_catalog dc
    left join media_agg ma on ma.group_id = dc.group_id
    left join lead_agg la on la.group_id = dc.group_id
    left join sale_agg sa on sa.group_id = dc.group_id
  )

  select
    p_dimension::text as dimension,
    a.group_id,
    a.group_name,

    a.account_id,
    a.account_name,
    a.campaign_id,
    a.campaign_name,
    a.adset_id,
    a.adset_name,
    a.ad_id,
    a.ad_name,
    a.creative_id,
    a.creative_name,

    a.thumbnail_url,
    a.image_url,
    a.creative_url,
    a.headline,
    a.primary_text,

    a.spend,
    a.impressions,
    a.clicks,

    case
      when a.impressions > 0
        then a.clicks::numeric / a.impressions::numeric
    end as ctr,

    case
      when a.clicks > 0
        then a.spend / a.clicks::numeric
    end as cpc,

    a.crm_leads,
    a.crm_primeiras_conversas,
    a.crm_agendados,
    a.crm_ganhos,

    a.acquisition_buying_contacts,
    a.acquisition_sales,
    a.acquisition_revenue,
    a.acquisition_sales_with_valid_value,
    a.acquisition_sales_without_valid_value,

    case
      when a.acquisition_sales = 0 then null
      when a.acquisition_sales_without_valid_value = 0 then true
      else false
    end as acquisition_revenue_is_complete,

    a.cohort_buying_contacts,
    a.cohort_total_sales,
    a.cohort_sales_without_own_lead,
    a.total_cohort_revenue,
    a.cohort_sales_with_valid_value,
    a.cohort_sales_without_valid_value,

    case
      when a.cohort_total_sales = 0 then null
      when a.cohort_sales_without_valid_value = 0 then true
      else false
    end as cohort_revenue_is_complete,

    case
      when a.spend > 0 and a.crm_leads > 0
        then a.spend / a.crm_leads::numeric
    end as cpl,

    case
      when a.spend > 0 and a.crm_agendados > 0
        then a.spend / a.crm_agendados::numeric
    end as cost_per_agendado,

    case
      when a.spend > 0 and a.crm_ganhos > 0
        then a.spend / a.crm_ganhos::numeric
    end as cost_per_gain,

    case
      when a.spend > 0 and a.acquisition_buying_contacts > 0
        then a.spend / a.acquisition_buying_contacts::numeric
    end as cac_acquisition,

    case
      when a.spend > 0
       and a.acquisition_sales > 0
       and a.acquisition_sales_without_valid_value = 0
        then a.acquisition_revenue / a.spend
    end as roas_acquisition,

    case
      when a.spend > 0
       and a.cohort_total_sales > 0
       and a.cohort_sales_without_valid_value = 0
        then a.total_cohort_revenue / a.spend
    end as roas_total_cohort

  from assembled a
  order by
    a.spend desc,
    a.group_name nulls last,
    a.group_id;
end;
$$;


ALTER FUNCTION "public"."get_meta_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_meta_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text") IS 'ImpulsHub V2: resumo full-funnel da Meta por account, campaign, adset, ad ou creative. Mídia pela data de entrega; CRM e vendas pela coorte do lead. Atribuição técnica por meta_ad_id. Venda é oportunidade; ganho é marco da jornada. Receita incompleta mantém ROAS NULL. No nível creative, utiliza o último creative_id conhecido do anúncio para CRM e vendas, prioriza headline como nome amigável e expõe ad_name/ad_id do anúncio representativo.';



CREATE OR REPLACE FUNCTION "public"."get_meta_campaign_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") RETURNS TABLE("account_id" "text", "account_name" "text", "campaign_id" "text", "campaign_name" "text", "spend" numeric, "meta_conversions" numeric, "crm_leads" bigint, "crm_agendados" bigint, "crm_ganhos" bigint, "receita" numeric)
    LANGUAGE "sql" STABLE
    AS $$
  WITH midia AS (
    SELECT
      m.account_id, m.account_name, m.campaign_id, m.campaign_name,
      SUM(m.spend) AS spend,
      SUM(COALESCE(m.meta_platform_conversions, 0)) AS meta_conversions
    FROM meta_ads_daily m
    WHERE m.client_id = p_client_id AND m.date BETWEEN p_start AND p_end
    GROUP BY m.account_id, m.account_name, m.campaign_id, m.campaign_name
  ),
  ad_para_campanha AS (
    SELECT DISTINCT m.ad_id, m.campaign_id
    FROM meta_ads_daily m
    WHERE m.client_id = p_client_id AND m.date BETWEEN p_start AND p_end
  ),
  crm AS (
    SELECT
      a.campaign_id,
      COUNT(*) FILTER (WHERE e.event_code = 'lead')     AS crm_leads,
      COUNT(*) FILTER (WHERE e.event_code = 'agendado') AS crm_agendados,
      COUNT(*) FILTER (WHERE e.event_code = 'ganho' OR e.status = 'won') AS crm_ganhos,
      COALESCE(SUM(e.valor_ganho) FILTER (WHERE e.event_code = 'ganho' OR e.status = 'won'), 0) AS receita
    FROM v_crm_events_enriched e
    JOIN ad_para_campanha a ON a.ad_id = e.meta_ad_id
    WHERE e.client_id = p_client_id AND e.event_date BETWEEN p_start AND p_end
      AND e.meta_ad_id IS NOT NULL
    GROUP BY a.campaign_id
  )
  SELECT
    mid.account_id, mid.account_name, mid.campaign_id, mid.campaign_name,
    mid.spend, mid.meta_conversions,
    COALESCE(c.crm_leads, 0), COALESCE(c.crm_agendados, 0),
    COALESCE(c.crm_ganhos, 0), COALESCE(c.receita, 0)
  FROM midia mid
  LEFT JOIN crm c ON c.campaign_id = mid.campaign_id;
$$;


ALTER FUNCTION "public"."get_meta_campaign_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_meta_creative_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") RETURNS TABLE("account_id" "text", "ad_id" "text", "ad_name" "text", "headline" "text", "creative_url" "text", "image_url" "text", "thumbnail_url" "text", "video_id" "text", "spend" numeric, "impressions" bigint, "clicks" bigint, "meta_conversions" numeric, "crm_leads" bigint, "crm_agendados" bigint, "crm_ganhos" bigint, "receita" numeric)
    LANGUAGE "sql" STABLE
    AS $$
  WITH midia AS (
    SELECT
      m.account_id, m.ad_id,
      -- nome/imagem: pega o valor mais recente dentro do período (evita
      -- misturar textos antigos se o anúncio foi editado no meio do caminho)
      (array_agg(m.ad_name ORDER BY m.date DESC))[1] AS ad_name,
      (array_agg(m.headline ORDER BY m.date DESC) FILTER (WHERE m.headline IS NOT NULL))[1] AS headline,
      (array_agg(m.creative_url ORDER BY m.date DESC) FILTER (WHERE m.creative_url IS NOT NULL))[1] AS creative_url,
      (array_agg(m.image_url ORDER BY m.date DESC) FILTER (WHERE m.image_url IS NOT NULL))[1] AS image_url,
      (array_agg(m.thumbnail_url ORDER BY m.date DESC) FILTER (WHERE m.thumbnail_url IS NOT NULL))[1] AS thumbnail_url,
      (array_agg(m.video_id ORDER BY m.date DESC) FILTER (WHERE m.video_id IS NOT NULL))[1] AS video_id,
      SUM(m.spend) AS spend,
      SUM(m.impressions) AS impressions,
      SUM(m.clicks) AS clicks,
      SUM(COALESCE(m.meta_platform_conversions, 0)) AS meta_conversions
    FROM meta_ads_daily m
    WHERE m.client_id = p_client_id AND m.date BETWEEN p_start AND p_end
    GROUP BY m.account_id, m.ad_id
  ),
  crm AS (
    SELECT
      e.meta_ad_id AS ad_id,
      COUNT(*) FILTER (WHERE e.event_code = 'lead')     AS crm_leads,
      COUNT(*) FILTER (WHERE e.event_code = 'agendado') AS crm_agendados,
      COUNT(*) FILTER (WHERE e.event_code = 'ganho' OR e.status = 'won') AS crm_ganhos,
      COALESCE(SUM(e.valor_ganho) FILTER (WHERE e.event_code = 'ganho' OR e.status = 'won'), 0) AS receita
    FROM v_crm_events_enriched e
    WHERE e.client_id = p_client_id AND e.event_date BETWEEN p_start AND p_end
      AND e.meta_ad_id IS NOT NULL
    GROUP BY e.meta_ad_id
  )
  SELECT
    mid.account_id, mid.ad_id, mid.ad_name, mid.headline,
    mid.creative_url, mid.image_url, mid.thumbnail_url, mid.video_id,
    mid.spend, mid.impressions, mid.clicks, mid.meta_conversions,
    COALESCE(c.crm_leads, 0), COALESCE(c.crm_agendados, 0),
    COALESCE(c.crm_ganhos, 0), COALESCE(c.receita, 0)
  FROM midia mid
  LEFT JOIN crm c ON c.ad_id = mid.ad_id;
$$;


ALTER FUNCTION "public"."get_meta_creative_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."intake_form_lead"("p_client_slug" "text", "p_form_intake_token" "uuid", "p_full_name" "text", "p_phone" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_gclid" "text" DEFAULT NULL::"text", "p_gbraid" "text" DEFAULT NULL::"text", "p_wbraid" "text" DEFAULT NULL::"text", "p_utm_source" "text" DEFAULT NULL::"text", "p_utm_medium" "text" DEFAULT NULL::"text", "p_utm_campaign" "text" DEFAULT NULL::"text", "p_utm_content" "text" DEFAULT NULL::"text", "p_utm_term" "text" DEFAULT NULL::"text", "p_page_url" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
  -- IMP-230 (revisao do Head): grava o historico inicial, como todo resto do
  -- sistema faz ao abrir um card (a validacao so exige isso em UPDATE, mas
  -- sem esta linha a aba de historico do card nasceria vazia).
  insert into crm.opportunity_stage_history
    (tenant_id, opportunity_id, from_stage_id, to_stage_id, transition_type, origin, actor_profile_id, reason, occurred_at)
  values
    (v_tenant, v_opp, null, v_stage, 'automatic', 'sistema', null, 'formulario do site (IMP-230)', pg_catalog.now());
  return pg_catalog.jsonb_build_object('contact_id', v_contact, 'opportunity_id', v_opp, 'deduped', false);
end
$$;


ALTER FUNCTION "public"."intake_form_lead"("p_client_slug" "text", "p_form_intake_token" "uuid", "p_full_name" "text", "p_phone" "text", "p_email" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text", "p_utm_source" "text", "p_utm_medium" "text", "p_utm_campaign" "text", "p_utm_content" "text", "p_utm_term" "text", "p_page_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_channel_source"("p_lead_origem" "text", "p_lead_entrada" "text", "p_meta_ad_id" "text", "p_google_campaign_id" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text") RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  select
    case
      -- 1. FONTE PRIMÁRIA: lead_origem
      when nullif(trim(coalesce(p_lead_origem, '')), '') is not null then
        case
          when lower(p_lead_origem) ~ '(fbads|facebook|meta|ctwa|click_to_whatsapp|lead_ads|3_1|3_2)'
            then 'Meta Ads'

          when lower(p_lead_origem) ~ '(gmb|google meu neg)'
            then 'Google Meu Negócio'

          when lower(p_lead_origem) ~ '(google_ads|google ads|gads|google cpc|paid_google)'
            then 'Google Ads'

          when lower(p_lead_origem) ~ '(instagram|ig)'
            then 'Instagram Orgânico'

          when lower(p_lead_origem) ~ '(form_site|form site|site|website|formul|3_3)'
            then 'Site'

          when lower(p_lead_origem) ~ '(first_whatsapp|whatsapp_direto|whatsapp direto|whatsapp|3_4)'
            then 'WhatsApp Direto'

          when lower(p_lead_origem) ~ '(indic)'
            then 'Indicação'

          when lower(p_lead_origem) ~ '(organico|orgânico|organic)'
            then 'Orgânico'

          else trim(p_lead_origem)
        end

      -- 2. FALLBACK TÉCNICO: só se lead_origem estiver vazio
      when nullif(trim(coalesce(p_meta_ad_id, '')), '') is not null
        then 'Meta Ads'

      when nullif(trim(coalesce(p_google_campaign_id, '')), '') is not null
        or nullif(trim(coalesce(p_gclid, '')), '') is not null
        or nullif(trim(coalesce(p_gbraid, '')), '') is not null
        or nullif(trim(coalesce(p_wbraid, '')), '') is not null
        then 'Google Ads'

      when lower(coalesce(p_lead_entrada, '')) ~ '(whatsapp)'
        then 'WhatsApp Direto'

      when lower(coalesce(p_lead_entrada, '')) ~ '(site|form)'
        then 'Site'

      else 'Não Identificado'
    end;
$$;


ALTER FUNCTION "public"."normalize_channel_source"("p_lead_origem" "text", "p_lead_entrada" "text", "p_meta_ad_id" "text", "p_google_campaign_id" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_lead_channel_v2"("p_lead_origem" "text", "p_meta_ad_id" "text", "p_google_campaign_id" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text") RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$

  select case

    /*
     * 1. Evidência técnica de mídia paga.
     * Identificador técnico ganha de texto livre.
     */

    when nullif(
      trim(coalesce(p_meta_ad_id, '')),
      ''
    ) is not null
      then 'Meta Ads'

    when
         nullif(trim(coalesce(p_google_campaign_id, '')), '') is not null
      or nullif(trim(coalesce(p_gclid, '')), '') is not null
      or nullif(trim(coalesce(p_gbraid, '')), '') is not null
      or nullif(trim(coalesce(p_wbraid, '')), '') is not null
      then 'Google Ads'

    /*
     * 2. Origem textual explícita.
     */

    when lower(trim(coalesce(p_lead_origem, '')))
      ~ '(fbads|facebook|meta|ctwa|click_to_whatsapp|lead_ads|3_1|3_2)'
      then 'Meta Ads'

    when lower(trim(coalesce(p_lead_origem, '')))
      ~ '(google_ads|google ads|gads|google cpc|paid_google)'
      then 'Google Ads'

    when lower(trim(coalesce(p_lead_origem, '')))
      ~ '(gmb|google meu neg)'
      then 'Google Meu Negócio'

    when lower(trim(coalesce(p_lead_origem, '')))
      ~ '(instagram|instagram orgânico|instagram organico)'
      then 'Instagram Orgânico'

    when lower(trim(coalesce(p_lead_origem, '')))
      ~ '(form_site|form site|site|website|formul|3_3)'
      then 'Site'

    /*
     * Não usamos a palavra genérica "whatsapp".
     * Um anúncio Meta também pode entrar por WhatsApp.
     */

    when lower(trim(coalesce(p_lead_origem, '')))
      ~ '(first_whatsapp|whatsapp_direto|whatsapp direto|3_4)'
      then 'WhatsApp Direto'

    when lower(trim(coalesce(p_lead_origem, '')))
      ~ '(indic)'
      then 'Indicação'

    when lower(trim(coalesce(p_lead_origem, '')))
      ~ '(organico|orgânico|organic)'
      then 'Orgânico'

    /*
     * Ausência de evidência não vira orgânico.
     */

    else 'Não atribuído'

  end;

$$;


ALTER FUNCTION "public"."resolve_lead_channel_v2"("p_lead_origem" "text", "p_meta_ad_id" "text", "p_google_campaign_id" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."canonical_loss_reasons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "label" "text" NOT NULL,
    "requires_note" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "canonical_loss_reasons_code_check" CHECK ((("code" = "lower"("code")) AND ("length"("code") > 0))),
    CONSTRAINT "canonical_loss_reasons_label_check" CHECK (("length"("btrim"("label")) > 0))
);


ALTER TABLE "crm"."canonical_loss_reasons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."commercial_outcomes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "opportunity_id" "uuid" NOT NULL,
    "outcome" "text" NOT NULL,
    "origin" "text" NOT NULL,
    "actor_profile_id" "uuid",
    "loss_reason_id" "uuid",
    "evidence" "text",
    "value" numeric(14,2),
    "value_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "currency" "text",
    "is_current" boolean DEFAULT true NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "commercial_outcomes_check" CHECK ((("outcome" = 'lost'::"text") = ("loss_reason_id" IS NOT NULL))),
    CONSTRAINT "commercial_outcomes_check1" CHECK (((("value_status" = 'pending'::"text") AND ("value" IS NULL) AND ("currency" IS NULL)) OR (("value_status" = 'valid'::"text") AND ("value" IS NOT NULL) AND ("value" > (0)::numeric) AND ("currency" IS NOT NULL) AND ("length"("btrim"("currency")) > 0)))),
    CONSTRAINT "commercial_outcomes_check2" CHECK ((("outcome" <> 'lost'::"text") OR ("value_status" = 'pending'::"text"))),
    CONSTRAINT "commercial_outcomes_origin_check" CHECK (("origin" = ANY (ARRAY['frase_configurada'::"text", 'manual'::"text", 'integracao'::"text", 'sistema'::"text"]))),
    CONSTRAINT "commercial_outcomes_outcome_check" CHECK (("outcome" = ANY (ARRAY['won'::"text", 'lost'::"text"]))),
    CONSTRAINT "commercial_outcomes_value_status_check" CHECK (("value_status" = ANY (ARRAY['pending'::"text", 'valid'::"text"])))
);


ALTER TABLE "crm"."commercial_outcomes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."contact_identities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "value_normalized" "text" NOT NULL,
    "provider" "text",
    "is_verified" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contact_identities_kind_check" CHECK (("kind" = ANY (ARRAY['phone'::"text", 'jid'::"text", 'lid'::"text", 'email'::"text", 'external'::"text"]))),
    CONSTRAINT "contact_identities_value_normalized_check" CHECK (("length"("btrim"("value_normalized")) > 0))
);


ALTER TABLE "crm"."contact_identities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."event_map" (
    "event_code" "text" NOT NULL,
    "stage_code" "text" NOT NULL,
    "version" integer NOT NULL,
    "event_name" "text" NOT NULL,
    "funnel_step" smallint,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "event_map_version_check" CHECK (("version" > 0))
);


ALTER TABLE "crm"."event_map" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."global_pipeline_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "version_no" integer NOT NULL,
    "status" "text" NOT NULL,
    "published_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "global_pipeline_versions_check" CHECK ((("status" <> 'active'::"text") OR ("published_at" IS NOT NULL))),
    CONSTRAINT "global_pipeline_versions_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text", 'retired'::"text"]))),
    CONSTRAINT "global_pipeline_versions_version_no_check" CHECK (("version_no" > 0))
);


ALTER TABLE "crm"."global_pipeline_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."opportunity_milestones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "opportunity_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "origin" "text" NOT NULL,
    "actor_profile_id" "uuid",
    "evidence" "text",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "opportunity_milestones_kind_check" CHECK (("kind" = ANY (ARRAY['lead_received'::"text", 'conversation_started'::"text", 'appointment'::"text", 'attendance'::"text", 'proposal'::"text", 'sale'::"text", 'revenue'::"text"]))),
    CONSTRAINT "opportunity_milestones_origin_check" CHECK (("origin" = ANY (ARRAY['frase_configurada'::"text", 'manual'::"text", 'integracao'::"text", 'sistema'::"text"])))
);


ALTER TABLE "crm"."opportunity_milestones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."opportunity_stage_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "opportunity_id" "uuid" NOT NULL,
    "from_stage_id" "uuid",
    "to_stage_id" "uuid" NOT NULL,
    "transition_type" "text" NOT NULL,
    "origin" "text" NOT NULL,
    "actor_profile_id" "uuid",
    "source_activity_id" "uuid",
    "source_rule_version_id" "uuid",
    "reason" "text",
    "compensates_history_id" "uuid",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "opportunity_stage_history_origin_check" CHECK (("origin" = ANY (ARRAY['frase_configurada'::"text", 'manual'::"text", 'integracao'::"text", 'sistema'::"text"]))),
    CONSTRAINT "opportunity_stage_history_transition_type_check" CHECK (("transition_type" = ANY (ARRAY['automatic'::"text", 'manual'::"text", 'undo'::"text", 'correction'::"text"])))
);


ALTER TABLE "crm"."opportunity_stage_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."processed_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "raw_event_id" "uuid" NOT NULL,
    "source" "text" NOT NULL,
    "external_id" "text" NOT NULL,
    "payload_hash" "text" NOT NULL,
    "status" "text" DEFAULT 'processing'::"text" NOT NULL,
    "error_code" "text",
    "processed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "processed_events_external_id_check" CHECK (("length"("btrim"("external_id")) > 0)),
    CONSTRAINT "processed_events_payload_hash_check" CHECK (("length"("payload_hash") >= 32)),
    CONSTRAINT "processed_events_source_check" CHECK (("length"("btrim"("source")) > 0)),
    CONSTRAINT "processed_events_status_check" CHECK (("status" = ANY (ARRAY['processing'::"text", 'processed'::"text", 'failed'::"text", 'rejected'::"text"])))
);


ALTER TABLE "crm"."processed_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "crm"."tenant_memberships" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_assignable" boolean DEFAULT false NOT NULL,
    CONSTRAINT "tenant_memberships_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'admin'::"text", 'manager'::"text", 'attendant'::"text", 'integration'::"text", 'viewer'::"text"]))),
    CONSTRAINT "tenant_memberships_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'suspended'::"text", 'removed'::"text"])))
);


ALTER TABLE "crm"."tenant_memberships" OWNER TO "postgres";


COMMENT ON COLUMN "crm"."tenant_memberships"."is_assignable" IS 'Membro operacional elegivel para ser dono CRC ou Vendas; separado de can_write.';



CREATE TABLE IF NOT EXISTS "crm"."tenants" (
    "id" "uuid" NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "tenants_name_check" CHECK (("length"("btrim"("name")) > 0)),
    CONSTRAINT "tenants_slug_check" CHECK ((("slug" = "lower"("slug")) AND (("length"("slug") >= 3) AND ("length"("slug") <= 80)))),
    CONSTRAINT "tenants_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'paused'::"text", 'archived'::"text"])))
);


ALTER TABLE "crm"."tenants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_google_ads_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "google_ads_customer_id" "text" NOT NULL,
    "google_ads_customer_name" "text",
    "google_ads_login_customer_id" "text",
    "is_primary" boolean DEFAULT false,
    "sync_enabled" boolean DEFAULT true,
    "source" "text" DEFAULT 'onboarding_form'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."client_google_ads_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_meta_ad_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "meta_ad_account_id" "text" NOT NULL,
    "meta_ad_account_name" "text",
    "is_primary" boolean DEFAULT false,
    "sync_enabled" boolean DEFAULT true,
    "source" "text" DEFAULT 'onboarding_form'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."client_meta_ad_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'viewer'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "client_users_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'admin'::"text", 'manager'::"text", 'viewer'::"text", 'agency'::"text", 'attendant'::"text"])))
);


ALTER TABLE "public"."client_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."conversion_outbox" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "normalized_event_id" "uuid" NOT NULL,
    "ghl_location_id" "text" NOT NULL,
    "contact_id" "text",
    "event_code" "text" NOT NULL,
    "platform" "text" DEFAULT 'meta'::"text" NOT NULL,
    "route" "text" NOT NULL,
    "meta_event_name" "text" NOT NULL,
    "payload" "jsonb",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "response" "jsonb",
    "last_error" "text",
    "next_attempt_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sent_at" timestamp with time zone,
    "platform_event_name" "text",
    "platform_conversion_action" "text",
    "platform_account_id" "text",
    "platform_manager_account_id" "text",
    "dispatch_method" "text",
    "external_job_id" "text",
    "external_request_id" "text",
    "http_status" integer,
    "error_code" "text",
    "error_subcode" "text",
    "error_details" "jsonb",
    "match_keys" "jsonb" DEFAULT '{}'::"jsonb",
    "request_body" "jsonb",
    "destination_config" "jsonb" DEFAULT '{}'::"jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."conversion_outbox" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."database_documentation_registry" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "content_md" "text" NOT NULL,
    "status" "text" DEFAULT 'current'::"text" NOT NULL,
    "version" integer NOT NULL,
    "generated_from" "text",
    "generated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "approved_at" timestamp with time zone,
    "approved_by" "uuid",
    "supersedes_id" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."database_documentation_registry" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events_normalized" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "raw_event_id" "uuid" NOT NULL,
    "client_id" "uuid",
    "ghl_location_id" "text",
    "ghl_location_name" "text",
    "client_name" "text",
    "event_code" "text" NOT NULL,
    "event_name" "text" NOT NULL,
    "funnel_step" smallint,
    "event_datetime" timestamp with time zone NOT NULL,
    "source_system" "text" DEFAULT 'ghl'::"text" NOT NULL,
    "source_event_type" "text",
    "source_workflow_id" "text",
    "source_workflow_name" "text",
    "contact_id" "text",
    "first_name" "text",
    "last_name" "text",
    "full_name" "text",
    "phone" "text",
    "email" "text",
    "contact_type" "text",
    "tags" "text",
    "lead_origem" "text",
    "lead_entrada" "text",
    "lead_agencias" "text",
    "conversion_source" "text",
    "entry_point_conversion_source" "text",
    "entry_point_conversion_app" "text",
    "source_type" "text",
    "source_id" "text",
    "source_url" "text",
    "source_ads" boolean,
    "ad_title" "text",
    "ctwa_clid" "text",
    "ctwa_payload" "text",
    "fbp" "text",
    "fbc" "text",
    "fbclid" "text",
    "gclid" "text",
    "gbraid" "text",
    "wbraid" "text",
    "ga_client_id" "text",
    "ga_session_id" "text",
    "procedure_interest" "text",
    "procedure_closed" "text",
    "budget_status" "text",
    "budget_value" numeric(14,2),
    "closed_value" numeric(14,2),
    "payment_method" "text",
    "loss_reason_category" "text",
    "loss_reason_detail" "text",
    "normalization_status" "text" DEFAULT 'normalized'::"text" NOT NULL,
    "normalization_error" "text",
    "normalized_payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "received_at" timestamp with time zone,
    "location_id" "text",
    "location_name" "text",
    "opportunity_id" "text",
    "pipeline_id" "text",
    "pipeline_name" "text",
    "pipeline_stage" "text",
    "status" "text",
    "phone_raw" "text",
    "utm_source" "text",
    "utm_medium" "text",
    "utm_campaign" "text",
    "utm_content" "text",
    "utm_term" "text",
    "valor_ganho" numeric,
    "forma_ganho" "text",
    "procedimento_ganho" "text",
    "motivo_perda_categoria" "text",
    "motivo_perda_detalhe" "text",
    "payload" "jsonb",
    "google_campaign_id" "text",
    "google_adgroup_id" "text",
    "google_ad_id" "text",
    "google_keyword" "text",
    "google_network" "text",
    "google_device" "text",
    "produto_servico" "text",
    "categoria_produto_servico" "text"
);


ALTER TABLE "public"."events_normalized" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events_raw" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source_system" "text",
    "event_type" "text",
    "location_id" "text",
    "contact_id" "text",
    "phone" "text",
    "email" "text",
    "request_method" "text",
    "request_path" "text",
    "request_headers" "jsonb",
    "request_query" "jsonb",
    "request_body" "jsonb",
    "payload" "jsonb" NOT NULL,
    "processing_status" "text" DEFAULT 'received'::"text" NOT NULL,
    "processing_error" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "location_name" "text",
    "processed_at" timestamp with time zone
);


ALTER TABLE "public"."events_raw" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_ga4_raw" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "property_id" "text",
    "property_name" "text",
    "date" "date" NOT NULL,
    "session_source" "text",
    "session_medium" "text",
    "session_campaign_id" "text",
    "session_campaign_name" "text",
    "default_channel_group" "text",
    "landing_page" "text",
    "sessions" bigint DEFAULT 0 NOT NULL,
    "active_users" bigint DEFAULT 0 NOT NULL,
    "new_users" bigint DEFAULT 0 NOT NULL,
    "engaged_sessions" bigint DEFAULT 0 NOT NULL,
    "engagement_rate" numeric(18,8) DEFAULT 0 NOT NULL,
    "views" bigint DEFAULT 0 NOT NULL,
    "event_count" bigint DEFAULT 0 NOT NULL,
    "generate_leads" bigint DEFAULT 0 NOT NULL,
    "begin_checkout" bigint DEFAULT 0 NOT NULL,
    "purchases" bigint DEFAULT 0 NOT NULL,
    "purchase_revenue" numeric(18,6) DEFAULT 0 NOT NULL,
    "source_system" "text" DEFAULT 'google_sheets'::"text" NOT NULL,
    "source_sheet" "text" DEFAULT '02_GA4_RAW'::"text" NOT NULL,
    "source_row_key" "text" NOT NULL,
    "source_row_number" integer,
    "n8n_execution_id" "text",
    "raw_payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."external_ga4_raw" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_hotmart_raw" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "transaction_id" "text",
    "purchase_date" timestamp with time zone,
    "approval_date" timestamp with time zone,
    "source_updated_at" timestamp with time zone,
    "transaction_status" "text",
    "product_id" "text",
    "product_name" "text",
    "offer_id" "text",
    "offer_name" "text",
    "gross_value" numeric(18,6) DEFAULT 0 NOT NULL,
    "net_value" numeric(18,6) DEFAULT 0 NOT NULL,
    "currency" "text" DEFAULT 'BRL'::"text" NOT NULL,
    "payment_method" "text",
    "installments" integer,
    "subscription_id" "text",
    "utm_source" "text",
    "utm_medium" "text",
    "utm_campaign" "text",
    "utm_content" "text",
    "utm_term" "text",
    "campaign" "text",
    "source" "text",
    "tracking_code" "text",
    "source_system" "text" DEFAULT 'google_sheets'::"text" NOT NULL,
    "source_sheet" "text" DEFAULT '03_HOTMART_RAW'::"text" NOT NULL,
    "source_row_key" "text" NOT NULL,
    "source_row_number" integer,
    "n8n_execution_id" "text",
    "raw_payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."external_hotmart_raw" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_meta_ads_raw" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "account_name" "text",
    "account_id" "text" NOT NULL,
    "campaign_id" "text",
    "campaign_name" "text",
    "adset_id" "text",
    "adset_name" "text",
    "ad_id" "text" NOT NULL,
    "ad_name" "text",
    "date" "date" NOT NULL,
    "spend" numeric(18,6) DEFAULT 0 NOT NULL,
    "impressions" bigint DEFAULT 0 NOT NULL,
    "link_clicks" bigint DEFAULT 0 NOT NULL,
    "landing_page_views" bigint DEFAULT 0 NOT NULL,
    "initiated_checkouts" bigint DEFAULT 0 NOT NULL,
    "omni_purchases" bigint DEFAULT 0 NOT NULL,
    "omni_purchase_value" numeric(18,6) DEFAULT 0 NOT NULL,
    "leads" bigint DEFAULT 0 NOT NULL,
    "source_system" "text" DEFAULT 'google_sheets'::"text" NOT NULL,
    "source_sheet" "text" DEFAULT '01_META_RAW'::"text" NOT NULL,
    "source_row_key" "text" NOT NULL,
    "source_row_number" integer,
    "n8n_execution_id" "text",
    "raw_payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."external_meta_ads_raw" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."form_intake_rate_limit" (
    "window_started" timestamp with time zone NOT NULL,
    "ip" "inet" NOT NULL,
    "form_intake_token" "uuid" NOT NULL,
    "request_count" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "form_intake_rate_limit_request_count_check" CHECK (("request_count" >= 0))
);


ALTER TABLE "public"."form_intake_rate_limit" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."google_ads_campaign_daily" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "customer_id" "text" NOT NULL,
    "customer_name" "text",
    "campaign_id" "text" NOT NULL,
    "campaign_name" "text",
    "campaign_status" "text",
    "advertising_channel_type" "text",
    "advertising_channel_sub_type" "text",
    "impressions" bigint DEFAULT 0 NOT NULL,
    "clicks" bigint DEFAULT 0 NOT NULL,
    "cost_micros" bigint DEFAULT 0 NOT NULL,
    "cost" numeric DEFAULT 0 NOT NULL,
    "ctr" numeric,
    "average_cpc_micros" bigint,
    "average_cpc" numeric,
    "conversions" numeric DEFAULT 0 NOT NULL,
    "conversions_value" numeric DEFAULT 0 NOT NULL,
    "all_conversions" numeric DEFAULT 0 NOT NULL,
    "all_conversions_value" numeric DEFAULT 0 NOT NULL,
    "source_payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."google_ads_campaign_daily" OWNER TO "postgres";


COMMENT ON TABLE "public"."google_ads_campaign_daily" IS 'Performance Google Ads no grão cliente + dia + conta + campanha. Fonte oficial para análise de conta e campanhas.';



COMMENT ON COLUMN "public"."google_ads_campaign_daily"."advertising_channel_type" IS 'Tipo principal retornado pelo Google Ads, como SEARCH, PERFORMANCE_MAX, DISPLAY, VIDEO ou DEMAND_GEN.';



COMMENT ON COLUMN "public"."google_ads_campaign_daily"."advertising_channel_sub_type" IS 'Subtipo oficial da campanha retornado pela API do Google Ads.';



COMMENT ON COLUMN "public"."google_ads_campaign_daily"."cost" IS 'Investimento convertido de cost_micros para unidade monetária.';



CREATE TABLE IF NOT EXISTS "public"."google_ads_daily" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "customer_id" "text" NOT NULL,
    "customer_name" "text",
    "campaign_id" "text" NOT NULL,
    "campaign_name" "text",
    "campaign_status" "text",
    "ad_group_id" "text" NOT NULL,
    "ad_group_name" "text",
    "ad_group_status" "text",
    "ad_id" "text" NOT NULL,
    "ad_name" "text",
    "ad_type" "text",
    "ad_status" "text",
    "impressions" integer DEFAULT 0,
    "clicks" integer DEFAULT 0,
    "cost_micros" bigint DEFAULT 0,
    "cost" numeric DEFAULT 0,
    "ctr" numeric DEFAULT 0,
    "average_cpc_micros" bigint DEFAULT 0,
    "average_cpc" numeric DEFAULT 0,
    "conversions" numeric DEFAULT 0,
    "conversions_value" numeric DEFAULT 0,
    "all_conversions" numeric DEFAULT 0,
    "all_conversions_value" numeric DEFAULT 0,
    "source_payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."google_ads_daily" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."google_ads_keywords_daily" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "client_name" "text",
    "google_ads_customer_id" "text" NOT NULL,
    "date" "date" NOT NULL,
    "campaign_id" "text",
    "campaign_name" "text",
    "ad_group_id" "text",
    "ad_group_name" "text",
    "keyword_id" "text",
    "keyword_text" "text",
    "keyword_match_type" "text",
    "keyword_status" "text",
    "impressions" bigint DEFAULT 0,
    "clicks" bigint DEFAULT 0,
    "cost_micros" bigint DEFAULT 0,
    "cost" numeric GENERATED ALWAYS AS ((("cost_micros")::numeric / 1000000.0)) STORED,
    "conversions" numeric DEFAULT 0,
    "conversions_value" numeric DEFAULT 0,
    "ctr" numeric,
    "average_cpc_micros" bigint,
    "average_cpc" numeric GENERATED ALWAYS AS ((("average_cpc_micros")::numeric / 1000000.0)) STORED,
    "raw_payload" "jsonb" DEFAULT '{}'::"jsonb",
    "synced_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."google_ads_keywords_daily" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."meta_leads_export_temp_temp" (
    "phone" "text",
    "ad_id" "text",
    "adset_id" "text",
    "campaign_id" "text",
    "created_time" timestamp with time zone,
    "campaign_name" "text"
);


ALTER TABLE "public"."meta_leads_export_temp_temp" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stevo_events_raw" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "stevo_instance_row_id" "uuid",
    "stevo_instance_id" "text",
    "client_id" "uuid",
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "event_type" "text",
    "external_message_id" "text",
    "event_timestamp" timestamp with time zone,
    "http_method" "text",
    "headers" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "query_params" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "payload_hash" "text",
    "parse_status" "text" DEFAULT 'raw'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."stevo_events_raw" OWNER TO "postgres";


COMMENT ON TABLE "public"."stevo_events_raw" IS 'MVP append-only para observar payloads brutos recebidos dos webhooks Stevo antes de definir schema canonico.';



CREATE TABLE IF NOT EXISTS "public"."stevo_instances" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "stevo_instance_id" "text" NOT NULL,
    "client_id" "uuid",
    "name" "text",
    "engine" "text",
    "phone_number" "text",
    "profile_name" "text",
    "connected" boolean,
    "ghl_location_id" "text",
    "server_url" "text",
    "raw_instance" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "last_sync_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."stevo_instances" OWNER TO "postgres";


COMMENT ON TABLE "public"."stevo_instances" IS 'MVP registry das instancias Stevo. Nao armazena token operacional.';



CREATE OR REPLACE VIEW "public"."v_ads_spend_daily" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "date",
    "platform",
    "account_id",
    "account_name",
    "campaign_id",
    "campaign_name",
    "ad_group_id",
    "ad_group_name",
    "ad_id",
    "ad_name",
    "spend",
    "impressions",
    "clicks",
    "updated_at"
   FROM ( SELECT "md"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "md"."date",
            'meta_ads'::"text" AS "platform",
            "md"."account_id",
            "md"."account_name",
            "md"."campaign_id",
            "md"."campaign_name",
            "md"."adset_id" AS "ad_group_id",
            "md"."adset_name" AS "ad_group_name",
            "md"."ad_id",
            "md"."ad_name",
            COALESCE("md"."spend", (0)::numeric) AS "spend",
            (COALESCE("md"."impressions", 0))::bigint AS "impressions",
            (COALESCE("md"."clicks", 0))::bigint AS "clicks",
            "md"."updated_at"
           FROM ("public"."meta_ads_daily" "md"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "md"."client_id")))
        UNION ALL
         SELECT "gd"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "gd"."date",
            'google_ads'::"text" AS "platform",
            "gd"."customer_id" AS "account_id",
            "gd"."customer_name" AS "account_name",
            "gd"."campaign_id",
            "gd"."campaign_name",
            "gd"."ad_group_id",
            "gd"."ad_group_name",
            "gd"."ad_id",
            "gd"."ad_name",
            COALESCE("gd"."cost", (0)::numeric) AS "spend",
            (COALESCE("gd"."impressions", 0))::bigint AS "impressions",
            (COALESCE("gd"."clicks", 0))::bigint AS "clicks",
            "gd"."updated_at"
           FROM ("public"."google_ads_daily" "gd"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "gd"."client_id")))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_ads_spend_daily" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_events_enriched" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "id",
    "raw_event_id",
    "client_id",
    "client_name",
    "client_slug",
    "received_at",
    "event_date",
    "event_code",
    "contact_id",
    "opportunity_id",
    "lead_origem",
    "lead_entrada",
    "meta_ad_id",
    "source_type",
    "source_url",
    "google_campaign_id",
    "google_adgroup_id",
    "google_ad_id",
    "google_keyword",
    "gclid",
    "gbraid",
    "wbraid",
    "channel_source",
    "valor_ganho",
    "forma_ganho",
    "procedimento_ganho",
    "motivo_perda_categoria",
    "motivo_perda_detalhe",
    "payload",
    "status",
    "pipeline_stage"
   FROM ( SELECT "en"."id",
            "en"."raw_event_id",
            "en"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "en"."received_at",
            ((COALESCE("en"."event_datetime", "en"."received_at") AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "event_date",
            "en"."event_code",
            "en"."contact_id",
            "en"."opportunity_id",
            "en"."lead_origem",
            "en"."lead_entrada",
            "en"."source_id" AS "meta_ad_id",
            "en"."source_type",
            "en"."source_url",
            "en"."google_campaign_id",
            "en"."google_adgroup_id",
            "en"."google_ad_id",
            "en"."google_keyword",
            "en"."gclid",
            "en"."gbraid",
            "en"."wbraid",
            "public"."normalize_channel_source"("en"."lead_origem", "en"."lead_entrada", "en"."source_id", "en"."google_campaign_id", "en"."gclid", "en"."gbraid", "en"."wbraid") AS "channel_source",
            COALESCE("en"."valor_ganho", (0)::numeric) AS "valor_ganho",
            "en"."forma_ganho",
            "en"."procedimento_ganho",
            "en"."motivo_perda_categoria",
            "en"."motivo_perda_detalhe",
            NULL::"jsonb" AS "payload",
            "en"."status",
            "en"."pipeline_stage"
           FROM ("public"."events_normalized" "en"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "en"."client_id")))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_crm_events_enriched" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_funnel_daily" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "event_date",
    "channel_source",
    "crm_leads",
    "crm_primeiras_conversas",
    "crm_agendados",
    "crm_ganhos",
    "crm_perdidos",
    "receita"
   FROM ( WITH "leads" AS (
                 SELECT "v_crm_events_enriched"."contact_id",
                    "v_crm_events_enriched"."client_id",
                    "v_crm_events_enriched"."client_name",
                    "v_crm_events_enriched"."client_slug",
                    "v_crm_events_enriched"."event_date",
                    COALESCE("v_crm_events_enriched"."channel_source", 'Não Identificado'::"text") AS "channel_source"
                   FROM "public"."v_crm_events_enriched"
                  WHERE ("v_crm_events_enriched"."event_code" = 'lead'::"text")
                )
         SELECT "l"."client_id",
            "l"."client_name",
            "l"."client_slug",
            "l"."event_date",
            "l"."channel_source",
            "count"(*) AS "crm_leads",
            "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
                   FROM "public"."v_crm_events_enriched" "e"
                  WHERE (("e"."contact_id" = "l"."contact_id") AND ("e"."event_code" = 'primeira_conversa'::"text"))))) AS "crm_primeiras_conversas",
            "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
                   FROM "public"."v_crm_events_enriched" "e"
                  WHERE (("e"."contact_id" = "l"."contact_id") AND ("e"."event_code" = 'agendado'::"text"))))) AS "crm_agendados",
            "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
                   FROM "public"."v_crm_events_enriched" "e"
                  WHERE (("e"."contact_id" = "l"."contact_id") AND (("e"."event_code" = 'ganho'::"text") OR ("e"."status" = 'won'::"text") OR ("e"."pipeline_stage" ~~* '%ganho%'::"text")))))) AS "crm_ganhos",
            "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
                   FROM "public"."v_crm_events_enriched" "e"
                  WHERE (("e"."contact_id" = "l"."contact_id") AND (("e"."event_code" = 'perdido'::"text") OR ("e"."status" = 'lost'::"text") OR ("e"."pipeline_stage" ~~* '%perdido%'::"text")))))) AS "crm_perdidos",
            COALESCE("sum"("dedup"."valor_ganho"), (0)::numeric) AS "receita"
           FROM ("leads" "l"
             LEFT JOIN LATERAL ( SELECT DISTINCT ON ("e"."contact_id") "e"."valor_ganho"
                   FROM "public"."v_crm_events_enriched" "e"
                  WHERE (("e"."contact_id" = "l"."contact_id") AND (("e"."event_code" = 'ganho'::"text") OR ("e"."status" = 'won'::"text")))
                  ORDER BY "e"."contact_id", "e"."received_at" DESC) "dedup" ON (true))
          GROUP BY "l"."client_id", "l"."client_name", "l"."client_slug", "l"."event_date", "l"."channel_source") "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_crm_funnel_daily" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_channel_performance_daily" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "date",
    "channel_source",
    "spend",
    "impressions",
    "clicks",
    "crm_leads",
    "crm_primeiras_conversas",
    "crm_agendados",
    "crm_ganhos",
    "crm_perdidos",
    "receita",
    "cpl_real",
    "custo_por_agendado",
    "cac",
    "roas_real"
   FROM ( WITH "ads_channel" AS (
                 SELECT "v_ads_spend_daily"."client_id",
                    "v_ads_spend_daily"."client_name",
                    "v_ads_spend_daily"."client_slug",
                    "v_ads_spend_daily"."date" AS "event_date",
                        CASE
                            WHEN ("v_ads_spend_daily"."platform" = 'meta_ads'::"text") THEN 'Meta Ads'::"text"
                            WHEN ("v_ads_spend_daily"."platform" = 'google_ads'::"text") THEN 'Google Ads'::"text"
                            ELSE "v_ads_spend_daily"."platform"
                        END AS "channel_source",
                    "sum"("v_ads_spend_daily"."spend") AS "spend",
                    "sum"("v_ads_spend_daily"."impressions") AS "impressions",
                    "sum"("v_ads_spend_daily"."clicks") AS "clicks"
                   FROM "public"."v_ads_spend_daily"
                  GROUP BY "v_ads_spend_daily"."client_id", "v_ads_spend_daily"."client_name", "v_ads_spend_daily"."client_slug", "v_ads_spend_daily"."date",
                        CASE
                            WHEN ("v_ads_spend_daily"."platform" = 'meta_ads'::"text") THEN 'Meta Ads'::"text"
                            WHEN ("v_ads_spend_daily"."platform" = 'google_ads'::"text") THEN 'Google Ads'::"text"
                            ELSE "v_ads_spend_daily"."platform"
                        END
                ), "crm_channel" AS (
                 SELECT "v_crm_funnel_daily"."client_id",
                    "v_crm_funnel_daily"."client_name",
                    "v_crm_funnel_daily"."client_slug",
                    "v_crm_funnel_daily"."event_date",
                    "v_crm_funnel_daily"."channel_source",
                    "sum"("v_crm_funnel_daily"."crm_leads") AS "crm_leads",
                    "sum"("v_crm_funnel_daily"."crm_primeiras_conversas") AS "crm_primeiras_conversas",
                    "sum"("v_crm_funnel_daily"."crm_agendados") AS "crm_agendados",
                    "sum"("v_crm_funnel_daily"."crm_ganhos") AS "crm_ganhos",
                    "sum"("v_crm_funnel_daily"."crm_perdidos") AS "crm_perdidos",
                    "sum"("v_crm_funnel_daily"."receita") AS "receita"
                   FROM "public"."v_crm_funnel_daily"
                  GROUP BY "v_crm_funnel_daily"."client_id", "v_crm_funnel_daily"."client_name", "v_crm_funnel_daily"."client_slug", "v_crm_funnel_daily"."event_date", "v_crm_funnel_daily"."channel_source"
                )
         SELECT COALESCE("a"."client_id", "c"."client_id") AS "client_id",
            COALESCE("a"."client_name", "c"."client_name") AS "client_name",
            COALESCE("a"."client_slug", "c"."client_slug") AS "client_slug",
            COALESCE("a"."event_date", "c"."event_date") AS "date",
            COALESCE("a"."channel_source", "c"."channel_source") AS "channel_source",
            COALESCE("a"."spend", (0)::numeric) AS "spend",
            COALESCE("a"."impressions", (0)::numeric) AS "impressions",
            COALESCE("a"."clicks", (0)::numeric) AS "clicks",
            COALESCE("c"."crm_leads", (0)::numeric) AS "crm_leads",
            COALESCE("c"."crm_primeiras_conversas", (0)::numeric) AS "crm_primeiras_conversas",
            COALESCE("c"."crm_agendados", (0)::numeric) AS "crm_agendados",
            COALESCE("c"."crm_ganhos", (0)::numeric) AS "crm_ganhos",
            COALESCE("c"."crm_perdidos", (0)::numeric) AS "crm_perdidos",
            COALESCE("c"."receita", (0)::numeric) AS "receita",
                CASE
                    WHEN (COALESCE("c"."crm_leads", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_leads")
                    ELSE NULL::numeric
                END AS "cpl_real",
                CASE
                    WHEN (COALESCE("c"."crm_agendados", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_agendados")
                    ELSE NULL::numeric
                END AS "custo_por_agendado",
                CASE
                    WHEN (COALESCE("c"."crm_ganhos", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_ganhos")
                    ELSE NULL::numeric
                END AS "cac",
                CASE
                    WHEN (COALESCE("a"."spend", (0)::numeric) > (0)::numeric) THEN (COALESCE("c"."receita", (0)::numeric) / "a"."spend")
                    ELSE NULL::numeric
                END AS "roas_real"
           FROM ("ads_channel" "a"
             FULL JOIN "crm_channel" "c" ON ((("c"."client_id" = "a"."client_id") AND ("c"."event_date" = "a"."event_date") AND ("c"."channel_source" = "a"."channel_source"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_channel_performance_daily" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_client_daily_pulse" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "date",
    "leads",
    "conversas",
    "agendados",
    "ganhos",
    "perdidos",
    "receita"
   FROM ( SELECT "v_crm_events_enriched"."client_id",
            "v_crm_events_enriched"."event_date" AS "date",
            "count"(*) FILTER (WHERE ("v_crm_events_enriched"."event_code" = 'lead'::"text")) AS "leads",
            "count"(*) FILTER (WHERE ("v_crm_events_enriched"."event_code" = 'primeira_conversa'::"text")) AS "conversas",
            "count"(*) FILTER (WHERE ("v_crm_events_enriched"."event_code" = 'agendado'::"text")) AS "agendados",
            "count"(*) FILTER (WHERE (("v_crm_events_enriched"."event_code" = 'ganho'::"text") OR ("v_crm_events_enriched"."status" = 'won'::"text"))) AS "ganhos",
            "count"(*) FILTER (WHERE (("v_crm_events_enriched"."event_code" = 'perdido'::"text") OR ("v_crm_events_enriched"."status" = 'lost'::"text"))) AS "perdidos",
            COALESCE("sum"("v_crm_events_enriched"."valor_ganho") FILTER (WHERE (("v_crm_events_enriched"."event_code" = 'ganho'::"text") OR ("v_crm_events_enriched"."status" = 'won'::"text"))), (0)::numeric) AS "receita"
           FROM "public"."v_crm_events_enriched"
          GROUP BY "v_crm_events_enriched"."client_id", "v_crm_events_enriched"."event_date") "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_client_daily_pulse" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_client_lead_channel_daily" WITH ("security_invoker"='true') AS
 SELECT "client_id",
    "event_date" AS "date",
    "lead_entrada",
    "lead_origem",
    "channel_source",
    "count"(*) AS "leads"
   FROM "public"."v_crm_events_enriched"
  WHERE ("event_code" = 'lead'::"text")
  GROUP BY "client_id", "event_date", "lead_entrada", "lead_origem", "channel_source";


ALTER VIEW "public"."v_client_lead_channel_daily" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_client_leads_by_stage" WITH ("security_invoker"='true') AS
 WITH "jornada" AS (
         SELECT "en"."client_id",
            "en"."contact_id",
            ("array_agg"("en"."full_name" ORDER BY "en"."event_datetime" DESC) FILTER (WHERE ("en"."full_name" IS NOT NULL)))[1] AS "full_name",
            ("array_agg"("en"."phone" ORDER BY "en"."event_datetime" DESC) FILTER (WHERE ("en"."phone" IS NOT NULL)))[1] AS "phone",
            ("array_agg"("en"."email" ORDER BY "en"."event_datetime" DESC) FILTER (WHERE ("en"."email" IS NOT NULL)))[1] AS "email",
            ("array_agg"("public"."normalize_channel_source"("en"."lead_origem", "en"."lead_entrada", "en"."source_id", "en"."google_campaign_id", "en"."gclid", "en"."gbraid", "en"."wbraid") ORDER BY "en"."event_datetime") FILTER (WHERE (("en"."lead_origem" IS NOT NULL) OR ("en"."lead_entrada" IS NOT NULL))))[1] AS "channel_source",
            ("array_agg"("en"."lead_entrada" ORDER BY "en"."event_datetime") FILTER (WHERE ("en"."lead_entrada" IS NOT NULL)))[1] AS "lead_entrada",
            "min"("en"."event_datetime") AS "data_entrada",
            "bool_or"(("en"."event_code" = 'primeira_conversa'::"text")) AS "teve_primeira_conversa",
            "bool_or"(("en"."event_code" = 'agendado'::"text")) AS "teve_agendado",
            "bool_or"((("en"."event_code" = 'ganho'::"text") OR ("en"."status" = 'won'::"text"))) AS "teve_ganho",
            "bool_or"((("en"."event_code" = 'perdido'::"text") OR ("en"."status" = 'lost'::"text"))) AS "teve_perdido"
           FROM "public"."events_normalized" "en"
          WHERE ("en"."contact_id" IS NOT NULL)
          GROUP BY "en"."client_id", "en"."contact_id"
        )
 SELECT "client_id",
    "contact_id",
    "full_name",
    "phone",
    "email",
    COALESCE("channel_source", 'Não Identificado'::"text") AS "channel_source",
    "lead_entrada",
    "data_entrada",
        CASE
            WHEN "teve_ganho" THEN 'Ganho'::"text"
            WHEN "teve_perdido" THEN 'Perdido'::"text"
            WHEN "teve_agendado" THEN 'Agendado'::"text"
            WHEN "teve_primeira_conversa" THEN 'Primeira conversa'::"text"
            ELSE 'Lead'::"text"
        END AS "etapa",
        CASE
            WHEN "teve_ganho" THEN 5
            WHEN "teve_perdido" THEN 0
            WHEN "teve_agendado" THEN 3
            WHEN "teve_primeira_conversa" THEN 2
            ELSE 1
        END AS "etapa_ordem"
   FROM "jornada";


ALTER VIEW "public"."v_client_leads_by_stage" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_lead_journey_v2" WITH ("security_invoker"='true') AS
 WITH "contact_rollup" AS (
         SELECT "en"."client_id",
            "en"."contact_id",
            ("array_agg"("en"."full_name" ORDER BY COALESCE("en"."event_datetime", "en"."received_at") DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."full_name" IS NOT NULL)))[1] AS "full_name",
            ("array_agg"("en"."phone" ORDER BY COALESCE("en"."event_datetime", "en"."received_at") DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."phone" IS NOT NULL)))[1] AS "phone",
            ("array_agg"("en"."email" ORDER BY COALESCE("en"."event_datetime", "en"."received_at") DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."email" IS NOT NULL)))[1] AS "email",
            "count"(*) AS "total_events",
            "count"(*) FILTER (WHERE ("en"."event_code" = 'lead'::"text")) AS "lead_event_count",
            "count"(*) FILTER (WHERE (("en"."event_code" = 'lead'::"text") AND ("en"."event_datetime" IS NULL))) AS "lead_events_without_datetime",
            "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'lead'::"text")) AS "lead_at",
            "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'primeira_conversa'::"text")) AS "primeira_conversa_at",
            "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'agendado'::"text")) AS "agendado_at",
            "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'ganho'::"text")) AS "ganho_at",
            "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'perdido'::"text")) AS "perdido_at",
            ("array_agg"("en"."event_code" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_datetime" IS NOT NULL) AND ("en"."event_code" = ANY (ARRAY['primeira_conversa'::"text", 'agendado'::"text", 'ganho'::"text", 'perdido'::"text"])))))[1] AS "latest_stage_code"
           FROM "public"."events_normalized" "en"
          WHERE ("en"."contact_id" IS NOT NULL)
          GROUP BY "en"."client_id", "en"."contact_id"
        ), "lead_attribution" AS (
         SELECT "en"."client_id",
            "en"."contact_id",
            ("array_agg"("en"."lead_origem" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."lead_origem" IS NOT NULL)))[1] AS "lead_origem",
            ("array_agg"("en"."lead_entrada" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."lead_entrada" IS NOT NULL)))[1] AS "lead_entrada",
            ("array_agg"("en"."source_id" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ((NULLIF(TRIM(BOTH FROM COALESCE("en"."source_id", ''::"text")), ''::"text") IS NOT NULL) AND (("lower"(COALESCE("en"."lead_origem", ''::"text")) ~ '(fbads|facebook|meta|ctwa|click_to_whatsapp|lead_ads|3_1|3_2)'::"text") OR (NULLIF(TRIM(BOTH FROM COALESCE("en"."ctwa_clid", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("en"."fbclid", ''::"text")), ''::"text") IS NOT NULL) OR ("lower"(COALESCE("en"."lead_entrada", ''::"text")) ~ '(form_fbads|lead_ads|click_to_whatsapp)'::"text") OR (NOT ((NULLIF(TRIM(BOTH FROM COALESCE("en"."google_campaign_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("en"."google_adgroup_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("en"."google_ad_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("en"."gclid", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("en"."gbraid", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("en"."wbraid", ''::"text")), ''::"text") IS NOT NULL)))))))[1] AS "meta_ad_id",
            ("array_agg"("en"."source_type" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."source_type" IS NOT NULL)))[1] AS "source_type",
            ("array_agg"("en"."source_url" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."source_url" IS NOT NULL)))[1] AS "source_url",
            ("array_agg"("en"."google_campaign_id" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."google_campaign_id" IS NOT NULL)))[1] AS "google_campaign_id",
            ("array_agg"("en"."google_adgroup_id" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."google_adgroup_id" IS NOT NULL)))[1] AS "google_adgroup_id",
            ("array_agg"("en"."google_ad_id" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."google_ad_id" IS NOT NULL)))[1] AS "google_ad_id",
            ("array_agg"("en"."google_keyword" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."google_keyword" IS NOT NULL)))[1] AS "google_keyword",
            ("array_agg"("en"."gclid" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."gclid" IS NOT NULL)))[1] AS "gclid",
            ("array_agg"("en"."gbraid" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."gbraid" IS NOT NULL)))[1] AS "gbraid",
            ("array_agg"("en"."wbraid" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."wbraid" IS NOT NULL)))[1] AS "wbraid"
           FROM "public"."events_normalized" "en"
          WHERE (("en"."contact_id" IS NOT NULL) AND ("en"."event_code" = 'lead'::"text"))
          GROUP BY "en"."client_id", "en"."contact_id"
        )
 SELECT "cr"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "cr"."contact_id",
    "cr"."full_name",
    "cr"."phone",
    "cr"."email",
    "cr"."lead_at",
    (("cr"."lead_at" AT TIME ZONE COALESCE(NULLIF("cb"."timezone", ''::"text"), 'America/Sao_Paulo'::"text")))::"date" AS "lead_date",
    "cr"."primeira_conversa_at",
    "cr"."agendado_at",
    "cr"."ganho_at",
    "cr"."perdido_at",
    ("cr"."primeira_conversa_at" IS NOT NULL) AS "has_primeira_conversa",
    ("cr"."agendado_at" IS NOT NULL) AS "has_agendado",
    ("cr"."ganho_at" IS NOT NULL) AS "has_ganho",
    ("cr"."perdido_at" IS NOT NULL) AS "has_perdido",
    COALESCE("cr"."latest_stage_code", 'lead'::"text") AS "etapa_codigo",
        CASE COALESCE("cr"."latest_stage_code", 'lead'::"text")
            WHEN 'primeira_conversa'::"text" THEN 'Primeira conversa'::"text"
            WHEN 'agendado'::"text" THEN 'Agendado'::"text"
            WHEN 'ganho'::"text" THEN 'Ganho'::"text"
            WHEN 'perdido'::"text" THEN 'Perdido'::"text"
            ELSE 'Lead'::"text"
        END AS "etapa",
        CASE COALESCE("cr"."latest_stage_code", 'lead'::"text")
            WHEN 'lead'::"text" THEN 1
            WHEN 'primeira_conversa'::"text" THEN 2
            WHEN 'agendado'::"text" THEN 3
            WHEN 'ganho'::"text" THEN 4
            WHEN 'perdido'::"text" THEN 5
            ELSE 99
        END AS "etapa_ordem",
    "la"."lead_origem",
    "la"."lead_entrada",
    "la"."meta_ad_id",
    "la"."source_type",
    "la"."source_url",
    "la"."google_campaign_id",
    "la"."google_adgroup_id",
    "la"."google_ad_id",
    "la"."google_keyword",
    "la"."gclid",
    "la"."gbraid",
    "la"."wbraid",
    "cr"."total_events",
    "cr"."lead_event_count",
    "cr"."lead_events_without_datetime"
   FROM (("contact_rollup" "cr"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "cr"."client_id")))
     LEFT JOIN "lead_attribution" "la" ON ((("la"."client_id" = "cr"."client_id") AND ("la"."contact_id" = "cr"."contact_id"))))
  WHERE ("cr"."lead_at" IS NOT NULL);


ALTER VIEW "public"."v_crm_lead_journey_v2" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_crm_lead_journey_v2" IS 'ImpulsHub V2: jornada canônica por client_id + contact_id. Atribuição restrita a eventos lead. Desde 2026-08-05, source_id só alimenta meta_ad_id quando há evidência explícita Meta ou ausência de evidência técnica Google, evitando falsos conflitos Google x Meta sem alterar o contrato da view.';



CREATE OR REPLACE VIEW "public"."v_client_leads_by_stage_v2" WITH ("security_invoker"='true') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "contact_id",
    "full_name",
    "phone",
    "email",
    "lead_at",
    "lead_date",
    "primeira_conversa_at",
    "agendado_at",
    "ganho_at",
    "perdido_at",
    "has_primeira_conversa",
    "has_agendado",
    "has_ganho",
    "has_perdido",
    "etapa_codigo",
    "etapa",
    "etapa_ordem",
    "lead_origem",
    "lead_entrada",
    "meta_ad_id",
    "google_campaign_id",
    "google_adgroup_id",
    "google_ad_id",
    "google_keyword",
    "gclid",
    "gbraid",
    "wbraid",
    (NULLIF(TRIM(BOTH FROM COALESCE("meta_ad_id", ''::"text")), ''::"text") IS NOT NULL) AS "has_meta_attribution",
    ((NULLIF(TRIM(BOTH FROM COALESCE("google_campaign_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("google_adgroup_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("google_ad_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("gclid", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("gbraid", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("wbraid", ''::"text")), ''::"text") IS NOT NULL)) AS "has_google_attribution",
        CASE
            WHEN ((NULLIF(TRIM(BOTH FROM COALESCE("meta_ad_id", ''::"text")), ''::"text") IS NOT NULL) AND ((NULLIF(TRIM(BOTH FROM COALESCE("google_campaign_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("google_adgroup_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("google_ad_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("gclid", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("gbraid", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("wbraid", ''::"text")), ''::"text") IS NOT NULL))) THEN 'Conflito de atribuição'::"text"
            WHEN (NULLIF(TRIM(BOTH FROM COALESCE("meta_ad_id", ''::"text")), ''::"text") IS NOT NULL) THEN 'Meta Ads'::"text"
            WHEN ((NULLIF(TRIM(BOTH FROM COALESCE("google_campaign_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("google_adgroup_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("google_ad_id", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("gclid", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("gbraid", ''::"text")), ''::"text") IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("wbraid", ''::"text")), ''::"text") IS NOT NULL)) THEN 'Google Ads'::"text"
            ELSE 'Não atribuído'::"text"
        END AS "attribution_platform",
    "total_events",
    "lead_event_count",
    "lead_events_without_datetime"
   FROM "public"."v_crm_lead_journey_v2" "j";


ALTER VIEW "public"."v_client_leads_by_stage_v2" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_client_performance_daily" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "date",
    "spend",
    "impressions",
    "clicks",
    "crm_leads",
    "crm_primeiras_conversas",
    "crm_agendados",
    "crm_ganhos",
    "crm_perdidos",
    "receita",
    "cpl_real",
    "custo_por_agendado",
    "cac",
    "roas_real",
    "ticket_medio"
   FROM ( WITH "ads" AS (
                 SELECT "v_ads_spend_daily"."client_id",
                    "v_ads_spend_daily"."client_name",
                    "v_ads_spend_daily"."client_slug",
                    "v_ads_spend_daily"."date" AS "event_date",
                    "sum"("v_ads_spend_daily"."spend") AS "spend",
                    "sum"("v_ads_spend_daily"."impressions") AS "impressions",
                    "sum"("v_ads_spend_daily"."clicks") AS "clicks"
                   FROM "public"."v_ads_spend_daily"
                  GROUP BY "v_ads_spend_daily"."client_id", "v_ads_spend_daily"."client_name", "v_ads_spend_daily"."client_slug", "v_ads_spend_daily"."date"
                ), "crm" AS (
                 SELECT "v_crm_funnel_daily"."client_id",
                    "v_crm_funnel_daily"."client_name",
                    "v_crm_funnel_daily"."client_slug",
                    "v_crm_funnel_daily"."event_date",
                    "sum"("v_crm_funnel_daily"."crm_leads") AS "crm_leads",
                    "sum"("v_crm_funnel_daily"."crm_primeiras_conversas") AS "crm_primeiras_conversas",
                    "sum"("v_crm_funnel_daily"."crm_agendados") AS "crm_agendados",
                    "sum"("v_crm_funnel_daily"."crm_ganhos") AS "crm_ganhos",
                    "sum"("v_crm_funnel_daily"."crm_perdidos") AS "crm_perdidos",
                    "sum"("v_crm_funnel_daily"."receita") AS "receita"
                   FROM "public"."v_crm_funnel_daily"
                  GROUP BY "v_crm_funnel_daily"."client_id", "v_crm_funnel_daily"."client_name", "v_crm_funnel_daily"."client_slug", "v_crm_funnel_daily"."event_date"
                )
         SELECT COALESCE("a"."client_id", "c"."client_id") AS "client_id",
            COALESCE("a"."client_name", "c"."client_name") AS "client_name",
            COALESCE("a"."client_slug", "c"."client_slug") AS "client_slug",
            COALESCE("a"."event_date", "c"."event_date") AS "date",
            COALESCE("a"."spend", (0)::numeric) AS "spend",
            COALESCE("a"."impressions", (0)::numeric) AS "impressions",
            COALESCE("a"."clicks", (0)::numeric) AS "clicks",
            COALESCE("c"."crm_leads", (0)::numeric) AS "crm_leads",
            COALESCE("c"."crm_primeiras_conversas", (0)::numeric) AS "crm_primeiras_conversas",
            COALESCE("c"."crm_agendados", (0)::numeric) AS "crm_agendados",
            COALESCE("c"."crm_ganhos", (0)::numeric) AS "crm_ganhos",
            COALESCE("c"."crm_perdidos", (0)::numeric) AS "crm_perdidos",
            COALESCE("c"."receita", (0)::numeric) AS "receita",
                CASE
                    WHEN (COALESCE("c"."crm_leads", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_leads")
                    ELSE NULL::numeric
                END AS "cpl_real",
                CASE
                    WHEN (COALESCE("c"."crm_agendados", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_agendados")
                    ELSE NULL::numeric
                END AS "custo_por_agendado",
                CASE
                    WHEN (COALESCE("c"."crm_ganhos", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_ganhos")
                    ELSE NULL::numeric
                END AS "cac",
                CASE
                    WHEN (COALESCE("a"."spend", (0)::numeric) > (0)::numeric) THEN (COALESCE("c"."receita", (0)::numeric) / "a"."spend")
                    ELSE NULL::numeric
                END AS "roas_real",
                CASE
                    WHEN (COALESCE("c"."crm_ganhos", (0)::numeric) > (0)::numeric) THEN (COALESCE("c"."receita", (0)::numeric) / "c"."crm_ganhos")
                    ELSE NULL::numeric
                END AS "ticket_medio"
           FROM ("ads" "a"
             FULL JOIN "crm" "c" ON ((("c"."client_id" = "a"."client_id") AND ("c"."event_date" = "a"."event_date"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_client_performance_daily" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_opportunities_v2" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "opportunity_id",
    "contact_id",
    "full_name",
    "phone",
    "email",
    "first_event_at",
    "first_event_date",
    "last_event_at",
    "lead_event_at",
    "primeira_conversa_at",
    "agendado_at",
    "ganho_at",
    "perdido_at",
    "opportunity_status",
    "is_won",
    "is_lost",
    "valor_ganho",
    "forma_ganho",
    "produto_servico",
    "categoria_produto_servico",
    "procedimento_ganho",
    "procedure_closed",
    "latest_event_code",
    "latest_pipeline_stage_raw",
    "latest_status_raw",
    "total_events",
    "distinct_contacts",
    "lead_event_count",
    "primeira_conversa_event_count",
    "agendado_event_count",
    "ganho_event_count",
    "perdido_event_count",
    "source_event_types",
    "contact_lead_at",
    "contact_lead_date",
    "has_contact_lead_journey",
    "attribution_platform",
    "lead_origem",
    "lead_entrada",
    "meta_ad_id",
    "google_campaign_id",
    "google_adgroup_id",
    "google_ad_id",
    "gclid",
    "gbraid",
    "wbraid"
   FROM ( WITH "opportunity_rollup" AS (
                 SELECT "en"."client_id",
                    TRIM(BOTH FROM "en"."opportunity_id") AS "opportunity_id",
                    "count"(*) AS "total_events",
                    "count"(DISTINCT "en"."contact_id") FILTER (WHERE ("en"."contact_id" IS NOT NULL)) AS "distinct_contacts",
                    ("array_agg"("en"."contact_id" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."contact_id" IS NOT NULL)))[1] AS "contact_id_candidate",
                    ("array_agg"("en"."full_name" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."full_name" IS NOT NULL)))[1] AS "full_name",
                    ("array_agg"("en"."phone" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."phone" IS NOT NULL)))[1] AS "phone",
                    ("array_agg"("en"."email" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."email" IS NOT NULL)))[1] AS "email",
                    "min"("en"."event_datetime") AS "first_event_at",
                    "max"("en"."event_datetime") AS "last_event_at",
                    "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'lead'::"text")) AS "lead_event_at",
                    "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'primeira_conversa'::"text")) AS "primeira_conversa_at",
                    "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'agendado'::"text")) AS "agendado_at",
                    "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'ganho'::"text")) AS "ganho_at",
                    "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'perdido'::"text")) AS "perdido_at",
                    "count"(*) FILTER (WHERE ("en"."event_code" = 'lead'::"text")) AS "lead_event_count",
                    "count"(*) FILTER (WHERE ("en"."event_code" = 'primeira_conversa'::"text")) AS "primeira_conversa_event_count",
                    "count"(*) FILTER (WHERE ("en"."event_code" = 'agendado'::"text")) AS "agendado_event_count",
                    "count"(*) FILTER (WHERE ("en"."event_code" = 'ganho'::"text")) AS "ganho_event_count",
                    "count"(*) FILTER (WHERE ("en"."event_code" = 'perdido'::"text")) AS "perdido_event_count",
                    "max"("en"."valor_ganho") FILTER (WHERE ("en"."event_code" = 'ganho'::"text")) AS "valor_ganho_candidate",
                    ("array_agg"("en"."forma_ganho" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_code" = 'ganho'::"text") AND ("en"."forma_ganho" IS NOT NULL))))[1] AS "forma_ganho_candidate",
                    ("array_agg"("en"."produto_servico" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_code" = 'ganho'::"text") AND ("en"."produto_servico" IS NOT NULL))))[1] AS "produto_servico_candidate",
                    ("array_agg"("en"."categoria_produto_servico" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_code" = 'ganho'::"text") AND ("en"."categoria_produto_servico" IS NOT NULL))))[1] AS "categoria_produto_servico_candidate",
                    ("array_agg"("en"."procedimento_ganho" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_code" = 'ganho'::"text") AND ("en"."procedimento_ganho" IS NOT NULL))))[1] AS "procedimento_ganho_candidate",
                    ("array_agg"("en"."procedure_closed" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_code" = 'ganho'::"text") AND ("en"."procedure_closed" IS NOT NULL))))[1] AS "procedure_closed_candidate",
                    ("array_agg"("en"."event_code" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC))[1] AS "latest_event_code",
                    ("array_agg"("en"."pipeline_stage" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."pipeline_stage" IS NOT NULL)))[1] AS "latest_pipeline_stage_raw",
                    ("array_agg"("en"."status" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."status" IS NOT NULL)))[1] AS "latest_status_raw",
                    "array_agg"(DISTINCT "en"."source_event_type" ORDER BY "en"."source_event_type") FILTER (WHERE ("en"."source_event_type" IS NOT NULL)) AS "source_event_types"
                   FROM "public"."events_normalized" "en"
                  WHERE (NULLIF(TRIM(BOTH FROM "en"."opportunity_id"), ''::"text") IS NOT NULL)
                  GROUP BY "en"."client_id", (TRIM(BOTH FROM "en"."opportunity_id"))
                ), "prepared" AS (
                 SELECT "o"."client_id",
                    "o"."opportunity_id",
                    "o"."total_events",
                    "o"."distinct_contacts",
                    "o"."contact_id_candidate",
                    "o"."full_name",
                    "o"."phone",
                    "o"."email",
                    "o"."first_event_at",
                    "o"."last_event_at",
                    "o"."lead_event_at",
                    "o"."primeira_conversa_at",
                    "o"."agendado_at",
                    "o"."ganho_at",
                    "o"."perdido_at",
                    "o"."lead_event_count",
                    "o"."primeira_conversa_event_count",
                    "o"."agendado_event_count",
                    "o"."ganho_event_count",
                    "o"."perdido_event_count",
                    "o"."valor_ganho_candidate",
                    "o"."forma_ganho_candidate",
                    "o"."produto_servico_candidate",
                    "o"."categoria_produto_servico_candidate",
                    "o"."procedimento_ganho_candidate",
                    "o"."procedure_closed_candidate",
                    "o"."latest_event_code",
                    "o"."latest_pipeline_stage_raw",
                    "o"."latest_status_raw",
                    "o"."source_event_types",
                        CASE
                            WHEN ("o"."distinct_contacts" = 1) THEN "o"."contact_id_candidate"
                            ELSE NULL::"text"
                        END AS "contact_id",
                        CASE
                            WHEN ("o"."ganho_event_count" = 1) THEN "o"."valor_ganho_candidate"
                            ELSE NULL::numeric
                        END AS "valor_ganho",
                        CASE
                            WHEN ("o"."ganho_event_count" = 1) THEN "o"."forma_ganho_candidate"
                            ELSE NULL::"text"
                        END AS "forma_ganho",
                        CASE
                            WHEN ("o"."ganho_event_count" = 1) THEN "o"."produto_servico_candidate"
                            ELSE NULL::"text"
                        END AS "produto_servico",
                        CASE
                            WHEN ("o"."ganho_event_count" = 1) THEN "o"."categoria_produto_servico_candidate"
                            ELSE NULL::"text"
                        END AS "categoria_produto_servico",
                        CASE
                            WHEN ("o"."ganho_event_count" = 1) THEN "o"."procedimento_ganho_candidate"
                            ELSE NULL::"text"
                        END AS "procedimento_ganho",
                        CASE
                            WHEN ("o"."ganho_event_count" = 1) THEN "o"."procedure_closed_candidate"
                            ELSE NULL::"text"
                        END AS "procedure_closed"
                   FROM "opportunity_rollup" "o"
                )
         SELECT "p"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "p"."opportunity_id",
            "p"."contact_id",
            "p"."full_name",
            "p"."phone",
            "p"."email",
            "p"."first_event_at",
            (("p"."first_event_at" AT TIME ZONE COALESCE(NULLIF("cb"."timezone", ''::"text"), 'America/Sao_Paulo'::"text")))::"date" AS "first_event_date",
            "p"."last_event_at",
            "p"."lead_event_at",
            "p"."primeira_conversa_at",
            "p"."agendado_at",
            "p"."ganho_at",
            "p"."perdido_at",
                CASE
                    WHEN (("p"."ganho_event_count" > 0) AND ("p"."perdido_event_count" > 0)) THEN 'conflito'::"text"
                    WHEN ("p"."ganho_event_count" > 0) THEN 'ganha'::"text"
                    WHEN ("p"."perdido_event_count" > 0) THEN 'perdida'::"text"
                    ELSE 'aberta'::"text"
                END AS "opportunity_status",
            ("p"."ganho_event_count" > 0) AS "is_won",
            ("p"."perdido_event_count" > 0) AS "is_lost",
            "p"."valor_ganho",
            "p"."forma_ganho",
            "p"."produto_servico",
            "p"."categoria_produto_servico",
            "p"."procedimento_ganho",
            "p"."procedure_closed",
            "p"."latest_event_code",
            "p"."latest_pipeline_stage_raw",
            "p"."latest_status_raw",
            "p"."total_events",
            "p"."distinct_contacts",
            "p"."lead_event_count",
            "p"."primeira_conversa_event_count",
            "p"."agendado_event_count",
            "p"."ganho_event_count",
            "p"."perdido_event_count",
            "p"."source_event_types",
            "j"."lead_at" AS "contact_lead_at",
            "j"."lead_date" AS "contact_lead_date",
            ("j"."contact_id" IS NOT NULL) AS "has_contact_lead_journey",
            "j"."attribution_platform",
            "j"."lead_origem",
            "j"."lead_entrada",
            "j"."meta_ad_id",
            "j"."google_campaign_id",
            "j"."google_adgroup_id",
            "j"."google_ad_id",
            "j"."gclid",
            "j"."gbraid",
            "j"."wbraid"
           FROM (("prepared" "p"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "p"."client_id")))
             LEFT JOIN "public"."v_client_leads_by_stage_v2" "j" ON ((("j"."client_id" = "p"."client_id") AND ("j"."contact_id" = "p"."contact_id"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_crm_opportunities_v2" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_crm_opportunities_v2" IS 'CANONICAL: uma linha por oportunidade CRM.';



CREATE OR REPLACE VIEW "public"."v_crm_sales_v2" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "opportunity_id",
    "contact_id",
    "full_name",
    "phone",
    "email",
    "ganho_at",
    "ganho_date",
    "valor_ganho",
    "forma_ganho",
    "produto_servico",
    "categoria_produto_servico",
    "procedimento_ganho",
    "procedure_closed",
    "opportunity_link_type",
    "lead_event_at",
    "contact_lead_at",
    "contact_lead_date",
    "has_contact_lead_journey",
    "is_acquisition_sale",
    "is_cohort_linkable",
    "has_informed_value",
    "has_valid_value",
    "revenue_quality",
    "attribution_platform",
    "lead_origem",
    "lead_entrada",
    "meta_ad_id",
    "google_campaign_id",
    "google_adgroup_id",
    "google_ad_id",
    "gclid",
    "gbraid",
    "wbraid",
    "latest_pipeline_stage_raw",
    "latest_status_raw",
    "source_event_types"
   FROM ( SELECT "o"."client_id",
            "o"."client_name",
            "o"."client_slug",
            "o"."opportunity_id",
            "o"."contact_id",
            "o"."full_name",
            "o"."phone",
            "o"."email",
            "o"."ganho_at",
            (("o"."ganho_at" AT TIME ZONE COALESCE(NULLIF("cb"."timezone", ''::"text"), 'America/Sao_Paulo'::"text")))::"date" AS "ganho_date",
            "o"."valor_ganho",
            "o"."forma_ganho",
            "o"."produto_servico",
            "o"."categoria_produto_servico",
            "o"."procedimento_ganho",
            "o"."procedure_closed",
                CASE
                    WHEN ("o"."lead_event_at" IS NOT NULL) THEN 'lead_na_mesma_oportunidade'::"text"
                    WHEN "o"."has_contact_lead_journey" THEN 'sem_lead_proprio_com_jornada_do_contato'::"text"
                    ELSE 'sem_jornada_de_lead'::"text"
                END AS "opportunity_link_type",
            "o"."lead_event_at",
            "o"."contact_lead_at",
            "o"."contact_lead_date",
            "o"."has_contact_lead_journey",
            ("o"."lead_event_at" IS NOT NULL) AS "is_acquisition_sale",
            "o"."has_contact_lead_journey" AS "is_cohort_linkable",
            ("o"."valor_ganho" IS NOT NULL) AS "has_informed_value",
            (("o"."valor_ganho" IS NOT NULL) AND ("o"."valor_ganho" > (0)::numeric)) AS "has_valid_value",
                CASE
                    WHEN ("o"."valor_ganho" IS NULL) THEN 'valor_ausente'::"text"
                    WHEN ("o"."valor_ganho" <= (0)::numeric) THEN 'valor_nao_positivo'::"text"
                    ELSE 'valor_valido'::"text"
                END AS "revenue_quality",
            "o"."attribution_platform",
            "o"."lead_origem",
            "o"."lead_entrada",
            "o"."meta_ad_id",
            "o"."google_campaign_id",
            "o"."google_adgroup_id",
            "o"."google_ad_id",
            "o"."gclid",
            "o"."gbraid",
            "o"."wbraid",
            "o"."latest_pipeline_stage_raw",
            "o"."latest_status_raw",
            "o"."source_event_types"
           FROM ("public"."v_crm_opportunities_v2" "o"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "o"."client_id")))
          WHERE "o"."is_won") "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_crm_sales_v2" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_crm_sales_v2" IS 'CANONICAL: uma linha por oportunidade ganha oficial.';



CREATE OR REPLACE VIEW "public"."v_crm_sales_daily_v2" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "date",
    "sales",
    "buying_contacts",
    "acquisition_sales",
    "sales_without_own_lead_but_known_contact",
    "sales_without_lead_journey",
    "sales_with_valid_value",
    "sales_without_valid_value",
    "confirmed_revenue",
    "revenue_is_complete",
    "average_ticket_with_valid_value"
   FROM ( SELECT "s"."client_id",
            "s"."client_name",
            "s"."client_slug",
            "s"."ganho_date" AS "date",
            "count"(*) AS "sales",
            "count"(DISTINCT "s"."contact_id") FILTER (WHERE ("s"."contact_id" IS NOT NULL)) AS "buying_contacts",
            "count"(*) FILTER (WHERE "s"."is_acquisition_sale") AS "acquisition_sales",
            "count"(*) FILTER (WHERE ((NOT "s"."is_acquisition_sale") AND "s"."is_cohort_linkable")) AS "sales_without_own_lead_but_known_contact",
            "count"(*) FILTER (WHERE (NOT "s"."is_cohort_linkable")) AS "sales_without_lead_journey",
            "count"(*) FILTER (WHERE "s"."has_valid_value") AS "sales_with_valid_value",
            "count"(*) FILTER (WHERE (NOT "s"."has_valid_value")) AS "sales_without_valid_value",
            "sum"("s"."valor_ganho") FILTER (WHERE "s"."has_valid_value") AS "confirmed_revenue",
            "bool_and"("s"."has_valid_value") AS "revenue_is_complete",
            "avg"("s"."valor_ganho") FILTER (WHERE "s"."has_valid_value") AS "average_ticket_with_valid_value"
           FROM "public"."v_crm_sales_v2" "s"
          GROUP BY "s"."client_id", "s"."client_name", "s"."client_slug", "s"."ganho_date") "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_crm_sales_daily_v2" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_google_ads_v2" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "id",
    "client_id",
    "client_name",
    "client_slug",
    "date",
    "customer_id",
    "customer_name",
    "campaign_id",
    "campaign_name",
    "campaign_status",
    "ad_group_id",
    "ad_group_name",
    "ad_group_status",
    "ad_id",
    "ad_name",
    "ad_type",
    "ad_status",
    "impressions",
    "clicks",
    "cost_micros",
    "cost",
    "ctr",
    "average_cpc_micros",
    "average_cpc",
    "conversions",
    "conversions_value",
    "all_conversions",
    "all_conversions_value",
    "created_at",
    "updated_at"
   FROM ( SELECT "g"."id",
            "g"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "g"."date",
            "g"."customer_id",
            "g"."customer_name",
            "g"."campaign_id",
            "g"."campaign_name",
            "g"."campaign_status",
            NULL::"text" AS "ad_group_id",
            NULL::"text" AS "ad_group_name",
            NULL::"text" AS "ad_group_status",
            NULL::"text" AS "ad_id",
            NULL::"text" AS "ad_name",
            NULL::"text" AS "ad_type",
            NULL::"text" AS "ad_status",
            ("g"."impressions")::integer AS "impressions",
            ("g"."clicks")::integer AS "clicks",
            "g"."cost_micros",
            "g"."cost",
            "g"."ctr",
            "g"."average_cpc_micros",
            "g"."average_cpc",
            "g"."conversions",
            "g"."conversions_value",
            "g"."all_conversions",
            "g"."all_conversions_value",
            "g"."created_at",
            "g"."updated_at"
           FROM ("public"."google_ads_campaign_daily" "g"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "g"."client_id")))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_google_ads_v2" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_google_ads_v2" IS 'Fonte Google Ads V2 de compatibilidade, agora baseada exclusivamente em google_ads_campaign_daily. Grão oficial: client_id + date + customer_id + campaign_id. Colunas de grupo e anúncio permanecem no contrato, mas retornam NULL. Não combina nem soma dados da tabela legada google_ads_daily.';



CREATE OR REPLACE VIEW "public"."v_client_performance_daily_v2" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "date",
    "platform_rows",
    "platforms_with_delivery",
    "media_source_rows",
    "reported_spend",
    "spend_is_complete",
    "reported_impressions",
    "impressions_are_complete",
    "reported_clicks",
    "clicks_are_complete",
    "latest_source_update_at",
    "cohort_leads",
    "cohort_primeiras_conversas",
    "cohort_agendados",
    "cohort_meta_ads_leads",
    "cohort_google_ads_leads",
    "cohort_paid_attributed_leads",
    "cohort_unattributed_leads",
    "cohort_attribution_conflicts",
    "acquisition_open_opportunities",
    "acquisition_open_contacts",
    "acquisition_won_opportunities",
    "acquisition_won_contacts",
    "acquisition_lost_opportunities",
    "acquisition_lost_contacts",
    "acquisition_status_conflicts",
    "cohort_total_sales",
    "cohort_buying_contacts",
    "cohort_acquisition_sales",
    "cohort_acquisition_buying_contacts",
    "cohort_sales_without_own_lead",
    "cohort_sales_with_valid_value",
    "cohort_sales_without_valid_value",
    "cohort_confirmed_revenue",
    "cohort_confirmed_acquisition_revenue",
    "cohort_confirmed_revenue_without_own_lead",
    "cohort_revenue_is_complete",
    "cohort_acquisition_revenue_is_complete",
    "closed_sales",
    "closed_buying_contacts",
    "closed_acquisition_sales",
    "closed_sales_without_own_lead",
    "closed_sales_without_lead_journey",
    "closed_sales_with_valid_value",
    "closed_sales_without_valid_value",
    "closed_confirmed_revenue",
    "closed_revenue_is_complete",
    "closed_average_ticket_with_valid_value"
   FROM ( WITH "platform_daily" AS (
                 SELECT "m_1"."client_id",
                    "m_1"."date",
                    'meta_ads'::"text" AS "platform",
                    "count"(*) AS "source_rows",
                    "sum"("m_1"."spend") FILTER (WHERE ("m_1"."spend" IS NOT NULL)) AS "reported_spend",
                    "bool_and"(("m_1"."spend" IS NOT NULL)) AS "spend_is_complete",
                    "sum"("m_1"."impressions") FILTER (WHERE ("m_1"."impressions" IS NOT NULL)) AS "reported_impressions",
                    "bool_and"(("m_1"."impressions" IS NOT NULL)) AS "impressions_are_complete",
                    "sum"("m_1"."clicks") FILTER (WHERE ("m_1"."clicks" IS NOT NULL)) AS "reported_clicks",
                    "bool_and"(("m_1"."clicks" IS NOT NULL)) AS "clicks_are_complete",
                    "max"("m_1"."updated_at") AS "latest_source_update_at"
                   FROM "public"."v_meta_ads_v2" "m_1"
                  GROUP BY "m_1"."client_id", "m_1"."date"
                UNION ALL
                 SELECT "g"."client_id",
                    "g"."date",
                    'google_ads'::"text" AS "platform",
                    "count"(*) AS "source_rows",
                    "sum"("g"."cost") FILTER (WHERE ("g"."cost" IS NOT NULL)) AS "reported_spend",
                    "bool_and"(("g"."cost" IS NOT NULL)) AS "spend_is_complete",
                    "sum"("g"."impressions") FILTER (WHERE ("g"."impressions" IS NOT NULL)) AS "reported_impressions",
                    "bool_and"(("g"."impressions" IS NOT NULL)) AS "impressions_are_complete",
                    "sum"("g"."clicks") FILTER (WHERE ("g"."clicks" IS NOT NULL)) AS "reported_clicks",
                    "bool_and"(("g"."clicks" IS NOT NULL)) AS "clicks_are_complete",
                    "max"("g"."updated_at") AS "latest_source_update_at"
                   FROM "public"."v_google_ads_v2" "g"
                  GROUP BY "g"."client_id", "g"."date"
                ), "media" AS (
                 SELECT "p"."client_id",
                    "p"."date",
                    "count"(*) AS "platform_rows",
                    "array_agg"("p"."platform" ORDER BY "p"."platform") AS "platforms_with_delivery",
                    "sum"("p"."source_rows") AS "source_rows",
                    "sum"("p"."reported_spend") FILTER (WHERE ("p"."reported_spend" IS NOT NULL)) AS "reported_spend",
                    "bool_and"("p"."spend_is_complete") AS "spend_is_complete",
                    "sum"("p"."reported_impressions") FILTER (WHERE ("p"."reported_impressions" IS NOT NULL)) AS "reported_impressions",
                    "bool_and"("p"."impressions_are_complete") AS "impressions_are_complete",
                    "sum"("p"."reported_clicks") FILTER (WHERE ("p"."reported_clicks" IS NOT NULL)) AS "reported_clicks",
                    "bool_and"("p"."clicks_are_complete") AS "clicks_are_complete",
                    "max"("p"."latest_source_update_at") AS "latest_source_update_at"
                   FROM "platform_daily" "p"
                  GROUP BY "p"."client_id", "p"."date"
                ), "lead_cohort" AS (
                 SELECT "l"."client_id",
                    "l"."lead_date" AS "date",
                    "count"(*) AS "cohort_leads",
                    "count"(*) FILTER (WHERE "l"."has_primeira_conversa") AS "cohort_primeiras_conversas",
                    "count"(*) FILTER (WHERE "l"."has_agendado") AS "cohort_agendados",
                    "count"(*) FILTER (WHERE ("l"."attribution_platform" = 'Meta Ads'::"text")) AS "cohort_meta_ads_leads",
                    "count"(*) FILTER (WHERE ("l"."attribution_platform" = 'Google Ads'::"text")) AS "cohort_google_ads_leads",
                    "count"(*) FILTER (WHERE ("l"."attribution_platform" = 'Não atribuído'::"text")) AS "cohort_unattributed_leads",
                    "count"(*) FILTER (WHERE ("l"."attribution_platform" = 'Conflito de atribuição'::"text")) AS "cohort_attribution_conflicts"
                   FROM "public"."v_client_leads_by_stage_v2" "l"
                  GROUP BY "l"."client_id", "l"."lead_date"
                ), "acquisition_outcomes" AS (
                 SELECT "o"."client_id",
                    "o"."contact_lead_date" AS "date",
                    "count"(*) FILTER (WHERE ("o"."opportunity_status" = 'aberta'::"text")) AS "acquisition_open_opportunities",
                    "count"(DISTINCT "o"."contact_id") FILTER (WHERE (("o"."opportunity_status" = 'aberta'::"text") AND ("o"."contact_id" IS NOT NULL))) AS "acquisition_open_contacts",
                    "count"(*) FILTER (WHERE ("o"."opportunity_status" = 'ganha'::"text")) AS "acquisition_won_opportunities",
                    "count"(DISTINCT "o"."contact_id") FILTER (WHERE (("o"."opportunity_status" = 'ganha'::"text") AND ("o"."contact_id" IS NOT NULL))) AS "acquisition_won_contacts",
                    "count"(*) FILTER (WHERE ("o"."opportunity_status" = 'perdida'::"text")) AS "acquisition_lost_opportunities",
                    "count"(DISTINCT "o"."contact_id") FILTER (WHERE (("o"."opportunity_status" = 'perdida'::"text") AND ("o"."contact_id" IS NOT NULL))) AS "acquisition_lost_contacts",
                    "count"(*) FILTER (WHERE ("o"."opportunity_status" = 'conflito'::"text")) AS "acquisition_status_conflicts"
                   FROM "public"."v_crm_opportunities_v2" "o"
                  WHERE (("o"."lead_event_at" IS NOT NULL) AND ("o"."contact_lead_date" IS NOT NULL))
                  GROUP BY "o"."client_id", "o"."contact_lead_date"
                ), "cohort_sales" AS (
                 SELECT "s"."client_id",
                    "s"."contact_lead_date" AS "date",
                    "count"(*) AS "cohort_total_sales",
                    "count"(DISTINCT "s"."contact_id") FILTER (WHERE ("s"."contact_id" IS NOT NULL)) AS "cohort_buying_contacts",
                    "count"(*) FILTER (WHERE "s"."is_acquisition_sale") AS "cohort_acquisition_sales",
                    "count"(DISTINCT "s"."contact_id") FILTER (WHERE ("s"."is_acquisition_sale" AND ("s"."contact_id" IS NOT NULL))) AS "cohort_acquisition_buying_contacts",
                    "count"(*) FILTER (WHERE (NOT "s"."is_acquisition_sale")) AS "cohort_sales_without_own_lead",
                    "count"(*) FILTER (WHERE "s"."has_valid_value") AS "cohort_sales_with_valid_value",
                    "count"(*) FILTER (WHERE (NOT "s"."has_valid_value")) AS "cohort_sales_without_valid_value",
                    "sum"("s"."valor_ganho") FILTER (WHERE "s"."has_valid_value") AS "cohort_confirmed_revenue",
                    "sum"("s"."valor_ganho") FILTER (WHERE ("s"."has_valid_value" AND "s"."is_acquisition_sale")) AS "cohort_confirmed_acquisition_revenue",
                    "sum"("s"."valor_ganho") FILTER (WHERE ("s"."has_valid_value" AND (NOT "s"."is_acquisition_sale"))) AS "cohort_confirmed_revenue_without_own_lead",
                    "bool_and"("s"."has_valid_value") AS "cohort_revenue_is_complete",
                    "bool_and"("s"."has_valid_value") FILTER (WHERE "s"."is_acquisition_sale") AS "cohort_acquisition_revenue_is_complete"
                   FROM "public"."v_crm_sales_v2" "s"
                  WHERE ("s"."is_cohort_linkable" AND ("s"."contact_lead_date" IS NOT NULL))
                  GROUP BY "s"."client_id", "s"."contact_lead_date"
                ), "sales_activity" AS (
                 SELECT "s"."client_id",
                    "s"."date",
                    "s"."sales" AS "closed_sales",
                    "s"."buying_contacts" AS "closed_buying_contacts",
                    "s"."acquisition_sales" AS "closed_acquisition_sales",
                    "s"."sales_without_own_lead_but_known_contact" AS "closed_sales_without_own_lead",
                    "s"."sales_without_lead_journey" AS "closed_sales_without_lead_journey",
                    "s"."sales_with_valid_value" AS "closed_sales_with_valid_value",
                    "s"."sales_without_valid_value" AS "closed_sales_without_valid_value",
                    "s"."confirmed_revenue" AS "closed_confirmed_revenue",
                    "s"."revenue_is_complete" AS "closed_revenue_is_complete",
                    "s"."average_ticket_with_valid_value" AS "closed_average_ticket_with_valid_value"
                   FROM "public"."v_crm_sales_daily_v2" "s"
                ), "date_spine" AS (
                 SELECT "media"."client_id",
                    "media"."date"
                   FROM "media"
                UNION
                 SELECT "lead_cohort"."client_id",
                    "lead_cohort"."date"
                   FROM "lead_cohort"
                UNION
                 SELECT "acquisition_outcomes"."client_id",
                    "acquisition_outcomes"."date"
                   FROM "acquisition_outcomes"
                UNION
                 SELECT "cohort_sales"."client_id",
                    "cohort_sales"."date"
                   FROM "cohort_sales"
                UNION
                 SELECT "sales_activity"."client_id",
                    "sales_activity"."date"
                   FROM "sales_activity"
                )
         SELECT "ds"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "ds"."date",
            "m"."platform_rows",
            "m"."platforms_with_delivery",
            "m"."source_rows" AS "media_source_rows",
            "m"."reported_spend",
            "m"."spend_is_complete",
            "m"."reported_impressions",
            "m"."impressions_are_complete",
            "m"."reported_clicks",
            "m"."clicks_are_complete",
            "m"."latest_source_update_at",
            COALESCE("lc"."cohort_leads", (0)::bigint) AS "cohort_leads",
            COALESCE("lc"."cohort_primeiras_conversas", (0)::bigint) AS "cohort_primeiras_conversas",
            COALESCE("lc"."cohort_agendados", (0)::bigint) AS "cohort_agendados",
            COALESCE("lc"."cohort_meta_ads_leads", (0)::bigint) AS "cohort_meta_ads_leads",
            COALESCE("lc"."cohort_google_ads_leads", (0)::bigint) AS "cohort_google_ads_leads",
            (COALESCE("lc"."cohort_meta_ads_leads", (0)::bigint) + COALESCE("lc"."cohort_google_ads_leads", (0)::bigint)) AS "cohort_paid_attributed_leads",
            COALESCE("lc"."cohort_unattributed_leads", (0)::bigint) AS "cohort_unattributed_leads",
            COALESCE("lc"."cohort_attribution_conflicts", (0)::bigint) AS "cohort_attribution_conflicts",
            COALESCE("ao"."acquisition_open_opportunities", (0)::bigint) AS "acquisition_open_opportunities",
            COALESCE("ao"."acquisition_open_contacts", (0)::bigint) AS "acquisition_open_contacts",
            COALESCE("ao"."acquisition_won_opportunities", (0)::bigint) AS "acquisition_won_opportunities",
            COALESCE("ao"."acquisition_won_contacts", (0)::bigint) AS "acquisition_won_contacts",
            COALESCE("ao"."acquisition_lost_opportunities", (0)::bigint) AS "acquisition_lost_opportunities",
            COALESCE("ao"."acquisition_lost_contacts", (0)::bigint) AS "acquisition_lost_contacts",
            COALESCE("ao"."acquisition_status_conflicts", (0)::bigint) AS "acquisition_status_conflicts",
            COALESCE("cs"."cohort_total_sales", (0)::bigint) AS "cohort_total_sales",
            COALESCE("cs"."cohort_buying_contacts", (0)::bigint) AS "cohort_buying_contacts",
            COALESCE("cs"."cohort_acquisition_sales", (0)::bigint) AS "cohort_acquisition_sales",
            COALESCE("cs"."cohort_acquisition_buying_contacts", (0)::bigint) AS "cohort_acquisition_buying_contacts",
            COALESCE("cs"."cohort_sales_without_own_lead", (0)::bigint) AS "cohort_sales_without_own_lead",
            COALESCE("cs"."cohort_sales_with_valid_value", (0)::bigint) AS "cohort_sales_with_valid_value",
            COALESCE("cs"."cohort_sales_without_valid_value", (0)::bigint) AS "cohort_sales_without_valid_value",
            "cs"."cohort_confirmed_revenue",
            "cs"."cohort_confirmed_acquisition_revenue",
            "cs"."cohort_confirmed_revenue_without_own_lead",
            "cs"."cohort_revenue_is_complete",
            "cs"."cohort_acquisition_revenue_is_complete",
            COALESCE("sa"."closed_sales", (0)::bigint) AS "closed_sales",
            COALESCE("sa"."closed_buying_contacts", (0)::bigint) AS "closed_buying_contacts",
            COALESCE("sa"."closed_acquisition_sales", (0)::bigint) AS "closed_acquisition_sales",
            COALESCE("sa"."closed_sales_without_own_lead", (0)::bigint) AS "closed_sales_without_own_lead",
            COALESCE("sa"."closed_sales_without_lead_journey", (0)::bigint) AS "closed_sales_without_lead_journey",
            COALESCE("sa"."closed_sales_with_valid_value", (0)::bigint) AS "closed_sales_with_valid_value",
            COALESCE("sa"."closed_sales_without_valid_value", (0)::bigint) AS "closed_sales_without_valid_value",
            "sa"."closed_confirmed_revenue",
            "sa"."closed_revenue_is_complete",
            "sa"."closed_average_ticket_with_valid_value"
           FROM (((((("date_spine" "ds"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "ds"."client_id")))
             LEFT JOIN "media" "m" ON ((("m"."client_id" = "ds"."client_id") AND ("m"."date" = "ds"."date"))))
             LEFT JOIN "lead_cohort" "lc" ON ((("lc"."client_id" = "ds"."client_id") AND ("lc"."date" = "ds"."date"))))
             LEFT JOIN "acquisition_outcomes" "ao" ON ((("ao"."client_id" = "ds"."client_id") AND ("ao"."date" = "ds"."date"))))
             LEFT JOIN "cohort_sales" "cs" ON ((("cs"."client_id" = "ds"."client_id") AND ("cs"."date" = "ds"."date"))))
             LEFT JOIN "sales_activity" "sa" ON ((("sa"."client_id" = "ds"."client_id") AND ("sa"."date" = "ds"."date"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_client_performance_daily_v2" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_client_performance_daily_v2" IS 'Visão executiva diária V2 de mídia, coorte CRM, oportunidades e vendas. A parcela Google Ads é obtida por v_google_ads_v2, cuja fonte oficial é google_ads_campaign_daily no grão campanha. Não soma a tabela legada google_ads_daily.';



CREATE OR REPLACE VIEW "public"."v_client_profile_safe" WITH ("security_invoker"='true') AS
 SELECT "id" AS "client_id",
    "client_name",
    "client_slug",
    "status",
    "timezone",
    "currency",
    "tracking_status",
    "tracking_ready",
    "meta_ready",
    "google_ads_ready",
    "meta_ads_sync_ready",
    "google_ads_sync_ready",
    "sync_ready",
    "meta_ads_last_sync_at",
    "google_ads_last_sync_at",
    "meta_ads_last_backfill_at",
    "google_ads_last_backfill_at",
    "created_at",
    "updated_at"
   FROM "public"."clients_base" "cb";


ALTER VIEW "public"."v_client_profile_safe" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_client_recent_events" WITH ("security_invoker"='true') AS
 SELECT "client_id",
    "id" AS "event_id",
    "event_datetime",
    "event_code",
    "full_name",
    "phone",
    "lead_entrada",
    COALESCE("public"."normalize_channel_source"("lead_origem", "lead_entrada", "source_id", "google_campaign_id", "gclid", "gbraid", "wbraid"), 'Não Identificado'::"text") AS "channel_source",
    "pipeline_stage",
    "opportunity_id"
   FROM "public"."events_normalized" "en"
  WHERE ("event_datetime" IS NOT NULL);


ALTER VIEW "public"."v_client_recent_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."workflow_execution_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workflow_key" "text" NOT NULL,
    "workflow_name" "text" NOT NULL,
    "workflow_category" "text" NOT NULL,
    "n8n_execution_id" "text",
    "client_id" "uuid",
    "client_slug" "text",
    "client_name" "text",
    "ghl_location_id" "text",
    "status" "text" DEFAULT 'running'::"text" NOT NULL,
    "stage" "text",
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    "duration_ms" integer,
    "items_processed" integer DEFAULT 0,
    "items_failed" integer DEFAULT 0,
    "error_message" "text",
    "error_node" "text",
    "stages" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "workflow_execution_logs_status_check" CHECK (("status" = ANY (ARRAY['running'::"text", 'success'::"text", 'partial'::"text", 'error'::"text", 'skipped'::"text", 'aborted_legacy'::"text"]))),
    CONSTRAINT "workflow_execution_logs_workflow_category_check" CHECK (("workflow_category" = ANY (ARRAY['onboarding'::"text", 'events'::"text", 'dispatch'::"text", 'media_sync'::"text", 'backfill'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."workflow_execution_logs" OWNER TO "postgres";


COMMENT ON TABLE "public"."workflow_execution_logs" IS 'Log de execução (resumo + etapas-chave) de todos os workflows n8n do ImpulsHub. Camada técnica interna, não client-facing direta — expor via view v_client_workflow_health.';



CREATE OR REPLACE VIEW "public"."v_client_workflow_health" WITH ("security_invoker"='true') AS
 SELECT "client_id",
    "workflow_key",
    "workflow_name",
    "workflow_category",
    "status",
    "stage",
    "started_at",
    "finished_at",
    "duration_ms",
    "items_processed",
    "items_failed"
   FROM "public"."workflow_execution_logs" "l"
  WHERE ("client_id" IS NOT NULL);


ALTER VIEW "public"."v_client_workflow_health" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_client_workflow_health" IS 'Saúde de execução por cliente, sem error_message/error_node (detalhe técnico fica interno). RLS herdada de clients_base via security_invoker + private.user_can_access_client().';



CREATE OR REPLACE VIEW "public"."v_crm_activities_v1" WITH ("security_invoker"='true') AS
 SELECT "tenant_id" AS "client_id",
    "contact_id",
    "opportunity_id",
    "id" AS "activity_id",
    "created_at",
    "kind",
    "direction",
    "body",
    "provider_message_id"
   FROM "crm"."activities" "a";


ALTER VIEW "public"."v_crm_activities_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_board_counts_v1" WITH ("security_invoker"='true') AS
 SELECT "t"."id" AS "client_id",
    "s"."code" AS "stage_code",
    "s"."label" AS "stage_label",
    "s"."position" AS "stage_position",
    "s"."is_terminal",
    "count"("o"."id") AS "opportunities"
   FROM ((("crm"."tenants" "t"
     CROSS JOIN "crm"."global_pipeline_stages" "s")
     JOIN "crm"."global_pipeline_versions" "v" ON ((("v"."id" = "s"."pipeline_version_id") AND ("v"."status" = 'active'::"text"))))
     LEFT JOIN "crm"."opportunities" "o" ON ((("o"."tenant_id" = "t"."id") AND ("o"."current_stage_id" = "s"."id"))))
  GROUP BY "t"."id", "s"."code", "s"."label", "s"."position", "s"."is_terminal";


ALTER VIEW "public"."v_crm_board_counts_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_card_history_v1" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "opportunity_id",
    "occurred_at",
    "event_kind",
    "transition_type",
    "origin",
    "from_stage_code",
    "from_stage_label",
    "to_stage_code",
    "to_stage_label",
    "milestone_kind",
    "outcome",
    "loss_reason_code",
    "loss_reason_label",
    "value",
    "value_status",
    "currency",
    "evidence",
    "reason",
    "actor_profile_id",
    "actor_name"
   FROM ( SELECT "h"."tenant_id" AS "client_id",
            "h"."opportunity_id",
            "h"."occurred_at",
            'stage'::"text" AS "event_kind",
            "h"."transition_type",
            "h"."origin",
            "fs"."code" AS "from_stage_code",
            "fs"."label" AS "from_stage_label",
            "ts"."code" AS "to_stage_code",
            "ts"."label" AS "to_stage_label",
            NULL::"text" AS "milestone_kind",
            NULL::"text" AS "outcome",
            NULL::"text" AS "loss_reason_code",
            NULL::"text" AS "loss_reason_label",
            NULL::numeric AS "value",
            NULL::"text" AS "value_status",
            NULL::"text" AS "currency",
            NULL::"text" AS "evidence",
            "h"."reason",
            "h"."actor_profile_id",
            "ap"."display_name" AS "actor_name"
           FROM ((("crm"."opportunity_stage_history" "h"
             LEFT JOIN "crm"."global_pipeline_stages" "fs" ON (("fs"."id" = "h"."from_stage_id")))
             JOIN "crm"."global_pipeline_stages" "ts" ON (("ts"."id" = "h"."to_stage_id")))
             LEFT JOIN "crm"."profiles" "ap" ON (("ap"."id" = "h"."actor_profile_id")))
        UNION ALL
         SELECT "m"."tenant_id" AS "client_id",
            "m"."opportunity_id",
            "m"."occurred_at",
            'milestone'::"text" AS "event_kind",
            NULL::"text" AS "transition_type",
            "m"."origin",
            NULL::"text" AS "from_stage_code",
            NULL::"text" AS "from_stage_label",
            NULL::"text" AS "to_stage_code",
            NULL::"text" AS "to_stage_label",
            "m"."kind" AS "milestone_kind",
            NULL::"text" AS "outcome",
            NULL::"text" AS "loss_reason_code",
            NULL::"text" AS "loss_reason_label",
            NULL::numeric AS "value",
            NULL::"text" AS "value_status",
            NULL::"text" AS "currency",
                CASE
                    WHEN (("m"."kind" = 'revenue'::"text") AND (NOT ("m"."tenant_id" IN ( SELECT "financial_client_ids"."client_id"
                       FROM "private"."financial_client_ids"() "financial_client_ids"("client_id"))))) THEN NULL::"text"
                    ELSE "m"."evidence"
                END AS "evidence",
            NULL::"text" AS "reason",
            "m"."actor_profile_id",
            "ap"."display_name" AS "actor_name"
           FROM ("crm"."opportunity_milestones" "m"
             LEFT JOIN "crm"."profiles" "ap" ON (("ap"."id" = "m"."actor_profile_id")))
        UNION ALL
         SELECT "co"."tenant_id" AS "client_id",
            "co"."opportunity_id",
            "co"."occurred_at",
            'outcome'::"text" AS "event_kind",
            NULL::"text" AS "transition_type",
            "co"."origin",
            NULL::"text" AS "from_stage_code",
            NULL::"text" AS "from_stage_label",
            NULL::"text" AS "to_stage_code",
            NULL::"text" AS "to_stage_label",
            NULL::"text" AS "milestone_kind",
            "co"."outcome",
            "lr"."code" AS "loss_reason_code",
            "lr"."label" AS "loss_reason_label",
                CASE
                    WHEN ("co"."tenant_id" IN ( SELECT "financial_client_ids"."client_id"
                       FROM "private"."financial_client_ids"() "financial_client_ids"("client_id"))) THEN "co"."value"
                    ELSE NULL::numeric
                END AS "value",
                CASE
                    WHEN ("co"."tenant_id" IN ( SELECT "financial_client_ids"."client_id"
                       FROM "private"."financial_client_ids"() "financial_client_ids"("client_id"))) THEN "co"."value_status"
                    ELSE NULL::"text"
                END AS "value_status",
                CASE
                    WHEN ("co"."tenant_id" IN ( SELECT "financial_client_ids"."client_id"
                       FROM "private"."financial_client_ids"() "financial_client_ids"("client_id"))) THEN "co"."currency"
                    ELSE NULL::"text"
                END AS "currency",
            "co"."evidence",
            NULL::"text" AS "reason",
            "co"."actor_profile_id",
            "ap"."display_name" AS "actor_name"
           FROM (("crm"."commercial_outcomes" "co"
             LEFT JOIN "crm"."canonical_loss_reasons" "lr" ON (("lr"."id" = "co"."loss_reason_id")))
             LEFT JOIN "crm"."profiles" "ap" ON (("ap"."id" = "co"."actor_profile_id")))) "gated"
  WHERE ("client_id" IN ( SELECT "m"."m"
           FROM "private"."my_client_ids"() "m"("m")));


ALTER VIEW "public"."v_crm_card_history_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_channels_daily_v2" WITH ("security_invoker"='true') AS
 WITH "base" AS (
         SELECT "l"."client_id",
            "l"."client_name",
            "l"."client_slug",
            "l"."lead_date",
            "l"."attribution_platform",
            COALESCE(NULLIF(TRIM(BOTH FROM "l"."lead_origem"), ''::"text"), 'Não informado'::"text") AS "lead_origem",
            COALESCE(NULLIF(TRIM(BOTH FROM "l"."lead_entrada"), ''::"text"), 'Não informado'::"text") AS "lead_entrada",
            "l"."has_primeira_conversa",
            "l"."has_agendado",
            "l"."has_ganho",
            "l"."has_perdido"
           FROM "public"."v_client_leads_by_stage_v2" "l"
        ), "dimensoes" AS (
         SELECT "base"."client_id",
            "base"."client_name",
            "base"."client_slug",
            "base"."lead_date",
            'plataforma_atribuida'::"text" AS "dimension_type",
            "base"."attribution_platform" AS "dimension_value",
            "base"."has_primeira_conversa",
            "base"."has_agendado",
            "base"."has_ganho",
            "base"."has_perdido"
           FROM "base"
        UNION ALL
         SELECT "base"."client_id",
            "base"."client_name",
            "base"."client_slug",
            "base"."lead_date",
            'origem_informada'::"text" AS "dimension_type",
            "base"."lead_origem" AS "dimension_value",
            "base"."has_primeira_conversa",
            "base"."has_agendado",
            "base"."has_ganho",
            "base"."has_perdido"
           FROM "base"
        UNION ALL
         SELECT "base"."client_id",
            "base"."client_name",
            "base"."client_slug",
            "base"."lead_date",
            'entrada_informada'::"text" AS "dimension_type",
            "base"."lead_entrada" AS "dimension_value",
            "base"."has_primeira_conversa",
            "base"."has_agendado",
            "base"."has_ganho",
            "base"."has_perdido"
           FROM "base"
        )
 SELECT "client_id",
    "client_name",
    "client_slug",
    "lead_date" AS "date",
    "dimension_type",
    "dimension_value",
    "count"(*) AS "crm_leads",
    "count"(*) FILTER (WHERE "has_primeira_conversa") AS "crm_primeiras_conversas",
    "count"(*) FILTER (WHERE "has_agendado") AS "crm_agendados",
    "count"(*) FILTER (WHERE "has_ganho") AS "crm_ganhos",
    "count"(*) FILTER (WHERE "has_perdido") AS "crm_perdidos"
   FROM "dimensoes"
  GROUP BY "client_id", "client_name", "client_slug", "lead_date", "dimension_type", "dimension_value";


ALTER VIEW "public"."v_crm_channels_daily_v2" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_contacts_v1" WITH ("security_invoker"='true') AS
 SELECT "c"."tenant_id" AS "client_id",
    "c"."id" AS "contact_id",
    "c"."full_name",
    "c"."phone_normalized",
    "c"."email",
        CASE
            WHEN ("c"."phone_normalized" IS NOT NULL) THEN ('https://wa.me/'::"text" || "c"."phone_normalized")
            ELSE NULL::"text"
        END AS "whatsapp_url",
    "c"."status",
    "act"."last_activity_at",
    COALESCE("act"."messages_total", (0)::bigint) AS "messages_total",
    "o"."id" AS "opportunity_id",
    "s"."code" AS "stage_code",
    "s"."label" AS "stage_label",
    "s"."position" AS "stage_position",
    "o"."status" AS "opportunity_status",
    "o"."opened_at",
    "o"."crc_owner_profile_id",
    "crc"."display_name" AS "crc_owner_name",
    "o"."sales_owner_profile_id",
    "sales"."display_name" AS "sales_owner_name",
        CASE
            WHEN (("o"."conversion_source" IS NOT NULL) OR ("o"."ctwa_clid" IS NOT NULL) OR ("o"."meta_ad_id" IS NOT NULL)) THEN 'anuncio'::"text"
            ELSE 'organico'::"text"
        END AS "origem",
    (("lower"("c"."full_name") || ' '::"text") || COALESCE("c"."phone_normalized", ''::"text")) AS "search_text"
   FROM ((((("crm"."contacts" "c"
     LEFT JOIN LATERAL ( SELECT "max"("a"."created_at") AS "last_activity_at",
            "count"(*) AS "messages_total"
           FROM "crm"."activities" "a"
          WHERE (("a"."tenant_id" = "c"."tenant_id") AND ("a"."contact_id" = "c"."id"))) "act" ON (true))
     LEFT JOIN LATERAL ( SELECT "o2"."id",
            "o2"."status",
            "o2"."current_stage_id",
            "o2"."opened_at",
            "o2"."crc_owner_profile_id",
            "o2"."sales_owner_profile_id",
            "o2"."conversion_source",
            "o2"."ctwa_clid",
            "o2"."meta_ad_id"
           FROM "crm"."opportunities" "o2"
          WHERE (("o2"."tenant_id" = "c"."tenant_id") AND ("o2"."contact_id" = "c"."id"))
          ORDER BY "o2"."opened_at" DESC, "o2"."created_at" DESC
         LIMIT 1) "o" ON (true))
     LEFT JOIN "crm"."global_pipeline_stages" "s" ON (("s"."id" = "o"."current_stage_id")))
     LEFT JOIN "crm"."profiles" "crc" ON (("crc"."id" = "o"."crc_owner_profile_id")))
     LEFT JOIN "crm"."profiles" "sales" ON (("sales"."id" = "o"."sales_owner_profile_id")));


ALTER VIEW "public"."v_crm_contacts_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_events_feed_v2" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "event_id",
    "raw_event_id",
    "client_id",
    "client_name",
    "client_slug",
    "event_datetime",
    "event_datetime_local",
    "event_date",
    "received_at",
    "event_code",
    "event_name",
    "funnel_step",
    "contact_id",
    "opportunity_id",
    "full_name",
    "first_name",
    "last_name",
    "phone",
    "email",
    "pipeline_id",
    "pipeline_name",
    "pipeline_stage",
    "status",
    "lead_origem",
    "lead_entrada",
    "source_type",
    "source_id",
    "source_url",
    "source_ads",
    "ad_title",
    "utm_source",
    "utm_medium",
    "utm_campaign",
    "utm_content",
    "utm_term",
    "ctwa_clid",
    "fbclid",
    "gclid",
    "gbraid",
    "wbraid",
    "google_campaign_id",
    "google_adgroup_id",
    "google_ad_id",
    "google_keyword",
    "google_network",
    "google_device",
    "valor_ganho",
    "forma_ganho",
    "produto_servico",
    "categoria_produto_servico",
    "procedimento_ganho",
    "procedure_closed",
    "motivo_perda_categoria",
    "motivo_perda_detalhe",
    "source_system",
    "source_event_type",
    "source_workflow_id",
    "source_workflow_name",
    "normalization_status",
    "normalization_error",
    "has_opportunity_id",
    "gain_has_informed_value",
    "gain_has_missing_value"
   FROM ( SELECT "en"."id" AS "event_id",
            "en"."raw_event_id",
            "en"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "en"."event_datetime",
            ("en"."event_datetime" AT TIME ZONE COALESCE(NULLIF("cb"."timezone", ''::"text"), 'America/Sao_Paulo'::"text")) AS "event_datetime_local",
            (("en"."event_datetime" AT TIME ZONE COALESCE(NULLIF("cb"."timezone", ''::"text"), 'America/Sao_Paulo'::"text")))::"date" AS "event_date",
            "en"."received_at",
            "en"."event_code",
            "en"."event_name",
            "en"."funnel_step",
            "en"."contact_id",
            "en"."opportunity_id",
            "en"."full_name",
            "en"."first_name",
            "en"."last_name",
            "en"."phone",
            "en"."email",
            "en"."pipeline_id",
            "en"."pipeline_name",
            "en"."pipeline_stage",
            "en"."status",
            "en"."lead_origem",
            "en"."lead_entrada",
            "en"."source_type",
            "en"."source_id",
            "en"."source_url",
            "en"."source_ads",
            "en"."ad_title",
            "en"."utm_source",
            "en"."utm_medium",
            "en"."utm_campaign",
            "en"."utm_content",
            "en"."utm_term",
            "en"."ctwa_clid",
            "en"."fbclid",
            "en"."gclid",
            "en"."gbraid",
            "en"."wbraid",
            "en"."google_campaign_id",
            "en"."google_adgroup_id",
            "en"."google_ad_id",
            "en"."google_keyword",
            "en"."google_network",
            "en"."google_device",
            "en"."valor_ganho",
            "en"."forma_ganho",
            "en"."produto_servico",
            "en"."categoria_produto_servico",
            "en"."procedimento_ganho",
            "en"."procedure_closed",
            "en"."motivo_perda_categoria",
            "en"."motivo_perda_detalhe",
            "en"."source_system",
            "en"."source_event_type",
            "en"."source_workflow_id",
            "en"."source_workflow_name",
            "en"."normalization_status",
            "en"."normalization_error",
            (NULLIF(TRIM(BOTH FROM "en"."opportunity_id"), ''::"text") IS NOT NULL) AS "has_opportunity_id",
            (("en"."event_code" = 'ganho'::"text") AND ("en"."valor_ganho" IS NOT NULL)) AS "gain_has_informed_value",
            (("en"."event_code" = 'ganho'::"text") AND ("en"."valor_ganho" IS NULL)) AS "gain_has_missing_value"
           FROM ("public"."events_normalized" "en"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "en"."client_id")))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_crm_events_feed_v2" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_crm_events_feed_v2" IS 'CANONICAL: uma linha por evento CRM normalizado.';



CREATE OR REPLACE VIEW "public"."v_crm_events_daily_v2" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "date",
    "event_code",
    "event_name",
    "source_event_type",
    "event_count",
    "distinct_contacts",
    "distinct_opportunities",
    "events_with_opportunity",
    "events_without_opportunity",
    "gain_event_count",
    "gain_events_with_value",
    "gain_events_without_value",
    "first_event_at",
    "last_event_at",
    "latest_received_at"
   FROM ( SELECT "e"."client_id",
            "e"."client_name",
            "e"."client_slug",
            "e"."event_date" AS "date",
            "e"."event_code",
            "e"."event_name",
            "e"."source_event_type",
            "count"(*) AS "event_count",
            "count"(DISTINCT "e"."contact_id") FILTER (WHERE ("e"."contact_id" IS NOT NULL)) AS "distinct_contacts",
            "count"(DISTINCT "e"."opportunity_id") FILTER (WHERE (("e"."opportunity_id" IS NOT NULL) AND (TRIM(BOTH FROM "e"."opportunity_id") <> ''::"text"))) AS "distinct_opportunities",
            "count"(*) FILTER (WHERE "e"."has_opportunity_id") AS "events_with_opportunity",
            "count"(*) FILTER (WHERE (NOT "e"."has_opportunity_id")) AS "events_without_opportunity",
            "count"(*) FILTER (WHERE ("e"."event_code" = 'ganho'::"text")) AS "gain_event_count",
            "count"(*) FILTER (WHERE "e"."gain_has_informed_value") AS "gain_events_with_value",
            "count"(*) FILTER (WHERE "e"."gain_has_missing_value") AS "gain_events_without_value",
            "min"("e"."event_datetime") AS "first_event_at",
            "max"("e"."event_datetime") AS "last_event_at",
            "max"("e"."received_at") AS "latest_received_at"
           FROM "public"."v_crm_events_feed_v2" "e"
          GROUP BY "e"."client_id", "e"."client_name", "e"."client_slug", "e"."event_date", "e"."event_code", "e"."event_name", "e"."source_event_type") "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_crm_events_daily_v2" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_funnel_daily_v2" WITH ("security_invoker"='true') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "lead_date" AS "event_date",
    "attribution_platform",
    "count"(*) AS "crm_leads",
    "count"(*) FILTER (WHERE "has_primeira_conversa") AS "crm_primeiras_conversas",
    "count"(*) FILTER (WHERE "has_agendado") AS "crm_agendados",
    "count"(*) FILTER (WHERE "has_ganho") AS "crm_ganhos",
    "count"(*) FILTER (WHERE "has_perdido") AS "crm_perdidos"
   FROM "public"."v_client_leads_by_stage_v2" "l"
  GROUP BY "client_id", "client_name", "client_slug", "lead_date", "attribution_platform";


ALTER VIEW "public"."v_crm_funnel_daily_v2" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_loss_reasons_v1" WITH ("security_invoker"='true') AS
 SELECT "code",
    "label",
    "requires_note",
    "active"
   FROM "crm"."canonical_loss_reasons";


ALTER VIEW "public"."v_crm_loss_reasons_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_my_role_v1" WITH ("security_invoker"='true') AS
 SELECT "client_id",
    "role",
    ("is_active" AND ("lower"("role") <> 'viewer'::"text")) AS "can_write"
   FROM "public"."client_users" "cu"
  WHERE ("user_id" = "auth"."uid"());


ALTER VIEW "public"."v_crm_my_role_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_opportunities" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "opportunity_id",
    "first_event_at",
    "first_event_date",
    "last_event_at",
    "last_event_date",
    "primeira_conversa_at",
    "primeira_conversa_date",
    "agendado_at",
    "agendado_date",
    "ganho_at",
    "ganho_date",
    "perdido_at",
    "perdido_date",
    "is_won",
    "is_lost",
    "opportunity_status",
    "pipeline_stage_final",
    "latest_event_code",
    "channel_source_raw",
    "lead_entrada",
    "channel_source",
    "meta_ad_id",
    "source_type",
    "source_url",
    "google_campaign_id",
    "google_adgroup_id",
    "google_ad_id",
    "google_keyword",
    "gclid",
    "gbraid",
    "wbraid",
    "valor_ganho_final",
    "forma_ganho",
    "procedimento_ganho",
    "revenue_event_at",
    "eventos_total",
    "eventos_primeira_conversa",
    "eventos_agendado",
    "eventos_ganho",
    "eventos_perdido",
    "eventos_com_valor",
    "has_revenue_duplication_risk"
   FROM ( WITH "base" AS (
                 SELECT "en"."id",
                    "en"."client_id",
                    "cb"."client_name" AS "cb_client_name",
                    "cb"."client_slug" AS "cb_client_slug",
                    "en"."opportunity_id",
                    COALESCE("en"."event_datetime", "en"."received_at") AS "received_at",
                    ((COALESCE("en"."event_datetime", "en"."received_at") AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "event_date",
                    "en"."event_code",
                    "en"."status",
                    "en"."pipeline_stage",
                    "en"."lead_origem",
                    "en"."lead_entrada",
                    "en"."source_id",
                    "en"."source_type",
                    "en"."source_url",
                    "en"."google_campaign_id",
                    "en"."google_adgroup_id",
                    "en"."google_ad_id",
                    "en"."google_keyword",
                    "en"."gclid",
                    "en"."gbraid",
                    "en"."wbraid",
                    "en"."valor_ganho",
                    "en"."forma_ganho",
                    "en"."procedimento_ganho"
                   FROM ("public"."events_normalized" "en"
                     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "en"."client_id")))
                  WHERE ("en"."opportunity_id" IS NOT NULL)
                ), "latest_event" AS (
                 SELECT DISTINCT ON ("b"."client_id", "b"."opportunity_id") "b"."client_id",
                    "b"."opportunity_id",
                    "b"."event_code" AS "latest_event_code",
                    "b"."status" AS "latest_status",
                    "b"."pipeline_stage" AS "latest_pipeline_stage",
                    "b"."received_at" AS "latest_event_at"
                   FROM "base" "b"
                  ORDER BY "b"."client_id", "b"."opportunity_id", "b"."received_at" DESC, "b"."id" DESC
                ), "first_source" AS (
                 SELECT DISTINCT ON ("b"."client_id", "b"."opportunity_id") "b"."client_id",
                    "b"."opportunity_id",
                    "b"."lead_origem",
                    "b"."lead_entrada",
                    "b"."source_id" AS "meta_ad_id",
                    "b"."source_type",
                    "b"."source_url",
                    "b"."google_campaign_id",
                    "b"."google_adgroup_id",
                    "b"."google_ad_id",
                    "b"."google_keyword",
                    "b"."gclid",
                    "b"."gbraid",
                    "b"."wbraid",
                    "b"."received_at" AS "source_event_at"
                   FROM "base" "b"
                  WHERE ((NULLIF("b"."lead_origem", ''::"text") IS NOT NULL) OR (NULLIF("b"."lead_entrada", ''::"text") IS NOT NULL) OR ("b"."source_id" IS NOT NULL) OR ("b"."google_campaign_id" IS NOT NULL) OR ("b"."gclid" IS NOT NULL) OR ("b"."gbraid" IS NOT NULL) OR ("b"."wbraid" IS NOT NULL))
                  ORDER BY "b"."client_id", "b"."opportunity_id", "b"."received_at", "b"."id"
                ), "revenue_event" AS (
                 SELECT DISTINCT ON ("b"."client_id", "b"."opportunity_id") "b"."client_id",
                    "b"."opportunity_id",
                    "b"."valor_ganho" AS "valor_ganho_final",
                    "b"."forma_ganho",
                    "b"."procedimento_ganho",
                    "b"."received_at" AS "revenue_event_at"
                   FROM "base" "b"
                  WHERE (COALESCE("b"."valor_ganho", (0)::numeric) > (0)::numeric)
                  ORDER BY "b"."client_id", "b"."opportunity_id",
                        CASE
                            WHEN (("b"."event_code" = 'ganho'::"text") OR ("b"."status" = 'won'::"text") OR ("b"."pipeline_stage" ~~* '%ganho%'::"text")) THEN 0
                            ELSE 1
                        END, "b"."received_at" DESC, "b"."id" DESC
                ), "agg" AS (
                 SELECT "b"."client_id",
                    "b"."cb_client_name" AS "client_name",
                    "b"."cb_client_slug" AS "client_slug",
                    "b"."opportunity_id",
                    "min"("b"."received_at") AS "first_event_at",
                    "max"("b"."received_at") AS "last_event_at",
                    "min"("b"."received_at") FILTER (WHERE ("b"."event_code" = 'primeira_conversa'::"text")) AS "primeira_conversa_at",
                    "min"("b"."received_at") FILTER (WHERE ("b"."event_code" = 'agendado'::"text")) AS "agendado_at",
                    "min"("b"."received_at") FILTER (WHERE (("b"."event_code" = 'ganho'::"text") OR ("b"."status" = 'won'::"text") OR ("b"."pipeline_stage" ~~* '%ganho%'::"text"))) AS "ganho_at",
                    "min"("b"."received_at") FILTER (WHERE (("b"."event_code" = 'perdido'::"text") OR ("b"."status" = 'lost'::"text") OR ("b"."pipeline_stage" ~~* '%perdido%'::"text"))) AS "perdido_at",
                    "bool_or"((("b"."event_code" = 'ganho'::"text") OR ("b"."status" = 'won'::"text") OR ("b"."pipeline_stage" ~~* '%ganho%'::"text"))) AS "is_won",
                    "bool_or"((("b"."event_code" = 'perdido'::"text") OR ("b"."status" = 'lost'::"text") OR ("b"."pipeline_stage" ~~* '%perdido%'::"text"))) AS "is_lost",
                    "count"(*) AS "eventos_total",
                    "count"(*) FILTER (WHERE ("b"."event_code" = 'primeira_conversa'::"text")) AS "eventos_primeira_conversa",
                    "count"(*) FILTER (WHERE ("b"."event_code" = 'agendado'::"text")) AS "eventos_agendado",
                    "count"(*) FILTER (WHERE ("b"."event_code" = 'ganho'::"text")) AS "eventos_ganho",
                    "count"(*) FILTER (WHERE ("b"."event_code" = 'perdido'::"text")) AS "eventos_perdido",
                    "count"(*) FILTER (WHERE (COALESCE("b"."valor_ganho", (0)::numeric) > (0)::numeric)) AS "eventos_com_valor"
                   FROM "base" "b"
                  GROUP BY "b"."client_id", "b"."cb_client_name", "b"."cb_client_slug", "b"."opportunity_id"
                )
         SELECT "a"."client_id",
            "a"."client_name",
            "a"."client_slug",
            "a"."opportunity_id",
            "a"."first_event_at",
            (("a"."first_event_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "first_event_date",
            "a"."last_event_at",
            (("a"."last_event_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "last_event_date",
            "a"."primeira_conversa_at",
            (("a"."primeira_conversa_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "primeira_conversa_date",
            "a"."agendado_at",
            (("a"."agendado_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "agendado_date",
            "a"."ganho_at",
            (("a"."ganho_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "ganho_date",
            "a"."perdido_at",
            (("a"."perdido_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "perdido_date",
            "a"."is_won",
            "a"."is_lost",
                CASE
                    WHEN "a"."is_won" THEN 'won'::"text"
                    WHEN "a"."is_lost" THEN 'lost'::"text"
                    ELSE COALESCE("le"."latest_status", 'open'::"text")
                END AS "opportunity_status",
            "le"."latest_pipeline_stage" AS "pipeline_stage_final",
            "le"."latest_event_code",
            "fs"."lead_origem" AS "channel_source_raw",
            "fs"."lead_entrada",
            "public"."normalize_channel_source"("fs"."lead_origem", "fs"."lead_entrada", "fs"."meta_ad_id", "fs"."google_campaign_id", "fs"."gclid", "fs"."gbraid", "fs"."wbraid") AS "channel_source",
            "fs"."meta_ad_id",
            "fs"."source_type",
            "fs"."source_url",
            "fs"."google_campaign_id",
            "fs"."google_adgroup_id",
            "fs"."google_ad_id",
            "fs"."google_keyword",
            "fs"."gclid",
            "fs"."gbraid",
            "fs"."wbraid",
            COALESCE("re"."valor_ganho_final", (0)::numeric) AS "valor_ganho_final",
            "re"."forma_ganho",
            "re"."procedimento_ganho",
            "re"."revenue_event_at",
            "a"."eventos_total",
            "a"."eventos_primeira_conversa",
            "a"."eventos_agendado",
            "a"."eventos_ganho",
            "a"."eventos_perdido",
            "a"."eventos_com_valor",
                CASE
                    WHEN (("a"."eventos_ganho" > 1) OR ("a"."eventos_com_valor" > 1)) THEN true
                    ELSE false
                END AS "has_revenue_duplication_risk"
           FROM ((("agg" "a"
             LEFT JOIN "latest_event" "le" ON ((("le"."client_id" = "a"."client_id") AND ("le"."opportunity_id" = "a"."opportunity_id"))))
             LEFT JOIN "first_source" "fs" ON ((("fs"."client_id" = "a"."client_id") AND ("fs"."opportunity_id" = "a"."opportunity_id"))))
             LEFT JOIN "revenue_event" "re" ON ((("re"."client_id" = "a"."client_id") AND ("re"."opportunity_id" = "a"."opportunity_id"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_crm_opportunities" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_crm_owners_v1" WITH ("security_invoker"='true') AS
 SELECT "tm"."tenant_id" AS "client_id",
    "tm"."profile_id",
    "p"."display_name",
    "tm"."role" AS "membership_role",
    COALESCE(("cu"."is_active" AND ("lower"("cu"."role") <> 'viewer'::"text")), false) AS "can_write"
   FROM (("crm"."tenant_memberships" "tm"
     JOIN "crm"."profiles" "p" ON (("p"."id" = "tm"."profile_id")))
     LEFT JOIN "public"."client_users" "cu" ON ((("cu"."client_id" = "tm"."tenant_id") AND ("cu"."user_id" = "tm"."profile_id"))))
  WHERE (("tm"."status" = 'active'::"text") AND "tm"."is_assignable");


ALTER VIEW "public"."v_crm_owners_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_data_quality_v2" WITH ("security_invoker"='true') AS
 WITH "contact_quality" AS (
         SELECT "en"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "en"."contact_id",
            ("array_agg"("en"."full_name" ORDER BY COALESCE("en"."event_datetime", "en"."received_at") DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."full_name" IS NOT NULL)))[1] AS "full_name",
            ("array_agg"("en"."phone" ORDER BY COALESCE("en"."event_datetime", "en"."received_at") DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."phone" IS NOT NULL)))[1] AS "phone",
            "count"(*) AS "total_events",
            "count"(*) FILTER (WHERE ("en"."event_code" = 'lead'::"text")) AS "lead_event_count",
            "count"(*) FILTER (WHERE (("en"."event_code" = 'lead'::"text") AND ("en"."event_datetime" IS NOT NULL))) AS "valid_lead_event_count",
            "count"(*) FILTER (WHERE ("en"."event_datetime" IS NULL)) AS "events_without_datetime",
            "count"(*) FILTER (WHERE ("en"."event_code" = ANY (ARRAY['primeira_conversa'::"text", 'agendado'::"text", 'ganho'::"text", 'perdido'::"text"]))) AS "later_stage_event_count",
            "min"("en"."event_datetime") AS "first_business_event_at",
            "min"("en"."received_at") AS "first_received_at",
            ("array_agg"("en"."event_code" ORDER BY COALESCE("en"."event_datetime", "en"."received_at"), "en"."received_at"))[1] AS "first_observed_event_code",
            "array_agg"(DISTINCT "en"."event_code" ORDER BY "en"."event_code") AS "event_codes"
           FROM ("public"."events_normalized" "en"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "en"."client_id")))
          WHERE ("en"."contact_id" IS NOT NULL)
          GROUP BY "en"."client_id", "cb"."client_name", "cb"."client_slug", "en"."contact_id"
        ), "contact_issues" AS (
         SELECT "cq"."client_id",
            "cq"."client_name",
            "cq"."client_slug",
            'contact'::"text" AS "quality_area",
            "r"."issue_code",
            "r"."severity",
            'contact'::"text" AS "entity_type",
            "cq"."contact_id" AS "entity_id",
            "cq"."contact_id",
            NULL::"text" AS "opportunity_id",
            NULL::"uuid" AS "event_id",
            "cq"."full_name",
            "cq"."phone",
            "r"."issue_at",
            (("r"."issue_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "issue_date",
            "r"."issue_count",
            'events_normalized'::"text" AS "source_relation",
            "r"."details"
           FROM ("contact_quality" "cq"
             CROSS JOIN LATERAL ( VALUES ('CONTACT_STAGE_WITHOUT_LEAD'::"text",'warning'::"text",(("cq"."lead_event_count" = 0) AND ("cq"."later_stage_event_count" > 0)),"cq"."later_stage_event_count",COALESCE("cq"."first_business_event_at", "cq"."first_received_at"),"jsonb_build_object"('total_events', "cq"."total_events", 'lead_event_count', "cq"."lead_event_count", 'later_stage_event_count', "cq"."later_stage_event_count", 'first_observed_event_code', "cq"."first_observed_event_code", 'event_codes', "cq"."event_codes")), ('CONTACT_LEAD_WITHOUT_BUSINESS_DATETIME'::"text",'critical'::"text",(("cq"."lead_event_count" > 0) AND ("cq"."valid_lead_event_count" = 0)),GREATEST(("cq"."lead_event_count" - "cq"."valid_lead_event_count"), (1)::bigint),"cq"."first_received_at","jsonb_build_object"('lead_event_count', "cq"."lead_event_count", 'valid_lead_event_count', "cq"."valid_lead_event_count")), ('CONTACT_DUPLICATE_LEAD_EVENTS'::"text",'warning'::"text",("cq"."lead_event_count" > 1),GREATEST(("cq"."lead_event_count" - 1), (1)::bigint),COALESCE("cq"."first_business_event_at", "cq"."first_received_at"),"jsonb_build_object"('lead_event_count', "cq"."lead_event_count", 'duplicate_count', GREATEST(("cq"."lead_event_count" - 1), (1)::bigint))), ('CONTACT_EVENT_WITHOUT_BUSINESS_DATETIME'::"text",'warning'::"text",("cq"."events_without_datetime" > 0),"cq"."events_without_datetime","cq"."first_received_at","jsonb_build_object"('events_without_datetime', "cq"."events_without_datetime", 'total_events', "cq"."total_events", 'event_codes', "cq"."event_codes"))) "r"("issue_code", "severity", "is_issue", "issue_count", "issue_at", "details"))
          WHERE "r"."is_issue"
        ), "ordered_events" AS (
         SELECT "e"."client_id",
            "e"."client_name",
            "e"."client_slug",
            "e"."event_id",
            "e"."raw_event_id",
            "e"."contact_id",
            "e"."opportunity_id",
            "e"."full_name",
            "e"."phone",
            "e"."event_code",
            "e"."event_name",
            "e"."event_datetime",
            "e"."received_at",
            "e"."pipeline_stage",
            "e"."status",
            "e"."source_event_type",
            "lag"("e"."event_id") OVER (PARTITION BY "e"."client_id", "e"."contact_id", "e"."opportunity_id", "e"."event_code" ORDER BY "e"."event_datetime", "e"."received_at", "e"."event_id") AS "previous_event_id",
            "lag"("e"."raw_event_id") OVER (PARTITION BY "e"."client_id", "e"."contact_id", "e"."opportunity_id", "e"."event_code" ORDER BY "e"."event_datetime", "e"."received_at", "e"."event_id") AS "previous_raw_event_id",
            "lag"("e"."event_datetime") OVER (PARTITION BY "e"."client_id", "e"."contact_id", "e"."opportunity_id", "e"."event_code" ORDER BY "e"."event_datetime", "e"."received_at", "e"."event_id") AS "previous_event_at"
           FROM "public"."v_crm_events_feed_v2" "e"
          WHERE ("e"."contact_id" IS NOT NULL)
        ), "repeat_issues" AS (
         SELECT "oe"."client_id",
            "oe"."client_name",
            "oe"."client_slug",
            'event'::"text" AS "quality_area",
            'EVENT_REPEATED_WITHIN_60_SECONDS'::"text" AS "issue_code",
            'info'::"text" AS "severity",
            'event'::"text" AS "entity_type",
            ("oe"."event_id")::"text" AS "entity_id",
            "oe"."contact_id",
            "oe"."opportunity_id",
            "oe"."event_id",
            "oe"."full_name",
            "oe"."phone",
            "oe"."event_datetime" AS "issue_at",
            (("oe"."event_datetime" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "issue_date",
            (1)::bigint AS "issue_count",
            'v_crm_events_feed_v2'::"text" AS "source_relation",
            "jsonb_build_object"('event_code', "oe"."event_code", 'event_name', "oe"."event_name", 'previous_event_id', "oe"."previous_event_id", 'previous_raw_event_id', "oe"."previous_raw_event_id", 'previous_event_at', "oe"."previous_event_at", 'seconds_since_previous_event', EXTRACT(epoch FROM ("oe"."event_datetime" - "oe"."previous_event_at")), 'pipeline_stage', "oe"."pipeline_stage", 'status', "oe"."status", 'source_event_type', "oe"."source_event_type") AS "details"
           FROM "ordered_events" "oe"
          WHERE (("oe"."previous_event_at" IS NOT NULL) AND ((EXTRACT(epoch FROM ("oe"."event_datetime" - "oe"."previous_event_at")) >= (0)::numeric) AND (EXTRACT(epoch FROM ("oe"."event_datetime" - "oe"."previous_event_at")) <= (60)::numeric)))
        ), "journey_issues" AS (
         SELECT "j"."client_id",
            "j"."client_name",
            "j"."client_slug",
            'journey'::"text" AS "quality_area",
            "r"."issue_code",
            "r"."severity",
            'contact'::"text" AS "entity_type",
            "j"."contact_id" AS "entity_id",
            "j"."contact_id",
            NULL::"text" AS "opportunity_id",
            NULL::"uuid" AS "event_id",
            "j"."full_name",
            "j"."phone",
            "r"."issue_at",
            (("r"."issue_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "issue_date",
            (1)::bigint AS "issue_count",
            'v_crm_lead_journey_v2'::"text" AS "source_relation",
            "r"."details"
           FROM ("public"."v_crm_lead_journey_v2" "j"
             CROSS JOIN LATERAL ( VALUES ('JOURNEY_FIRST_CONVERSATION_BEFORE_LEAD'::"text",'warning'::"text",(("j"."primeira_conversa_at" IS NOT NULL) AND ("j"."primeira_conversa_at" < "j"."lead_at")),"j"."primeira_conversa_at","jsonb_build_object"('lead_at', "j"."lead_at", 'primeira_conversa_at', "j"."primeira_conversa_at")), ('JOURNEY_SCHEDULE_BEFORE_LEAD'::"text",'warning'::"text",(("j"."agendado_at" IS NOT NULL) AND ("j"."agendado_at" < "j"."lead_at")),"j"."agendado_at","jsonb_build_object"('lead_at', "j"."lead_at", 'agendado_at', "j"."agendado_at")), ('JOURNEY_GAIN_BEFORE_LEAD'::"text",'critical'::"text",(("j"."ganho_at" IS NOT NULL) AND ("j"."ganho_at" < "j"."lead_at")),"j"."ganho_at","jsonb_build_object"('lead_at', "j"."lead_at", 'ganho_at', "j"."ganho_at")), ('JOURNEY_LOSS_BEFORE_LEAD'::"text",'warning'::"text",(("j"."perdido_at" IS NOT NULL) AND ("j"."perdido_at" < "j"."lead_at")),"j"."perdido_at","jsonb_build_object"('lead_at', "j"."lead_at", 'perdido_at', "j"."perdido_at")), ('JOURNEY_HAS_GAIN_AND_LOSS'::"text",'warning'::"text",(("j"."ganho_at" IS NOT NULL) AND ("j"."perdido_at" IS NOT NULL)),GREATEST("j"."ganho_at", "j"."perdido_at"),"jsonb_build_object"('ganho_at', "j"."ganho_at", 'perdido_at', "j"."perdido_at"))) "r"("issue_code", "severity", "is_issue", "issue_at", "details"))
          WHERE "r"."is_issue"
        ), "opportunity_issues" AS (
         SELECT "o"."client_id",
            "o"."client_name",
            "o"."client_slug",
            'opportunity'::"text" AS "quality_area",
            "r"."issue_code",
            "r"."severity",
            'opportunity'::"text" AS "entity_type",
            "o"."opportunity_id" AS "entity_id",
            "o"."contact_id",
            "o"."opportunity_id",
            NULL::"uuid" AS "event_id",
            "o"."full_name",
            "o"."phone",
            "r"."issue_at",
            COALESCE((("r"."issue_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date", "o"."first_event_date") AS "issue_date",
            "r"."issue_count",
            'v_crm_opportunities_v2'::"text" AS "source_relation",
            "r"."details"
           FROM ("public"."v_crm_opportunities_v2" "o"
             CROSS JOIN LATERAL ( VALUES ('OPPORTUNITY_WITHOUT_CONTACT'::"text",'critical'::"text",("o"."distinct_contacts" = 0),(1)::bigint,"o"."first_event_at","jsonb_build_object"('distinct_contacts', "o"."distinct_contacts", 'opportunity_status', "o"."opportunity_status", 'total_events', "o"."total_events")), ('OPPORTUNITY_WITH_MULTIPLE_CONTACTS'::"text",'critical'::"text",("o"."distinct_contacts" > 1),"o"."distinct_contacts","o"."first_event_at","jsonb_build_object"('distinct_contacts', "o"."distinct_contacts", 'total_events', "o"."total_events")), ('OPPORTUNITY_MULTIPLE_GAIN_EVENTS'::"text",'warning'::"text",("o"."ganho_event_count" > 1),"o"."ganho_event_count","o"."ganho_at","jsonb_build_object"('ganho_event_count', "o"."ganho_event_count", 'source_event_types', "o"."source_event_types")), ('OPPORTUNITY_MULTIPLE_LOSS_EVENTS'::"text",'warning'::"text",("o"."perdido_event_count" > 1),"o"."perdido_event_count","o"."perdido_at","jsonb_build_object"('perdido_event_count', "o"."perdido_event_count", 'source_event_types', "o"."source_event_types")), ('OPPORTUNITY_HAS_GAIN_AND_LOSS'::"text",'critical'::"text",(("o"."ganho_event_count" > 0) AND ("o"."perdido_event_count" > 0)),(1)::bigint,GREATEST("o"."ganho_at", "o"."perdido_at"),"jsonb_build_object"('ganho_at', "o"."ganho_at", 'perdido_at', "o"."perdido_at", 'ganho_event_count', "o"."ganho_event_count", 'perdido_event_count', "o"."perdido_event_count")), ('OPPORTUNITY_GAIN_BEFORE_SCHEDULE'::"text",'warning'::"text",(("o"."ganho_at" IS NOT NULL) AND ("o"."agendado_at" IS NOT NULL) AND ("o"."ganho_at" < "o"."agendado_at")),(1)::bigint,"o"."ganho_at","jsonb_build_object"('agendado_at', "o"."agendado_at", 'ganho_at', "o"."ganho_at")), ('OPPORTUNITY_WITHOUT_CONTACT_LEAD_JOURNEY'::"text",'warning'::"text",("o"."has_contact_lead_journey" IS NOT TRUE),(1)::bigint,"o"."first_event_at","jsonb_build_object"('opportunity_status', "o"."opportunity_status", 'contact_lead_at', "o"."contact_lead_at", 'attribution_platform', "o"."attribution_platform"))) "r"("issue_code", "severity", "is_issue", "issue_count", "issue_at", "details"))
          WHERE "r"."is_issue"
        ), "sales_issues" AS (
         SELECT "s"."client_id",
            "s"."client_name",
            "s"."client_slug",
            "r"."quality_area",
            "r"."issue_code",
            "r"."severity",
            'sale'::"text" AS "entity_type",
            "s"."opportunity_id" AS "entity_id",
            "s"."contact_id",
            "s"."opportunity_id",
            NULL::"uuid" AS "event_id",
            "s"."full_name",
            "s"."phone",
            "s"."ganho_at" AS "issue_at",
            "s"."ganho_date" AS "issue_date",
            (1)::bigint AS "issue_count",
            'v_crm_sales_v2'::"text" AS "source_relation",
            "r"."details"
           FROM ("public"."v_crm_sales_v2" "s"
             CROSS JOIN LATERAL ( VALUES ('sale'::"text",'SALE_WITHOUT_INFORMED_VALUE'::"text",'critical'::"text",("s"."has_informed_value" IS NOT TRUE),"jsonb_build_object"('valor_ganho', "s"."valor_ganho", 'revenue_quality', "s"."revenue_quality", 'is_acquisition_sale', "s"."is_acquisition_sale", 'is_cohort_linkable', "s"."is_cohort_linkable", 'opportunity_link_type', "s"."opportunity_link_type")), ('sale'::"text",'SALE_WITH_INVALID_VALUE'::"text",'critical'::"text",(("s"."has_informed_value" IS TRUE) AND ("s"."has_valid_value" IS NOT TRUE)),"jsonb_build_object"('valor_ganho', "s"."valor_ganho", 'revenue_quality', "s"."revenue_quality", 'has_informed_value', "s"."has_informed_value", 'has_valid_value', "s"."has_valid_value")), ('sale'::"text",'SALE_NOT_COHORT_LINKABLE'::"text",'warning'::"text",("s"."is_cohort_linkable" IS NOT TRUE),"jsonb_build_object"('has_contact_lead_journey', "s"."has_contact_lead_journey", 'is_acquisition_sale', "s"."is_acquisition_sale", 'is_cohort_linkable', "s"."is_cohort_linkable", 'opportunity_link_type', "s"."opportunity_link_type")), ('attribution'::"text",'SALE_ATTRIBUTION_CONFLICT'::"text",'critical'::"text",("s"."attribution_platform" = 'Conflito de atribuição'::"text"),"jsonb_build_object"('attribution_platform', "s"."attribution_platform", 'meta_ad_id', "s"."meta_ad_id", 'google_campaign_id', "s"."google_campaign_id", 'google_adgroup_id', "s"."google_adgroup_id", 'google_ad_id', "s"."google_ad_id")), ('attribution'::"text",'SALE_WITHOUT_TECHNICAL_ATTRIBUTION'::"text",'warning'::"text",("s"."attribution_platform" = 'Não atribuído'::"text"),"jsonb_build_object"('attribution_platform', "s"."attribution_platform", 'lead_origem', "s"."lead_origem", 'lead_entrada', "s"."lead_entrada"))) "r"("quality_area", "issue_code", "severity", "is_issue", "details"))
          WHERE "r"."is_issue"
        ), "lead_attribution_issues" AS (
         SELECT "l"."client_id",
            "l"."client_name",
            "l"."client_slug",
            'attribution'::"text" AS "quality_area",
            "r"."issue_code",
            "r"."severity",
            'contact'::"text" AS "entity_type",
            "l"."contact_id" AS "entity_id",
            "l"."contact_id",
            NULL::"text" AS "opportunity_id",
            NULL::"uuid" AS "event_id",
            "l"."full_name",
            "l"."phone",
            "l"."lead_at" AS "issue_at",
            "l"."lead_date" AS "issue_date",
            (1)::bigint AS "issue_count",
            'v_client_leads_by_stage_v2'::"text" AS "source_relation",
            "r"."details"
           FROM ("public"."v_client_leads_by_stage_v2" "l"
             CROSS JOIN LATERAL ( VALUES ('LEAD_ATTRIBUTION_CONFLICT'::"text",'critical'::"text",("l"."attribution_platform" = 'Conflito de atribuição'::"text"),"jsonb_build_object"('attribution_platform', "l"."attribution_platform", 'meta_ad_id', "l"."meta_ad_id", 'google_campaign_id', "l"."google_campaign_id", 'google_adgroup_id', "l"."google_adgroup_id", 'google_ad_id', "l"."google_ad_id")), ('META_LEAD_WITHOUT_MEDIA_MAPPING'::"text",'warning'::"text",(("l"."meta_ad_id" IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
                           FROM "public"."v_meta_ads_v2" "m"
                          WHERE (("m"."client_id" = "l"."client_id") AND ("m"."ad_id" = "l"."meta_ad_id")))))),"jsonb_build_object"('meta_ad_id', "l"."meta_ad_id", 'attribution_platform', "l"."attribution_platform")), ('GOOGLE_LEAD_WITHOUT_CAMPAIGN_ID'::"text",'warning'::"text",(("l"."has_google_attribution" IS TRUE) AND ("l"."google_campaign_id" IS NULL)),"jsonb_build_object"('attribution_platform', "l"."attribution_platform", 'gclid', "l"."gclid", 'gbraid', "l"."gbraid", 'wbraid', "l"."wbraid")), ('GOOGLE_LEAD_WITHOUT_AD_GROUP_ID'::"text",'info'::"text",(("l"."has_google_attribution" IS TRUE) AND ("l"."google_campaign_id" IS NOT NULL) AND ("l"."google_adgroup_id" IS NULL)),"jsonb_build_object"('google_campaign_id', "l"."google_campaign_id", 'google_adgroup_id', "l"."google_adgroup_id")), ('GOOGLE_LEAD_WITHOUT_AD_ID'::"text",'info'::"text",(("l"."has_google_attribution" IS TRUE) AND ("l"."google_campaign_id" IS NOT NULL) AND ("l"."google_ad_id" IS NULL)),"jsonb_build_object"('google_campaign_id', "l"."google_campaign_id", 'google_adgroup_id', "l"."google_adgroup_id", 'google_ad_id', "l"."google_ad_id")), ('GOOGLE_LEAD_WITHOUT_MEDIA_MAPPING'::"text",'warning'::"text",(("l"."google_campaign_id" IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
                           FROM "public"."v_google_ads_v2" "g"
                          WHERE (("g"."client_id" = "l"."client_id") AND ("g"."campaign_id" = "l"."google_campaign_id")))))),"jsonb_build_object"('google_campaign_id', "l"."google_campaign_id", 'attribution_platform', "l"."attribution_platform"))) "r"("issue_code", "severity", "is_issue", "details"))
          WHERE "r"."is_issue"
        ), "meta_hierarchy" AS (
         SELECT "m"."client_id",
            "max"("m"."client_name") AS "client_name",
            "max"("m"."client_slug") AS "client_slug",
            "m"."ad_id",
            "count"(DISTINCT "m"."account_id") AS "account_ids",
            "count"(DISTINCT "m"."campaign_id") AS "campaign_ids",
            "count"(DISTINCT "m"."adset_id") AS "adset_ids",
            "count"(DISTINCT "m"."creative_id") FILTER (WHERE ("m"."creative_id" IS NOT NULL)) AS "creative_ids"
           FROM "public"."v_meta_ads_v2" "m"
          WHERE ("m"."ad_id" IS NOT NULL)
          GROUP BY "m"."client_id", "m"."ad_id"
        ), "meta_hierarchy_issues" AS (
         SELECT "mh"."client_id",
            "mh"."client_name",
            "mh"."client_slug",
            'media'::"text" AS "quality_area",
            "r"."issue_code",
            "r"."severity",
            'meta_ad'::"text" AS "entity_type",
            "mh"."ad_id" AS "entity_id",
            NULL::"text" AS "contact_id",
            NULL::"text" AS "opportunity_id",
            NULL::"uuid" AS "event_id",
            NULL::"text" AS "full_name",
            NULL::"text" AS "phone",
            NULL::timestamp with time zone AS "issue_at",
            NULL::"date" AS "issue_date",
            "r"."issue_count",
            'v_meta_ads_v2'::"text" AS "source_relation",
            "r"."details"
           FROM ("meta_hierarchy" "mh"
             CROSS JOIN LATERAL ( VALUES ('META_AD_WITH_MULTIPLE_ACCOUNTS'::"text",'critical'::"text",("mh"."account_ids" > 1),"mh"."account_ids","jsonb_build_object"('ad_id', "mh"."ad_id", 'distinct_account_ids', "mh"."account_ids")), ('META_AD_WITH_MULTIPLE_CAMPAIGNS'::"text",'critical'::"text",("mh"."campaign_ids" > 1),"mh"."campaign_ids","jsonb_build_object"('ad_id', "mh"."ad_id", 'distinct_campaign_ids', "mh"."campaign_ids")), ('META_AD_WITH_MULTIPLE_ADSETS'::"text",'critical'::"text",("mh"."adset_ids" > 1),"mh"."adset_ids","jsonb_build_object"('ad_id', "mh"."ad_id", 'distinct_adset_ids', "mh"."adset_ids")), ('META_AD_WITH_MULTIPLE_CREATIVES'::"text",'warning'::"text",("mh"."creative_ids" > 1),"mh"."creative_ids","jsonb_build_object"('ad_id', "mh"."ad_id", 'distinct_creative_ids', "mh"."creative_ids", 'resolution_rule', 'latest_known_creative'))) "r"("issue_code", "severity", "is_issue", "issue_count", "details"))
          WHERE "r"."is_issue"
        ), "google_hierarchy" AS (
         SELECT "g"."client_id",
            "max"("g"."client_name") AS "client_name",
            "max"("g"."client_slug") AS "client_slug",
            'google_ad'::"text" AS "entity_type",
            "g"."ad_id" AS "entity_id",
            "count"(DISTINCT "g"."ad_group_id") AS "ad_group_ids",
            "count"(DISTINCT "g"."campaign_id") AS "campaign_ids",
            "count"(DISTINCT "g"."customer_id") AS "customer_ids"
           FROM "public"."v_google_ads_v2" "g"
          WHERE ("g"."ad_id" IS NOT NULL)
          GROUP BY "g"."client_id", "g"."ad_id"
        UNION ALL
         SELECT "g"."client_id",
            "max"("g"."client_name") AS "max",
            "max"("g"."client_slug") AS "max",
            'google_ad_group'::"text",
            "g"."ad_group_id",
            (0)::bigint AS "int8",
            "count"(DISTINCT "g"."campaign_id") AS "count",
            "count"(DISTINCT "g"."customer_id") AS "count"
           FROM "public"."v_google_ads_v2" "g"
          WHERE ("g"."ad_group_id" IS NOT NULL)
          GROUP BY "g"."client_id", "g"."ad_group_id"
        UNION ALL
         SELECT "g"."client_id",
            "max"("g"."client_name") AS "max",
            "max"("g"."client_slug") AS "max",
            'google_campaign'::"text",
            "g"."campaign_id",
            (0)::bigint AS "int8",
            (0)::bigint AS "int8",
            "count"(DISTINCT "g"."customer_id") AS "count"
           FROM "public"."v_google_ads_v2" "g"
          WHERE ("g"."campaign_id" IS NOT NULL)
          GROUP BY "g"."client_id", "g"."campaign_id"
        ), "google_hierarchy_issues" AS (
         SELECT "gh"."client_id",
            "gh"."client_name",
            "gh"."client_slug",
            'media'::"text" AS "quality_area",
            "r"."issue_code",
            'critical'::"text" AS "severity",
            "gh"."entity_type",
            "gh"."entity_id",
            NULL::"text" AS "contact_id",
            NULL::"text" AS "opportunity_id",
            NULL::"uuid" AS "event_id",
            NULL::"text" AS "full_name",
            NULL::"text" AS "phone",
            NULL::timestamp with time zone AS "issue_at",
            NULL::"date" AS "issue_date",
            "r"."issue_count",
            'v_google_ads_v2'::"text" AS "source_relation",
            "r"."details"
           FROM ("google_hierarchy" "gh"
             CROSS JOIN LATERAL ( VALUES ('GOOGLE_AD_WITH_MULTIPLE_AD_GROUPS'::"text",(("gh"."entity_type" = 'google_ad'::"text") AND ("gh"."ad_group_ids" > 1)),"gh"."ad_group_ids","jsonb_build_object"('ad_id', "gh"."entity_id", 'distinct_ad_group_ids', "gh"."ad_group_ids")), ('GOOGLE_AD_WITH_MULTIPLE_CAMPAIGNS'::"text",(("gh"."entity_type" = 'google_ad'::"text") AND ("gh"."campaign_ids" > 1)),"gh"."campaign_ids","jsonb_build_object"('ad_id', "gh"."entity_id", 'distinct_campaign_ids', "gh"."campaign_ids")), ('GOOGLE_AD_WITH_MULTIPLE_ACCOUNTS'::"text",(("gh"."entity_type" = 'google_ad'::"text") AND ("gh"."customer_ids" > 1)),"gh"."customer_ids","jsonb_build_object"('ad_id', "gh"."entity_id", 'distinct_customer_ids', "gh"."customer_ids")), ('GOOGLE_AD_GROUP_WITH_MULTIPLE_CAMPAIGNS'::"text",(("gh"."entity_type" = 'google_ad_group'::"text") AND ("gh"."campaign_ids" > 1)),"gh"."campaign_ids","jsonb_build_object"('ad_group_id', "gh"."entity_id", 'distinct_campaign_ids', "gh"."campaign_ids")), ('GOOGLE_AD_GROUP_WITH_MULTIPLE_ACCOUNTS'::"text",(("gh"."entity_type" = 'google_ad_group'::"text") AND ("gh"."customer_ids" > 1)),"gh"."customer_ids","jsonb_build_object"('ad_group_id', "gh"."entity_id", 'distinct_customer_ids', "gh"."customer_ids")), ('GOOGLE_CAMPAIGN_WITH_MULTIPLE_ACCOUNTS'::"text",(("gh"."entity_type" = 'google_campaign'::"text") AND ("gh"."customer_ids" > 1)),"gh"."customer_ids","jsonb_build_object"('campaign_id', "gh"."entity_id", 'distinct_customer_ids', "gh"."customer_ids"))) "r"("issue_code", "is_issue", "issue_count", "details"))
          WHERE "r"."is_issue"
        ), "all_issues" AS (
         SELECT "contact_issues"."client_id",
            "contact_issues"."client_name",
            "contact_issues"."client_slug",
            "contact_issues"."quality_area",
            "contact_issues"."issue_code",
            "contact_issues"."severity",
            "contact_issues"."entity_type",
            "contact_issues"."entity_id",
            "contact_issues"."contact_id",
            "contact_issues"."opportunity_id",
            "contact_issues"."event_id",
            "contact_issues"."full_name",
            "contact_issues"."phone",
            "contact_issues"."issue_at",
            "contact_issues"."issue_date",
            "contact_issues"."issue_count",
            "contact_issues"."source_relation",
            "contact_issues"."details"
           FROM "contact_issues"
        UNION ALL
         SELECT "repeat_issues"."client_id",
            "repeat_issues"."client_name",
            "repeat_issues"."client_slug",
            "repeat_issues"."quality_area",
            "repeat_issues"."issue_code",
            "repeat_issues"."severity",
            "repeat_issues"."entity_type",
            "repeat_issues"."entity_id",
            "repeat_issues"."contact_id",
            "repeat_issues"."opportunity_id",
            "repeat_issues"."event_id",
            "repeat_issues"."full_name",
            "repeat_issues"."phone",
            "repeat_issues"."issue_at",
            "repeat_issues"."issue_date",
            "repeat_issues"."issue_count",
            "repeat_issues"."source_relation",
            "repeat_issues"."details"
           FROM "repeat_issues"
        UNION ALL
         SELECT "journey_issues"."client_id",
            "journey_issues"."client_name",
            "journey_issues"."client_slug",
            "journey_issues"."quality_area",
            "journey_issues"."issue_code",
            "journey_issues"."severity",
            "journey_issues"."entity_type",
            "journey_issues"."entity_id",
            "journey_issues"."contact_id",
            "journey_issues"."opportunity_id",
            "journey_issues"."event_id",
            "journey_issues"."full_name",
            "journey_issues"."phone",
            "journey_issues"."issue_at",
            "journey_issues"."issue_date",
            "journey_issues"."issue_count",
            "journey_issues"."source_relation",
            "journey_issues"."details"
           FROM "journey_issues"
        UNION ALL
         SELECT "opportunity_issues"."client_id",
            "opportunity_issues"."client_name",
            "opportunity_issues"."client_slug",
            "opportunity_issues"."quality_area",
            "opportunity_issues"."issue_code",
            "opportunity_issues"."severity",
            "opportunity_issues"."entity_type",
            "opportunity_issues"."entity_id",
            "opportunity_issues"."contact_id",
            "opportunity_issues"."opportunity_id",
            "opportunity_issues"."event_id",
            "opportunity_issues"."full_name",
            "opportunity_issues"."phone",
            "opportunity_issues"."issue_at",
            "opportunity_issues"."issue_date",
            "opportunity_issues"."issue_count",
            "opportunity_issues"."source_relation",
            "opportunity_issues"."details"
           FROM "opportunity_issues"
        UNION ALL
         SELECT "sales_issues"."client_id",
            "sales_issues"."client_name",
            "sales_issues"."client_slug",
            "sales_issues"."quality_area",
            "sales_issues"."issue_code",
            "sales_issues"."severity",
            "sales_issues"."entity_type",
            "sales_issues"."entity_id",
            "sales_issues"."contact_id",
            "sales_issues"."opportunity_id",
            "sales_issues"."event_id",
            "sales_issues"."full_name",
            "sales_issues"."phone",
            "sales_issues"."issue_at",
            "sales_issues"."issue_date",
            "sales_issues"."issue_count",
            "sales_issues"."source_relation",
            "sales_issues"."details"
           FROM "sales_issues"
        UNION ALL
         SELECT "lead_attribution_issues"."client_id",
            "lead_attribution_issues"."client_name",
            "lead_attribution_issues"."client_slug",
            "lead_attribution_issues"."quality_area",
            "lead_attribution_issues"."issue_code",
            "lead_attribution_issues"."severity",
            "lead_attribution_issues"."entity_type",
            "lead_attribution_issues"."entity_id",
            "lead_attribution_issues"."contact_id",
            "lead_attribution_issues"."opportunity_id",
            "lead_attribution_issues"."event_id",
            "lead_attribution_issues"."full_name",
            "lead_attribution_issues"."phone",
            "lead_attribution_issues"."issue_at",
            "lead_attribution_issues"."issue_date",
            "lead_attribution_issues"."issue_count",
            "lead_attribution_issues"."source_relation",
            "lead_attribution_issues"."details"
           FROM "lead_attribution_issues"
        UNION ALL
         SELECT "meta_hierarchy_issues"."client_id",
            "meta_hierarchy_issues"."client_name",
            "meta_hierarchy_issues"."client_slug",
            "meta_hierarchy_issues"."quality_area",
            "meta_hierarchy_issues"."issue_code",
            "meta_hierarchy_issues"."severity",
            "meta_hierarchy_issues"."entity_type",
            "meta_hierarchy_issues"."entity_id",
            "meta_hierarchy_issues"."contact_id",
            "meta_hierarchy_issues"."opportunity_id",
            "meta_hierarchy_issues"."event_id",
            "meta_hierarchy_issues"."full_name",
            "meta_hierarchy_issues"."phone",
            "meta_hierarchy_issues"."issue_at",
            "meta_hierarchy_issues"."issue_date",
            "meta_hierarchy_issues"."issue_count",
            "meta_hierarchy_issues"."source_relation",
            "meta_hierarchy_issues"."details"
           FROM "meta_hierarchy_issues"
        UNION ALL
         SELECT "google_hierarchy_issues"."client_id",
            "google_hierarchy_issues"."client_name",
            "google_hierarchy_issues"."client_slug",
            "google_hierarchy_issues"."quality_area",
            "google_hierarchy_issues"."issue_code",
            "google_hierarchy_issues"."severity",
            "google_hierarchy_issues"."entity_type",
            "google_hierarchy_issues"."entity_id",
            "google_hierarchy_issues"."contact_id",
            "google_hierarchy_issues"."opportunity_id",
            "google_hierarchy_issues"."event_id",
            "google_hierarchy_issues"."full_name",
            "google_hierarchy_issues"."phone",
            "google_hierarchy_issues"."issue_at",
            "google_hierarchy_issues"."issue_date",
            "google_hierarchy_issues"."issue_count",
            "google_hierarchy_issues"."source_relation",
            "google_hierarchy_issues"."details"
           FROM "google_hierarchy_issues"
        )
 SELECT "md5"("concat_ws"('|'::"text", ("client_id")::"text", "issue_code", "entity_type", COALESCE("entity_id", ''::"text"), COALESCE(("event_id")::"text", ''::"text"))) AS "quality_id",
    "client_id",
    "client_name",
    "client_slug",
    "quality_area",
    "issue_code",
    "severity",
    "entity_type",
    "entity_id",
    "contact_id",
    "opportunity_id",
    "event_id",
    "full_name",
    "phone",
    "issue_at",
    "issue_date",
    "issue_count",
    "source_relation",
    "details"
   FROM "all_issues" "ai";


ALTER VIEW "public"."v_data_quality_v2" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_data_quality_v2" IS 'Fonte única de qualidade de dados V2. Centraliza alertas de contato, evento, jornada, oportunidade, venda, atribuição e mídia. security_invoker=true. Não deve alimentar métricas principais do dashboard.';



CREATE OR REPLACE VIEW "public"."v_event_tracking_audit" WITH ("security_barrier"='true', "security_invoker"='false') AS
 WITH "settings" AS (
         SELECT '02:00:00'::interval AS "workflow_sla",
            '24:00:00'::interval AS "conversion_sla"
        ), "inbound_ranked" AS (
         SELECT "w"."id",
            "w"."workflow_key",
            "w"."workflow_name",
            "w"."workflow_category",
            "w"."n8n_execution_id",
            "w"."client_id",
            "w"."client_slug",
            "w"."client_name",
            "w"."ghl_location_id",
            "w"."status",
            "w"."stage",
            "w"."started_at",
            "w"."finished_at",
            "w"."duration_ms",
            "w"."items_processed",
            "w"."items_failed",
            "w"."error_message",
            "w"."error_node",
            "w"."stages",
            "w"."metadata",
            "w"."created_at",
            ("w"."metadata" ->> 'raw_event_id'::"text") AS "correlated_raw_event_id",
            "row_number"() OVER (PARTITION BY ("w"."metadata" ->> 'raw_event_id'::"text") ORDER BY
                CASE
                    WHEN (("w"."status" = 'error'::"text") OR ("w"."error_message" IS NOT NULL)) THEN 0
                    ELSE 1
                END, "w"."started_at" DESC,
                CASE
                    WHEN ("w"."finished_at" IS NOT NULL) THEN 0
                    ELSE 1
                END, "w"."id" DESC) AS "relevance_rank"
           FROM "public"."workflow_execution_logs" "w"
          WHERE (("w"."workflow_key" = '1.1'::"text") AND (NULLIF(("w"."metadata" ->> 'raw_event_id'::"text"), ''::"text") IS NOT NULL))
        ), "inbound_log" AS (
         SELECT "inbound_ranked"."id",
            "inbound_ranked"."workflow_key",
            "inbound_ranked"."workflow_name",
            "inbound_ranked"."workflow_category",
            "inbound_ranked"."n8n_execution_id",
            "inbound_ranked"."client_id",
            "inbound_ranked"."client_slug",
            "inbound_ranked"."client_name",
            "inbound_ranked"."ghl_location_id",
            "inbound_ranked"."status",
            "inbound_ranked"."stage",
            "inbound_ranked"."started_at",
            "inbound_ranked"."finished_at",
            "inbound_ranked"."duration_ms",
            "inbound_ranked"."items_processed",
            "inbound_ranked"."items_failed",
            "inbound_ranked"."error_message",
            "inbound_ranked"."error_node",
            "inbound_ranked"."stages",
            "inbound_ranked"."metadata",
            "inbound_ranked"."created_at",
            "inbound_ranked"."correlated_raw_event_id",
            "inbound_ranked"."relevance_rank"
           FROM "inbound_ranked"
          WHERE ("inbound_ranked"."relevance_rank" = 1)
        ), "dispatch_ranked" AS (
         SELECT "w"."id",
            "w"."workflow_key",
            "w"."workflow_name",
            "w"."workflow_category",
            "w"."n8n_execution_id",
            "w"."client_id",
            "w"."client_slug",
            "w"."client_name",
            "w"."ghl_location_id",
            "w"."status",
            "w"."stage",
            "w"."started_at",
            "w"."finished_at",
            "w"."duration_ms",
            "w"."items_processed",
            "w"."items_failed",
            "w"."error_message",
            "w"."error_node",
            "w"."stages",
            "w"."metadata",
            "w"."created_at",
            ("w"."metadata" ->> 'outbox_id'::"text") AS "correlated_outbox_id",
            "row_number"() OVER (PARTITION BY ("w"."metadata" ->> 'outbox_id'::"text") ORDER BY
                CASE
                    WHEN (("w"."status" = 'error'::"text") OR ("w"."error_message" IS NOT NULL)) THEN 0
                    ELSE 1
                END, "w"."started_at" DESC,
                CASE
                    WHEN ("w"."finished_at" IS NOT NULL) THEN 0
                    ELSE 1
                END, "w"."id" DESC) AS "relevance_rank"
           FROM "public"."workflow_execution_logs" "w"
          WHERE (("w"."workflow_key" = ANY (ARRAY['1.2'::"text", '1.3'::"text"])) AND (NULLIF(("w"."metadata" ->> 'outbox_id'::"text"), ''::"text") IS NOT NULL))
        ), "dispatch_log" AS (
         SELECT "dispatch_ranked"."id",
            "dispatch_ranked"."workflow_key",
            "dispatch_ranked"."workflow_name",
            "dispatch_ranked"."workflow_category",
            "dispatch_ranked"."n8n_execution_id",
            "dispatch_ranked"."client_id",
            "dispatch_ranked"."client_slug",
            "dispatch_ranked"."client_name",
            "dispatch_ranked"."ghl_location_id",
            "dispatch_ranked"."status",
            "dispatch_ranked"."stage",
            "dispatch_ranked"."started_at",
            "dispatch_ranked"."finished_at",
            "dispatch_ranked"."duration_ms",
            "dispatch_ranked"."items_processed",
            "dispatch_ranked"."items_failed",
            "dispatch_ranked"."error_message",
            "dispatch_ranked"."error_node",
            "dispatch_ranked"."stages",
            "dispatch_ranked"."metadata",
            "dispatch_ranked"."created_at",
            "dispatch_ranked"."correlated_outbox_id",
            "dispatch_ranked"."relevance_rank"
           FROM "dispatch_ranked"
          WHERE ("dispatch_ranked"."relevance_rank" = 1)
        ), "conversion_jobs_base" AS (
         SELECT "co"."id",
            "co"."normalized_event_id",
            "co"."platform",
            "co"."route",
            "co"."meta_event_name",
            "co"."platform_event_name",
            "co"."status",
            "co"."attempts",
            "co"."http_status",
            "co"."created_at",
            "co"."sent_at",
            "co"."next_attempt_at",
            "co"."last_error",
            "co"."error_details",
            "co"."error_code",
            "co"."response",
            "dl"."workflow_key" AS "dispatch_workflow_key",
            "dl"."workflow_name" AS "dispatch_workflow_name",
            "dl"."n8n_execution_id" AS "dispatch_execution_id",
            "dl"."status" AS "dispatch_source_status",
            "dl"."stage" AS "dispatch_checkpoint",
            "dl"."started_at" AS "dispatch_started_at",
            "dl"."finished_at" AS "dispatch_finished_at",
            "dl"."error_node" AS "dispatch_error_node",
            "dl"."error_message" AS "dispatch_error_message",
                CASE
                    WHEN ("co"."status" = 'failed'::"text") THEN 'failed'::"text"
                    WHEN (("co"."status" = 'pending'::"text") AND ("co"."created_at" < ("clock_timestamp"() - "s"."conversion_sla"))) THEN 'stuck'::"text"
                    ELSE "co"."status"
                END AS "conversion_audit_status",
            COALESCE(NULLIF("co"."last_error", ''::"text"), NULLIF(("co"."error_details" ->> 'message'::"text"), ''::"text"), NULLIF(("co"."error_details" ->> 'error'::"text"), ''::"text"), NULLIF("co"."error_code", ''::"text"), NULLIF(("co"."response" #>> '{error,message}'::"text"[]), ''::"text"), NULLIF(("co"."response" ->> 'message'::"text"), ''::"text")) AS "conversion_reason",
                CASE
                    WHEN (("dl"."id" IS NULL) AND ("co"."status" = 'pending'::"text")) THEN 'dispatcher_not_started'::"text"
                    WHEN ("dl"."id" IS NULL) THEN 'workflow_log_missing'::"text"
                    WHEN (("dl"."status" = 'error'::"text") OR ("dl"."error_message" IS NOT NULL)) THEN 'error'::"text"
                    WHEN (("dl"."status" = 'running'::"text") AND ("dl"."started_at" < ("clock_timestamp"() - "s"."workflow_sla"))) THEN 'not_closed'::"text"
                    WHEN ("dl"."status" = 'running'::"text") THEN 'running'::"text"
                    WHEN ("dl"."status" = ANY (ARRAY['success'::"text", 'skipped'::"text"])) THEN 'ok'::"text"
                    WHEN ("dl"."status" = 'partial'::"text") THEN 'error'::"text"
                    ELSE 'workflow_log_missing'::"text"
                END AS "dispatch_audit_status"
           FROM (("public"."conversion_outbox" "co"
             CROSS JOIN "settings" "s")
             LEFT JOIN "dispatch_log" "dl" ON (("dl"."correlated_outbox_id" = ("co"."id")::"text")))
        ), "conversion_jobs_agg" AS (
         SELECT "conversion_jobs_base"."normalized_event_id",
            ("count"(*))::integer AS "conversion_jobs_count",
            "count"(*) FILTER (WHERE ("conversion_jobs_base"."conversion_audit_status" = 'failed'::"text")) AS "failed_count",
            "count"(*) FILTER (WHERE ("conversion_jobs_base"."conversion_audit_status" = 'stuck'::"text")) AS "stuck_count",
            "count"(*) FILTER (WHERE ("conversion_jobs_base"."conversion_audit_status" = 'pending'::"text")) AS "pending_count",
            "count"(*) FILTER (WHERE ("conversion_jobs_base"."conversion_audit_status" = 'sent'::"text")) AS "sent_count",
            "count"(*) FILTER (WHERE ("conversion_jobs_base"."conversion_audit_status" = 'skipped'::"text")) AS "skipped_count",
            "count"(*) FILTER (WHERE ("conversion_jobs_base"."dispatch_audit_status" = 'error'::"text")) AS "dispatch_error_count",
            "count"(*) FILTER (WHERE ("conversion_jobs_base"."dispatch_audit_status" = 'not_closed'::"text")) AS "dispatch_not_closed_count",
            "count"(*) FILTER (WHERE ("conversion_jobs_base"."dispatch_audit_status" = 'running'::"text")) AS "dispatch_running_count",
            "count"(*) FILTER (WHERE ("conversion_jobs_base"."dispatch_audit_status" = 'dispatcher_not_started'::"text")) AS "dispatcher_not_started_count",
            "count"(*) FILTER (WHERE ("conversion_jobs_base"."dispatch_audit_status" = 'workflow_log_missing'::"text")) AS "dispatch_log_missing_count",
            ("array_agg"("conversion_jobs_base"."conversion_reason" ORDER BY
                CASE "conversion_jobs_base"."conversion_audit_status"
                    WHEN 'failed'::"text" THEN 1
                    WHEN 'stuck'::"text" THEN 2
                    WHEN 'pending'::"text" THEN 3
                    WHEN 'skipped'::"text" THEN 4
                    ELSE 5
                END, "conversion_jobs_base"."created_at" DESC) FILTER (WHERE ("conversion_jobs_base"."conversion_reason" IS NOT NULL)))[1] AS "prioritized_conversion_reason",
            "jsonb_agg"("jsonb_strip_nulls"("jsonb_build_object"('outbox_id', "conversion_jobs_base"."id", 'normalized_event_id', "conversion_jobs_base"."normalized_event_id", 'platform', "conversion_jobs_base"."platform", 'route', "conversion_jobs_base"."route", 'platform_event_name', COALESCE("conversion_jobs_base"."platform_event_name", "conversion_jobs_base"."meta_event_name"), 'status', "conversion_jobs_base"."status", 'audit_status', "conversion_jobs_base"."conversion_audit_status", 'reason', "conversion_jobs_base"."conversion_reason", 'attempts', "conversion_jobs_base"."attempts", 'http_status', "conversion_jobs_base"."http_status", 'created_at', "conversion_jobs_base"."created_at", 'sent_at', "conversion_jobs_base"."sent_at", 'next_attempt_at', "conversion_jobs_base"."next_attempt_at", 'dispatch_workflow_key', "conversion_jobs_base"."dispatch_workflow_key", 'dispatch_workflow_name', "conversion_jobs_base"."dispatch_workflow_name", 'dispatch_execution_id', "conversion_jobs_base"."dispatch_execution_id", 'dispatch_source_status', "conversion_jobs_base"."dispatch_source_status", 'dispatch_status', "conversion_jobs_base"."dispatch_audit_status", 'last_checkpoint', "conversion_jobs_base"."dispatch_checkpoint", 'dispatch_started_at', "conversion_jobs_base"."dispatch_started_at", 'dispatch_finished_at', "conversion_jobs_base"."dispatch_finished_at", 'dispatch_error_node', "conversion_jobs_base"."dispatch_error_node", 'dispatch_error_message', "conversion_jobs_base"."dispatch_error_message")) ORDER BY "conversion_jobs_base"."created_at", "conversion_jobs_base"."platform", "conversion_jobs_base"."route", "conversion_jobs_base"."id") AS "conversion_jobs",
            "jsonb_agg"("jsonb_strip_nulls"("jsonb_build_object"('outbox_id', "conversion_jobs_base"."id", 'platform', "conversion_jobs_base"."platform", 'workflow_key', "conversion_jobs_base"."dispatch_workflow_key", 'workflow_name', "conversion_jobs_base"."dispatch_workflow_name", 'execution_id', "conversion_jobs_base"."dispatch_execution_id", 'source_status', "conversion_jobs_base"."dispatch_source_status", 'status', "conversion_jobs_base"."dispatch_audit_status", 'last_checkpoint', "conversion_jobs_base"."dispatch_checkpoint", 'started_at', "conversion_jobs_base"."dispatch_started_at", 'finished_at', "conversion_jobs_base"."dispatch_finished_at", 'error_node', "conversion_jobs_base"."dispatch_error_node", 'error_message', "conversion_jobs_base"."dispatch_error_message")) ORDER BY "conversion_jobs_base"."created_at", "conversion_jobs_base"."platform", "conversion_jobs_base"."route", "conversion_jobs_base"."id") AS "dispatch_n8n_summary"
           FROM "conversion_jobs_base"
          GROUP BY "conversion_jobs_base"."normalized_event_id"
        ), "base" AS (
         SELECT "er"."id" AS "raw_event_id",
            "en"."id" AS "normalized_event_id",
            COALESCE("en"."client_id", "cb"."id") AS "client_id",
            COALESCE("en"."client_name", "cb"."client_name") AS "client_name",
            "cb"."client_slug",
            COALESCE("en"."ghl_location_id", "er"."location_id") AS "ghl_location_id",
            COALESCE("en"."contact_id", "er"."contact_id") AS "contact_id",
            "en"."full_name",
            COALESCE("en"."event_code", "lower"("er"."event_type")) AS "event_code",
            "en"."event_datetime",
            "er"."received_at",
            "er"."processing_status" AS "raw_processing_status",
            "er"."processing_error" AS "raw_processing_error",
            "er"."processed_at" AS "raw_processed_at",
            "en"."normalization_status",
            "en"."normalization_error",
            "il"."n8n_execution_id" AS "inbound_n8n_execution_id",
            "il"."status" AS "inbound_n8n_source_status",
            "il"."stage" AS "inbound_n8n_stage",
            "il"."error_node" AS "inbound_n8n_error_node",
            "il"."error_message" AS "inbound_n8n_error_message",
            "il"."started_at" AS "inbound_n8n_started_at",
            "il"."finished_at" AS "inbound_n8n_finished_at",
            "cja"."conversion_jobs_count",
            "cja"."failed_count",
            "cja"."stuck_count",
            "cja"."pending_count",
            "cja"."sent_count",
            "cja"."skipped_count",
            "cja"."dispatch_error_count",
            "cja"."dispatch_not_closed_count",
            "cja"."dispatch_running_count",
            "cja"."dispatcher_not_started_count",
            "cja"."dispatch_log_missing_count",
            "cja"."prioritized_conversion_reason",
            "cja"."conversion_jobs",
            "cja"."dispatch_n8n_summary"
           FROM (((("public"."events_raw" "er"
             LEFT JOIN "public"."events_normalized" "en" ON (("en"."raw_event_id" = "er"."id")))
             LEFT JOIN "public"."clients_base" "cb" ON ((("cb"."id" = "en"."client_id") OR (("en"."client_id" IS NULL) AND ("cb"."ghl_location_id" = "er"."location_id")))))
             LEFT JOIN "inbound_log" "il" ON (("il"."correlated_raw_event_id" = ("er"."id")::"text")))
             LEFT JOIN "conversion_jobs_agg" "cja" ON (("cja"."normalized_event_id" = "en"."id")))
        ), "classified" AS (
         SELECT "b"."raw_event_id",
            "b"."normalized_event_id",
            "b"."client_id",
            "b"."client_name",
            "b"."client_slug",
            "b"."ghl_location_id",
            "b"."contact_id",
            "b"."full_name",
            "b"."event_code",
            "b"."event_datetime",
            "b"."received_at",
            "b"."raw_processing_status",
            "b"."raw_processing_error",
            "b"."raw_processed_at",
            "b"."normalization_status",
            "b"."normalization_error",
            "b"."inbound_n8n_execution_id",
            "b"."inbound_n8n_source_status",
            "b"."inbound_n8n_stage",
            "b"."inbound_n8n_error_node",
            "b"."inbound_n8n_error_message",
            "b"."inbound_n8n_started_at",
            "b"."inbound_n8n_finished_at",
            "b"."conversion_jobs_count",
            "b"."failed_count",
            "b"."stuck_count",
            "b"."pending_count",
            "b"."sent_count",
            "b"."skipped_count",
            "b"."dispatch_error_count",
            "b"."dispatch_not_closed_count",
            "b"."dispatch_running_count",
            "b"."dispatcher_not_started_count",
            "b"."dispatch_log_missing_count",
            "b"."prioritized_conversion_reason",
            "b"."conversion_jobs",
            "b"."dispatch_n8n_summary",
                CASE
                    WHEN (("b"."raw_processing_error" IS NOT NULL) OR ("b"."raw_processing_status" = ANY (ARRAY['client_not_found'::"text", 'error'::"text", 'failed'::"text", 'processing_error'::"text"]))) THEN 'error'::"text"
                    WHEN (("b"."raw_processing_status" = 'received'::"text") AND ("b"."received_at" >= ("clock_timestamp"() - "s"."workflow_sla"))) THEN 'processing'::"text"
                    ELSE 'ok'::"text"
                END AS "raw_audit_status",
                CASE
                    WHEN ("b"."raw_processing_error" IS NOT NULL) THEN "b"."raw_processing_error"
                    WHEN ("b"."raw_processing_status" = 'client_not_found'::"text") THEN 'Cliente não identificado para o location_id recebido.'::"text"
                    WHEN (("b"."raw_processing_status" = 'received'::"text") AND ("b"."received_at" >= ("clock_timestamp"() - "s"."workflow_sla"))) THEN 'Evento bruto persistido e dentro da janela operacional.'::"text"
                    ELSE 'Evento bruto persistido.'::"text"
                END AS "raw_audit_reason",
                CASE
                    WHEN ("b"."normalized_event_id" IS NOT NULL) THEN 'ok'::"text"
                    WHEN ("b"."raw_processing_status" = 'excluded_from_normalized'::"text") THEN 'not_applicable'::"text"
                    WHEN (("b"."raw_processing_error" IS NOT NULL) OR ("b"."raw_processing_status" = ANY (ARRAY['client_not_found'::"text", 'error'::"text", 'failed'::"text", 'processing_error'::"text"]))) THEN 'error'::"text"
                    WHEN ("b"."raw_processing_status" = 'normalized'::"text") THEN 'inconsistent'::"text"
                    WHEN ("b"."received_at" >= ("clock_timestamp"() - "s"."workflow_sla")) THEN 'processing'::"text"
                    ELSE 'stuck'::"text"
                END AS "normalization_audit_status",
                CASE
                    WHEN ("b"."normalized_event_id" IS NOT NULL) THEN 'Evento normalizado fisicamente registrado.'::"text"
                    WHEN ("b"."raw_processing_status" = 'excluded_from_normalized'::"text") THEN 'Evento explicitamente excluído da normalização.'::"text"
                    WHEN ("b"."raw_processing_error" IS NOT NULL) THEN "b"."raw_processing_error"
                    WHEN ("b"."raw_processing_status" = 'client_not_found'::"text") THEN 'Normalização não realizada porque o cliente não foi identificado.'::"text"
                    WHEN ("b"."raw_processing_status" = 'normalized'::"text") THEN 'O bruto está marcado como normalized, mas não existe linha física em events_normalized.'::"text"
                    WHEN ("b"."received_at" >= ("clock_timestamp"() - "s"."workflow_sla")) THEN 'Normalização ainda dentro da janela operacional.'::"text"
                    ELSE 'Não existe evento normalizado nem erro explícito acima da janela operacional.'::"text"
                END AS "normalization_audit_reason",
                CASE
                    WHEN ("b"."event_code" = ANY (ARRAY['lead'::"text", 'agendado'::"text", 'ganho'::"text"])) THEN 'applicable'::"text"
                    WHEN ("b"."event_code" = ANY (ARRAY['primeira_conversa'::"text", 'perdido'::"text"])) THEN 'not_applicable'::"text"
                    ELSE 'unknown'::"text"
                END AS "conversion_applicability",
                CASE
                    WHEN ((COALESCE("b"."conversion_jobs_count", 0) = 0) AND ("b"."event_code" = ANY (ARRAY['primeira_conversa'::"text", 'perdido'::"text"]))) THEN 'not_applicable'::"text"
                    WHEN ((COALESCE("b"."conversion_jobs_count", 0) = 0) AND ("b"."event_code" = ANY (ARRAY['lead'::"text", 'agendado'::"text", 'ganho'::"text"]))) THEN 'routing_not_recorded'::"text"
                    WHEN (COALESCE("b"."failed_count", (0)::bigint) > 0) THEN 'failed'::"text"
                    WHEN (COALESCE("b"."stuck_count", (0)::bigint) > 0) THEN 'stuck'::"text"
                    WHEN (COALESCE("b"."pending_count", (0)::bigint) > 0) THEN 'pending'::"text"
                    WHEN (COALESCE("b"."sent_count", (0)::bigint) > 0) THEN 'sent'::"text"
                    WHEN (COALESCE("b"."skipped_count", (0)::bigint) = COALESCE("b"."conversion_jobs_count", 0)) THEN 'skipped'::"text"
                    ELSE 'unknown'::"text"
                END AS "conversion_summary_status",
                CASE
                    WHEN ((COALESCE("b"."conversion_jobs_count", 0) = 0) AND ("b"."event_code" = ANY (ARRAY['primeira_conversa'::"text", 'perdido'::"text"]))) THEN 'Este evento não é aplicável para conversão pela regra atual.'::"text"
                    WHEN ((COALESCE("b"."conversion_jobs_count", 0) = 0) AND ("b"."event_code" = ANY (ARRAY['lead'::"text", 'agendado'::"text", 'ganho'::"text"]))) THEN 'Nenhuma decisão de conversão foi registrada.'::"text"
                    WHEN ("b"."prioritized_conversion_reason" IS NOT NULL) THEN "b"."prioritized_conversion_reason"
                    WHEN (COALESCE("b"."stuck_count", (0)::bigint) > 0) THEN 'Existe job pendente acima da janela operacional.'::"text"
                    WHEN (COALESCE("b"."pending_count", (0)::bigint) > 0) THEN 'Existe job dentro da fila de processamento.'::"text"
                    WHEN (COALESCE("b"."sent_count", (0)::bigint) > 0) THEN 'Ao menos um job foi enviado.'::"text"
                    WHEN (COALESCE("b"."skipped_count", (0)::bigint) > 0) THEN 'Os jobs foram explicitamente marcados como não enviados.'::"text"
                    ELSE NULL::"text"
                END AS "conversion_summary_reason",
                CASE
                    WHEN ("b"."inbound_n8n_execution_id" IS NULL) THEN 'workflow_log_missing'::"text"
                    WHEN (("b"."inbound_n8n_source_status" = 'error'::"text") OR ("b"."inbound_n8n_error_message" IS NOT NULL)) THEN 'error'::"text"
                    WHEN (("b"."inbound_n8n_source_status" = 'running'::"text") AND ("b"."inbound_n8n_started_at" < ("clock_timestamp"() - "s"."workflow_sla"))) THEN 'not_closed'::"text"
                    WHEN ("b"."inbound_n8n_source_status" = 'running'::"text") THEN 'running'::"text"
                    WHEN ("b"."inbound_n8n_source_status" = ANY (ARRAY['success'::"text", 'skipped'::"text"])) THEN 'ok'::"text"
                    WHEN ("b"."inbound_n8n_source_status" = 'partial'::"text") THEN 'error'::"text"
                    ELSE 'workflow_log_missing'::"text"
                END AS "inbound_n8n_status",
                CASE
                    WHEN (COALESCE("b"."conversion_jobs_count", 0) = 0) THEN NULL::"text"
                    WHEN (COALESCE("b"."dispatch_error_count", (0)::bigint) > 0) THEN 'error'::"text"
                    WHEN (COALESCE("b"."dispatch_not_closed_count", (0)::bigint) > 0) THEN 'not_closed'::"text"
                    WHEN (COALESCE("b"."dispatcher_not_started_count", (0)::bigint) > 0) THEN 'dispatcher_not_started'::"text"
                    WHEN (COALESCE("b"."dispatch_running_count", (0)::bigint) > 0) THEN 'running'::"text"
                    WHEN (COALESCE("b"."dispatch_log_missing_count", (0)::bigint) > 0) THEN 'workflow_log_missing'::"text"
                    ELSE 'ok'::"text"
                END AS "dispatch_n8n_status"
           FROM ("base" "b"
             CROSS JOIN "settings" "s")
        ), "finalized" AS (
         SELECT "c"."raw_event_id",
            "c"."normalized_event_id",
            "c"."client_id",
            "c"."client_name",
            "c"."client_slug",
            "c"."ghl_location_id",
            "c"."contact_id",
            "c"."full_name",
            "c"."event_code",
            "c"."event_datetime",
            "c"."received_at",
            "c"."raw_processing_status",
            "c"."raw_processing_error",
            "c"."raw_processed_at",
            "c"."normalization_status",
            "c"."normalization_error",
            "c"."inbound_n8n_execution_id",
            "c"."inbound_n8n_source_status",
            "c"."inbound_n8n_stage",
            "c"."inbound_n8n_error_node",
            "c"."inbound_n8n_error_message",
            "c"."inbound_n8n_started_at",
            "c"."inbound_n8n_finished_at",
            "c"."conversion_jobs_count",
            "c"."failed_count",
            "c"."stuck_count",
            "c"."pending_count",
            "c"."sent_count",
            "c"."skipped_count",
            "c"."dispatch_error_count",
            "c"."dispatch_not_closed_count",
            "c"."dispatch_running_count",
            "c"."dispatcher_not_started_count",
            "c"."dispatch_log_missing_count",
            "c"."prioritized_conversion_reason",
            "c"."conversion_jobs",
            "c"."dispatch_n8n_summary",
            "c"."raw_audit_status",
            "c"."raw_audit_reason",
            "c"."normalization_audit_status",
            "c"."normalization_audit_reason",
            "c"."conversion_applicability",
            "c"."conversion_summary_status",
            "c"."conversion_summary_reason",
            "c"."inbound_n8n_status",
            "c"."dispatch_n8n_status",
                CASE
                    WHEN (("c"."raw_audit_status" = 'error'::"text") OR ("c"."inbound_n8n_status" = 'error'::"text") OR ("c"."dispatch_n8n_status" = 'error'::"text") OR ("c"."conversion_summary_status" = 'failed'::"text") OR ("c"."normalization_audit_status" = 'error'::"text")) THEN 'error'::"text"
                    WHEN ("c"."normalization_audit_status" = 'inconsistent'::"text") THEN 'inconsistent'::"text"
                    WHEN (("c"."normalization_audit_status" = 'stuck'::"text") OR ("c"."conversion_summary_status" = ANY (ARRAY['stuck'::"text", 'routing_not_recorded'::"text"])) OR ("c"."inbound_n8n_status" = ANY (ARRAY['not_closed'::"text", 'workflow_log_missing'::"text"])) OR ("c"."dispatch_n8n_status" = ANY (ARRAY['not_closed'::"text", 'workflow_log_missing'::"text", 'dispatcher_not_started'::"text"]))) THEN 'warning'::"text"
                    WHEN (("c"."raw_audit_status" = 'processing'::"text") OR ("c"."normalization_audit_status" = 'processing'::"text") OR ("c"."conversion_summary_status" = 'pending'::"text") OR ("c"."inbound_n8n_status" = 'running'::"text") OR ("c"."dispatch_n8n_status" = 'running'::"text")) THEN 'processing'::"text"
                    ELSE 'ok'::"text"
                END AS "overall_status",
                CASE
                    WHEN ("c"."raw_audit_status" = 'error'::"text") THEN "c"."raw_audit_reason"
                    WHEN ("c"."inbound_n8n_status" = 'error'::"text") THEN COALESCE("c"."inbound_n8n_error_message", 'Erro técnico explícito no workflow de entrada.'::"text")
                    WHEN ("c"."dispatch_n8n_status" = 'error'::"text") THEN 'Existe erro técnico explícito em um dispatcher.'::"text"
                    WHEN ("c"."conversion_summary_status" = 'failed'::"text") THEN COALESCE("c"."conversion_summary_reason", 'Falha registrada pela plataforma de conversão.'::"text")
                    WHEN ("c"."normalization_audit_status" = ANY (ARRAY['error'::"text", 'inconsistent'::"text", 'stuck'::"text"])) THEN "c"."normalization_audit_reason"
                    WHEN ("c"."conversion_summary_status" = ANY (ARRAY['stuck'::"text", 'routing_not_recorded'::"text"])) THEN "c"."conversion_summary_reason"
                    WHEN ("c"."dispatch_n8n_status" = 'dispatcher_not_started'::"text") THEN 'O job de conversão foi criado, mas não foi encontrada execução correspondente do dispatcher.'::"text"
                    WHEN ("c"."dispatch_n8n_status" = 'not_closed'::"text") THEN 'O dispatcher possui log sem encerramento acima da janela operacional.'::"text"
                    WHEN ("c"."inbound_n8n_status" = 'not_closed'::"text") THEN 'O workflow de entrada possui log sem encerramento acima da janela operacional.'::"text"
                    WHEN ("c"."inbound_n8n_status" = 'workflow_log_missing'::"text") THEN 'Não foi encontrado log correlacionado do workflow de entrada.'::"text"
                    WHEN (("c"."raw_audit_status" = 'processing'::"text") OR ("c"."normalization_audit_status" = 'processing'::"text")) THEN 'Evento dentro da janela operacional.'::"text"
                    WHEN ("c"."conversion_summary_status" = 'pending'::"text") THEN "c"."conversion_summary_reason"
                    ELSE 'Jornada sem problema operacional explícito nas evidências registradas.'::"text"
                END AS "overall_reason"
           FROM "classified" "c"
        )
 SELECT "raw_event_id",
    "normalized_event_id",
    "client_id",
    "client_name",
    "client_slug",
    "ghl_location_id",
    "contact_id",
    "full_name",
    "event_code",
    "event_datetime",
    "received_at",
    "raw_processing_status",
    "raw_processing_error",
    "raw_processed_at",
    "raw_audit_status",
    "raw_audit_reason",
    "normalization_status",
    "normalization_error",
    "normalization_audit_status",
    "normalization_audit_reason",
    "conversion_applicability",
    COALESCE("conversion_jobs_count", 0) AS "conversion_jobs_count",
    "conversion_summary_status",
    "conversion_summary_reason",
    COALESCE("conversion_jobs", '[]'::"jsonb") AS "conversion_jobs",
    "inbound_n8n_execution_id",
    "inbound_n8n_source_status",
    "inbound_n8n_status",
    "inbound_n8n_stage",
    "inbound_n8n_error_node",
    "inbound_n8n_error_message",
    "inbound_n8n_started_at",
    "inbound_n8n_finished_at",
    "dispatch_n8n_status",
    COALESCE("dispatch_n8n_summary", '[]'::"jsonb") AS "dispatch_n8n_summary",
    "overall_status",
    "overall_reason"
   FROM "finalized" "f"
  WHERE ((("client_id" IS NOT NULL) AND "private"."user_can_access_client"("client_id")) OR (("client_id" IS NULL) AND "private"."is_agency_user"()));


ALTER VIEW "public"."v_event_tracking_audit" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_event_tracking_audit" IS 'CANONICAL: uma linha por events_raw.id. Consolida bruto, normalização, conversões e logs n8n. SLA workflow 2h; pending 24h. Prioridade de logs: erro explícito, mais recente, encerrado, id mais recente. Sem payloads sensíveis.';



CREATE OR REPLACE VIEW "public"."v_google_ads_keywords_daily" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "google_ads_customer_id",
    "date",
    "campaign_id",
    "campaign_name",
    "ad_group_id",
    "ad_group_name",
    "keyword_id",
    "keyword_text",
    "keyword_match_type",
    "keyword_status",
    "impressions",
    "clicks",
    "cost",
    "cost_micros",
    "conversions",
    "conversions_value",
    "ctr_percent",
    "cpc",
    "cost_per_conversion",
    "synced_at",
    "updated_at"
   FROM ( SELECT "g"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "g"."google_ads_customer_id",
            "g"."date",
            "g"."campaign_id",
            "g"."campaign_name",
            "g"."ad_group_id",
            "g"."ad_group_name",
            "g"."keyword_id",
            "g"."keyword_text",
            "g"."keyword_match_type",
            "g"."keyword_status",
            "g"."impressions",
            "g"."clicks",
            "g"."cost",
            "g"."cost_micros",
            "g"."conversions",
            "g"."conversions_value",
                CASE
                    WHEN ("g"."impressions" > 0) THEN "round"(((("g"."clicks")::numeric / ("g"."impressions")::numeric) * (100)::numeric), 2)
                    ELSE (0)::numeric
                END AS "ctr_percent",
                CASE
                    WHEN ("g"."clicks" > 0) THEN "round"(("g"."cost" / ("g"."clicks")::numeric), 2)
                    ELSE (0)::numeric
                END AS "cpc",
                CASE
                    WHEN ("g"."conversions" > (0)::numeric) THEN "round"(("g"."cost" / "g"."conversions"), 2)
                    ELSE (0)::numeric
                END AS "cost_per_conversion",
            "g"."synced_at",
            "g"."updated_at"
           FROM ("public"."google_ads_keywords_daily" "g"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "g"."client_id")))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_google_ads_keywords_daily" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_google_ads_keywords_daily" IS 'DEPRECATED: usar v_google_keywords_v2. Mantida temporariamente para compatibilidade com o frontend antigo.';



CREATE OR REPLACE VIEW "public"."v_google_campaign_daily" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "date",
    "customer_id",
    "customer_name",
    "campaign_id",
    "campaign_name",
    "spend",
    "impressions",
    "clicks",
    "google_conversions",
    "crm_leads",
    "crm_agendados"
   FROM ( WITH "midia" AS (
                 SELECT "g"."client_id",
                    "g"."date",
                    "g"."customer_id",
                    "g"."customer_name",
                    "g"."campaign_id",
                    "g"."campaign_name",
                    "sum"("g"."cost") AS "spend",
                    "sum"("g"."impressions") AS "impressions",
                    "sum"("g"."clicks") AS "clicks",
                    "sum"(COALESCE("g"."conversions", (0)::numeric)) AS "google_conversions"
                   FROM "public"."google_ads_daily" "g"
                  GROUP BY "g"."client_id", "g"."date", "g"."customer_id", "g"."customer_name", "g"."campaign_id", "g"."campaign_name"
                ), "leads" AS (
                 SELECT "e"."client_id",
                    "e"."event_date" AS "date",
                    "e"."google_campaign_id",
                    "e"."contact_id"
                   FROM "public"."v_crm_events_enriched" "e"
                  WHERE (("e"."google_campaign_id" IS NOT NULL) AND ("e"."event_code" = 'lead'::"text"))
                ), "crm" AS (
                 SELECT "l"."client_id",
                    "l"."date",
                    "l"."google_campaign_id",
                    "count"(*) AS "crm_leads",
                    "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
                           FROM "public"."v_crm_events_enriched" "e2"
                          WHERE (("e2"."contact_id" = "l"."contact_id") AND ("e2"."client_id" = "l"."client_id") AND ("e2"."event_code" = 'agendado'::"text"))))) AS "crm_agendados"
                   FROM "leads" "l"
                  GROUP BY "l"."client_id", "l"."date", "l"."google_campaign_id"
                )
         SELECT "mid"."client_id",
            "mid"."date",
            "mid"."customer_id",
            "mid"."customer_name",
            "mid"."campaign_id",
            "mid"."campaign_name",
            "mid"."spend",
            "mid"."impressions",
            "mid"."clicks",
            "mid"."google_conversions",
            COALESCE("c"."crm_leads", (0)::bigint) AS "crm_leads",
            COALESCE("c"."crm_agendados", (0)::bigint) AS "crm_agendados"
           FROM ("midia" "mid"
             LEFT JOIN "crm" "c" ON ((("c"."client_id" = "mid"."client_id") AND ("c"."google_campaign_id" = "mid"."campaign_id") AND ("c"."date" = "mid"."date"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_google_campaign_daily" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_google_campaign_daily" IS 'DEPRECATED: usar v_google_ads_v2. Mantida temporariamente para compatibilidade com o frontend antigo. security_invoker=true aplicado em 2026-07-23 para herdar RLS das tabelas base.';



CREATE OR REPLACE VIEW "public"."v_google_campaign_performance" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "account_id",
    "account_name",
    "campaign_id",
    "campaign_name",
    "spend",
    "impressions",
    "clicks",
    "crm_leads",
    "crm_primeiras_conversas",
    "crm_agendados",
    "crm_ganhos",
    "crm_perdidos",
    "receita",
    "cpl_real",
    "custo_por_agendado",
    "cac",
    "roas_real"
   FROM ( WITH "ads" AS (
                 SELECT "gd"."client_id",
                    "cb"."client_name",
                    "cb"."client_slug",
                    "gd"."customer_id" AS "account_id",
                    "gd"."customer_name" AS "account_name",
                    "gd"."campaign_id",
                    "gd"."campaign_name",
                    "sum"(COALESCE("gd"."cost", (0)::numeric)) AS "spend",
                    "sum"(COALESCE("gd"."impressions", 0)) AS "impressions",
                    "sum"(COALESCE("gd"."clicks", 0)) AS "clicks"
                   FROM ("public"."google_ads_daily" "gd"
                     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "gd"."client_id")))
                  GROUP BY "gd"."client_id", "cb"."client_name", "cb"."client_slug", "gd"."customer_id", "gd"."customer_name", "gd"."campaign_id", "gd"."campaign_name"
                ), "crm_leads" AS (
                 SELECT "v_crm_events_enriched"."client_id",
                    "v_crm_events_enriched"."google_campaign_id",
                    "count"(*) AS "crm_leads"
                   FROM "public"."v_crm_events_enriched"
                  WHERE (("v_crm_events_enriched"."event_code" = 'lead'::"text") AND ("v_crm_events_enriched"."google_campaign_id" IS NOT NULL))
                  GROUP BY "v_crm_events_enriched"."client_id", "v_crm_events_enriched"."google_campaign_id"
                ), "crm_opps" AS (
                 SELECT "v_crm_opportunities"."client_id",
                    "v_crm_opportunities"."google_campaign_id",
                    "count"(*) FILTER (WHERE ("v_crm_opportunities"."primeira_conversa_date" IS NOT NULL)) AS "crm_primeiras_conversas",
                    "count"(*) FILTER (WHERE ("v_crm_opportunities"."agendado_date" IS NOT NULL)) AS "crm_agendados",
                    "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_won" = true) AND ("v_crm_opportunities"."ganho_date" IS NOT NULL))) AS "crm_ganhos",
                    "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_lost" = true) AND ("v_crm_opportunities"."is_won" = false) AND ("v_crm_opportunities"."perdido_date" IS NOT NULL))) AS "crm_perdidos",
                    COALESCE("sum"("v_crm_opportunities"."valor_ganho_final") FILTER (WHERE ("v_crm_opportunities"."is_won" = true)), (0)::numeric) AS "receita"
                   FROM "public"."v_crm_opportunities"
                  WHERE ("v_crm_opportunities"."google_campaign_id" IS NOT NULL)
                  GROUP BY "v_crm_opportunities"."client_id", "v_crm_opportunities"."google_campaign_id"
                )
         SELECT "a"."client_id",
            "a"."client_name",
            "a"."client_slug",
            "a"."account_id",
            "a"."account_name",
            "a"."campaign_id",
            "a"."campaign_name",
            "a"."spend",
            "a"."impressions",
            "a"."clicks",
            COALESCE("l"."crm_leads", (0)::bigint) AS "crm_leads",
            COALESCE("o"."crm_primeiras_conversas", (0)::bigint) AS "crm_primeiras_conversas",
            COALESCE("o"."crm_agendados", (0)::bigint) AS "crm_agendados",
            COALESCE("o"."crm_ganhos", (0)::bigint) AS "crm_ganhos",
            COALESCE("o"."crm_perdidos", (0)::bigint) AS "crm_perdidos",
            COALESCE("o"."receita", (0)::numeric) AS "receita",
                CASE
                    WHEN (COALESCE("l"."crm_leads", (0)::bigint) > 0) THEN ("a"."spend" / ("l"."crm_leads")::numeric)
                    ELSE NULL::numeric
                END AS "cpl_real",
                CASE
                    WHEN (COALESCE("o"."crm_agendados", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_agendados")::numeric)
                    ELSE NULL::numeric
                END AS "custo_por_agendado",
                CASE
                    WHEN (COALESCE("o"."crm_ganhos", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_ganhos")::numeric)
                    ELSE NULL::numeric
                END AS "cac",
                CASE
                    WHEN ("a"."spend" > (0)::numeric) THEN (COALESCE("o"."receita", (0)::numeric) / "a"."spend")
                    ELSE NULL::numeric
                END AS "roas_real"
           FROM (("ads" "a"
             LEFT JOIN "crm_leads" "l" ON ((("l"."client_id" = "a"."client_id") AND ("l"."google_campaign_id" = "a"."campaign_id"))))
             LEFT JOIN "crm_opps" "o" ON ((("o"."client_id" = "a"."client_id") AND ("o"."google_campaign_id" = "a"."campaign_id"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_google_campaign_performance" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_google_campaign_performance" IS 'DEPRECATED: mistura mídia e CRM com metodologia antiga. Não usar em novas implementações.';



CREATE OR REPLACE VIEW "public"."v_google_keywords_v2" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "id",
    "client_id",
    "client_name",
    "client_slug",
    "google_ads_customer_id",
    "date",
    "campaign_id",
    "campaign_name",
    "ad_group_id",
    "ad_group_name",
    "keyword_id",
    "keyword_text",
    "keyword_match_type",
    "keyword_status",
    "impressions",
    "clicks",
    "cost_micros",
    "cost",
    "ctr",
    "average_cpc_micros",
    "average_cpc",
    "conversions",
    "conversions_value",
    "synced_at",
    "created_at",
    "updated_at"
   FROM ( SELECT "gk"."id",
            "gk"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "gk"."google_ads_customer_id",
            "gk"."date",
            "gk"."campaign_id",
            "gk"."campaign_name",
            "gk"."ad_group_id",
            "gk"."ad_group_name",
            "gk"."keyword_id",
            "gk"."keyword_text",
            "gk"."keyword_match_type",
            "gk"."keyword_status",
            "gk"."impressions",
            "gk"."clicks",
            "gk"."cost_micros",
            "gk"."cost",
            "gk"."ctr",
            "gk"."average_cpc_micros",
            "gk"."average_cpc",
            "gk"."conversions",
            "gk"."conversions_value",
            "gk"."synced_at",
            "gk"."created_at",
            "gk"."updated_at"
           FROM ("public"."google_ads_keywords_daily" "gk"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "gk"."client_id")))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_google_keywords_v2" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_google_keywords_v2" IS 'CANONICAL: fonte Google Ads por palavra-chave e dia.';



CREATE OR REPLACE VIEW "public"."v_meta_account_daily" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "date",
    "account_id",
    "account_name",
    "spend",
    "impressions",
    "clicks",
    "meta_conversions",
    "crm_leads",
    "crm_agendados"
   FROM ( WITH "midia" AS (
                 SELECT "m"."client_id",
                    "m"."date",
                    "m"."account_id",
                    "m"."account_name",
                    "sum"("m"."spend") AS "spend",
                    "sum"("m"."impressions") AS "impressions",
                    "sum"("m"."clicks") AS "clicks",
                    "sum"(COALESCE("m"."meta_platform_conversions", (0)::numeric)) AS "meta_conversions"
                   FROM "public"."meta_ads_daily" "m"
                  GROUP BY "m"."client_id", "m"."date", "m"."account_id", "m"."account_name"
                ), "ad_para_conta" AS (
                 SELECT DISTINCT "m"."client_id",
                    "m"."ad_id",
                    "m"."account_id"
                   FROM "public"."meta_ads_daily" "m"
                ), "leads" AS (
                 SELECT "e"."client_id",
                    "e"."event_date" AS "date",
                    "a"."account_id",
                    "e"."contact_id"
                   FROM ("public"."v_crm_events_enriched" "e"
                     JOIN "ad_para_conta" "a" ON ((("a"."client_id" = "e"."client_id") AND ("a"."ad_id" = "e"."meta_ad_id"))))
                  WHERE (("e"."meta_ad_id" IS NOT NULL) AND ("e"."event_code" = 'lead'::"text"))
                ), "crm" AS (
                 SELECT "l"."client_id",
                    "l"."date",
                    "l"."account_id",
                    "count"(*) AS "crm_leads",
                    "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
                           FROM "public"."v_crm_events_enriched" "e2"
                          WHERE (("e2"."contact_id" = "l"."contact_id") AND ("e2"."client_id" = "l"."client_id") AND ("e2"."event_code" = 'agendado'::"text"))))) AS "crm_agendados"
                   FROM "leads" "l"
                  GROUP BY "l"."client_id", "l"."date", "l"."account_id"
                )
         SELECT "mid"."client_id",
            "mid"."date",
            "mid"."account_id",
            "mid"."account_name",
            "mid"."spend",
            "mid"."impressions",
            "mid"."clicks",
            "mid"."meta_conversions",
            COALESCE("c"."crm_leads", (0)::bigint) AS "crm_leads",
            COALESCE("c"."crm_agendados", (0)::bigint) AS "crm_agendados"
           FROM ("midia" "mid"
             LEFT JOIN "crm" "c" ON ((("c"."client_id" = "mid"."client_id") AND ("c"."account_id" = "mid"."account_id") AND ("c"."date" = "mid"."date"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_meta_account_daily" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_meta_account_daily" IS 'DEPRECATED: usar v_meta_ads_v2. Mantida temporariamente para compatibilidade com o frontend antigo. security_invoker=true aplicado em 2026-07-23 para herdar RLS das tabelas base.';



CREATE OR REPLACE VIEW "public"."v_meta_campaign_daily" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "date",
    "account_id",
    "account_name",
    "campaign_id",
    "campaign_name",
    "spend",
    "impressions",
    "clicks",
    "meta_conversions",
    "crm_leads",
    "crm_agendados"
   FROM ( WITH "midia" AS (
                 SELECT "m"."client_id",
                    "m"."date",
                    "m"."account_id",
                    "m"."account_name",
                    "m"."campaign_id",
                    "m"."campaign_name",
                    "sum"("m"."spend") AS "spend",
                    "sum"("m"."impressions") AS "impressions",
                    "sum"("m"."clicks") AS "clicks",
                    "sum"(COALESCE("m"."meta_platform_conversions", (0)::numeric)) AS "meta_conversions"
                   FROM "public"."meta_ads_daily" "m"
                  GROUP BY "m"."client_id", "m"."date", "m"."account_id", "m"."account_name", "m"."campaign_id", "m"."campaign_name"
                ), "ad_para_campanha" AS (
                 SELECT DISTINCT "m"."client_id",
                    "m"."ad_id",
                    "m"."campaign_id"
                   FROM "public"."meta_ads_daily" "m"
                ), "leads" AS (
                 SELECT "e"."client_id",
                    "e"."event_date" AS "date",
                    "a"."campaign_id",
                    "e"."contact_id"
                   FROM ("public"."v_crm_events_enriched" "e"
                     JOIN "ad_para_campanha" "a" ON ((("a"."client_id" = "e"."client_id") AND ("a"."ad_id" = "e"."meta_ad_id"))))
                  WHERE (("e"."meta_ad_id" IS NOT NULL) AND ("e"."event_code" = 'lead'::"text"))
                ), "crm" AS (
                 SELECT "l"."client_id",
                    "l"."date",
                    "l"."campaign_id",
                    "count"(*) AS "crm_leads",
                    "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
                           FROM "public"."v_crm_events_enriched" "e2"
                          WHERE (("e2"."contact_id" = "l"."contact_id") AND ("e2"."client_id" = "l"."client_id") AND ("e2"."event_code" = 'agendado'::"text"))))) AS "crm_agendados"
                   FROM "leads" "l"
                  GROUP BY "l"."client_id", "l"."date", "l"."campaign_id"
                )
         SELECT "mid"."client_id",
            "mid"."date",
            "mid"."account_id",
            "mid"."account_name",
            "mid"."campaign_id",
            "mid"."campaign_name",
            "mid"."spend",
            "mid"."impressions",
            "mid"."clicks",
            "mid"."meta_conversions",
            COALESCE("c"."crm_leads", (0)::bigint) AS "crm_leads",
            COALESCE("c"."crm_agendados", (0)::bigint) AS "crm_agendados"
           FROM ("midia" "mid"
             LEFT JOIN "crm" "c" ON ((("c"."client_id" = "mid"."client_id") AND ("c"."campaign_id" = "mid"."campaign_id") AND ("c"."date" = "mid"."date"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_meta_campaign_daily" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_meta_campaign_daily" IS 'DEPRECATED: usar v_meta_ads_v2. Mantida temporariamente para compatibilidade com o frontend antigo. security_invoker=true aplicado em 2026-07-23 para herdar RLS das tabelas base.';



CREATE OR REPLACE VIEW "public"."v_meta_campaign_performance" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "account_id",
    "campaign_id",
    "campaign_name",
    "adset_id",
    "adset_name",
    "ad_id",
    "ad_name",
    "spend",
    "impressions",
    "clicks",
    "crm_leads",
    "crm_primeiras_conversas",
    "crm_agendados",
    "crm_ganhos",
    "crm_perdidos",
    "receita",
    "cpl_real",
    "custo_por_agendado",
    "cac",
    "roas_real"
   FROM ( WITH "ads" AS (
                 SELECT "v_ads_spend_daily"."client_id",
                    "v_ads_spend_daily"."client_name",
                    "v_ads_spend_daily"."client_slug",
                    "v_ads_spend_daily"."account_id",
                    "v_ads_spend_daily"."campaign_id",
                    "v_ads_spend_daily"."campaign_name",
                    "v_ads_spend_daily"."ad_group_id" AS "adset_id",
                    "v_ads_spend_daily"."ad_group_name" AS "adset_name",
                    "v_ads_spend_daily"."ad_id",
                    "v_ads_spend_daily"."ad_name",
                    "sum"("v_ads_spend_daily"."spend") AS "spend",
                    "sum"("v_ads_spend_daily"."impressions") AS "impressions",
                    "sum"("v_ads_spend_daily"."clicks") AS "clicks"
                   FROM "public"."v_ads_spend_daily"
                  WHERE ("v_ads_spend_daily"."platform" = 'meta_ads'::"text")
                  GROUP BY "v_ads_spend_daily"."client_id", "v_ads_spend_daily"."client_name", "v_ads_spend_daily"."client_slug", "v_ads_spend_daily"."account_id", "v_ads_spend_daily"."campaign_id", "v_ads_spend_daily"."campaign_name", "v_ads_spend_daily"."ad_group_id", "v_ads_spend_daily"."ad_group_name", "v_ads_spend_daily"."ad_id", "v_ads_spend_daily"."ad_name"
                ), "crm_leads" AS (
                 SELECT "v_crm_events_enriched"."client_id",
                    "v_crm_events_enriched"."meta_ad_id" AS "ad_id",
                    "count"(*) AS "crm_leads"
                   FROM "public"."v_crm_events_enriched"
                  WHERE (("v_crm_events_enriched"."event_code" = 'lead'::"text") AND ("v_crm_events_enriched"."meta_ad_id" IS NOT NULL))
                  GROUP BY "v_crm_events_enriched"."client_id", "v_crm_events_enriched"."meta_ad_id"
                ), "crm_opps" AS (
                 SELECT "v_crm_opportunities"."client_id",
                    "v_crm_opportunities"."meta_ad_id" AS "ad_id",
                    "count"(*) FILTER (WHERE ("v_crm_opportunities"."primeira_conversa_date" IS NOT NULL)) AS "crm_primeiras_conversas",
                    "count"(*) FILTER (WHERE ("v_crm_opportunities"."agendado_date" IS NOT NULL)) AS "crm_agendados",
                    "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_won" = true) AND ("v_crm_opportunities"."ganho_date" IS NOT NULL))) AS "crm_ganhos",
                    "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_lost" = true) AND ("v_crm_opportunities"."is_won" = false) AND ("v_crm_opportunities"."perdido_date" IS NOT NULL))) AS "crm_perdidos",
                    COALESCE("sum"("v_crm_opportunities"."valor_ganho_final") FILTER (WHERE ("v_crm_opportunities"."is_won" = true)), (0)::numeric) AS "receita"
                   FROM "public"."v_crm_opportunities"
                  WHERE ("v_crm_opportunities"."meta_ad_id" IS NOT NULL)
                  GROUP BY "v_crm_opportunities"."client_id", "v_crm_opportunities"."meta_ad_id"
                )
         SELECT "a"."client_id",
            "a"."client_name",
            "a"."client_slug",
            "a"."account_id",
            "a"."campaign_id",
            "a"."campaign_name",
            "a"."adset_id",
            "a"."adset_name",
            "a"."ad_id",
            "a"."ad_name",
            "a"."spend",
            "a"."impressions",
            "a"."clicks",
            COALESCE("l"."crm_leads", (0)::bigint) AS "crm_leads",
            COALESCE("o"."crm_primeiras_conversas", (0)::bigint) AS "crm_primeiras_conversas",
            COALESCE("o"."crm_agendados", (0)::bigint) AS "crm_agendados",
            COALESCE("o"."crm_ganhos", (0)::bigint) AS "crm_ganhos",
            COALESCE("o"."crm_perdidos", (0)::bigint) AS "crm_perdidos",
            COALESCE("o"."receita", (0)::numeric) AS "receita",
                CASE
                    WHEN (COALESCE("l"."crm_leads", (0)::bigint) > 0) THEN ("a"."spend" / ("l"."crm_leads")::numeric)
                    ELSE NULL::numeric
                END AS "cpl_real",
                CASE
                    WHEN (COALESCE("o"."crm_agendados", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_agendados")::numeric)
                    ELSE NULL::numeric
                END AS "custo_por_agendado",
                CASE
                    WHEN (COALESCE("o"."crm_ganhos", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_ganhos")::numeric)
                    ELSE NULL::numeric
                END AS "cac",
                CASE
                    WHEN ("a"."spend" > (0)::numeric) THEN (COALESCE("o"."receita", (0)::numeric) / "a"."spend")
                    ELSE NULL::numeric
                END AS "roas_real"
           FROM (("ads" "a"
             LEFT JOIN "crm_leads" "l" ON ((("l"."client_id" = "a"."client_id") AND ("l"."ad_id" = "a"."ad_id"))))
             LEFT JOIN "crm_opps" "o" ON ((("o"."client_id" = "a"."client_id") AND ("o"."ad_id" = "a"."ad_id"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_meta_campaign_performance" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_meta_campaign_performance" IS 'DEPRECATED: mistura mídia e CRM com metodologia antiga. Não usar em novas implementações.';



CREATE OR REPLACE VIEW "public"."v_meta_creative_daily" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "date",
    "account_id",
    "campaign_id",
    "campaign_name",
    "adset_id",
    "adset_name",
    "ad_id",
    "ad_name",
    "creative_id",
    "creative_name",
    "thumbnail_url",
    "image_url",
    "creative_url",
    "video_id",
    "headline",
    "primary_text",
    "spend",
    "impressions",
    "clicks",
    "meta_conversions",
    "crm_leads",
    "crm_agendados",
    "crm_ganhos",
    "receita"
   FROM ( WITH "midia" AS (
                 SELECT "m"."client_id",
                    "m"."date",
                    "m"."account_id",
                    "m"."campaign_id",
                    "m"."campaign_name",
                    "m"."adset_id",
                    "m"."adset_name",
                    "m"."ad_id",
                    "m"."ad_name",
                    "m"."creative_id",
                    "m"."creative_name",
                    "m"."thumbnail_url",
                    "m"."image_url",
                    "m"."creative_url",
                    "m"."video_id",
                    "m"."headline",
                    "m"."primary_text",
                    "m"."spend",
                    "m"."impressions",
                    "m"."clicks",
                    COALESCE("m"."meta_platform_conversions", (0)::numeric) AS "meta_conversions"
                   FROM "public"."meta_ads_daily" "m"
                ), "crm" AS (
                 SELECT "e"."client_id",
                    "e"."event_date" AS "date",
                    "e"."meta_ad_id" AS "ad_id",
                    "count"(*) FILTER (WHERE ("e"."event_code" = 'lead'::"text")) AS "crm_leads",
                    "count"(*) FILTER (WHERE ("e"."event_code" = 'agendado'::"text")) AS "crm_agendados",
                    "count"(*) FILTER (WHERE (("e"."event_code" = 'ganho'::"text") OR ("e"."status" = 'won'::"text"))) AS "crm_ganhos",
                    COALESCE("sum"("e"."valor_ganho") FILTER (WHERE (("e"."event_code" = 'ganho'::"text") OR ("e"."status" = 'won'::"text"))), (0)::numeric) AS "receita"
                   FROM "public"."v_crm_events_enriched" "e"
                  WHERE ("e"."meta_ad_id" IS NOT NULL)
                  GROUP BY "e"."client_id", "e"."event_date", "e"."meta_ad_id"
                )
         SELECT "mid"."client_id",
            "mid"."date",
            "mid"."account_id",
            "mid"."campaign_id",
            "mid"."campaign_name",
            "mid"."adset_id",
            "mid"."adset_name",
            "mid"."ad_id",
            "mid"."ad_name",
            "mid"."creative_id",
            "mid"."creative_name",
            "mid"."thumbnail_url",
            "mid"."image_url",
            "mid"."creative_url",
            "mid"."video_id",
            "mid"."headline",
            "mid"."primary_text",
            "mid"."spend",
            "mid"."impressions",
            "mid"."clicks",
            "mid"."meta_conversions",
            COALESCE("c"."crm_leads", (0)::bigint) AS "crm_leads",
            COALESCE("c"."crm_agendados", (0)::bigint) AS "crm_agendados",
            COALESCE("c"."crm_ganhos", (0)::bigint) AS "crm_ganhos",
            COALESCE("c"."receita", (0)::numeric) AS "receita"
           FROM ("midia" "mid"
             LEFT JOIN "crm" "c" ON ((("c"."client_id" = "mid"."client_id") AND ("c"."ad_id" = "mid"."ad_id") AND ("c"."date" = "mid"."date"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_meta_creative_daily" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_meta_creative_daily" IS 'DEPRECATED: usar v_meta_ads_v2. Mantida temporariamente para compatibilidade com o frontend antigo.';



CREATE OR REPLACE VIEW "public"."v_meta_creative_performance" WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "client_id",
    "client_name",
    "client_slug",
    "account_id",
    "campaign_id",
    "campaign_name",
    "adset_id",
    "adset_name",
    "ad_id",
    "ad_name",
    "creative_id",
    "creative_name",
    "thumbnail_url",
    "image_url",
    "creative_url",
    "destination_url",
    "primary_text",
    "headline",
    "video_id",
    "spend",
    "impressions",
    "clicks",
    "inline_link_clicks",
    "crm_leads",
    "crm_primeiras_conversas",
    "crm_agendados",
    "crm_ganhos",
    "crm_perdidos",
    "receita",
    "cpl_real",
    "custo_por_agendado",
    "cac",
    "roas_real"
   FROM ( WITH "ads" AS (
                 SELECT "md"."client_id",
                    "cb"."client_name",
                    "cb"."client_slug",
                    "md"."account_id",
                    "md"."campaign_id",
                    "md"."campaign_name",
                    "md"."adset_id",
                    "md"."adset_name",
                    "md"."ad_id",
                    "md"."ad_name",
                    "md"."creative_id",
                    "max"("md"."creative_name") AS "creative_name",
                    "max"("md"."thumbnail_url") AS "thumbnail_url",
                    "max"("md"."image_url") AS "image_url",
                    "max"("md"."creative_url") AS "creative_url",
                    "max"("md"."destination_url") AS "destination_url",
                    "max"("md"."primary_text") AS "primary_text",
                    "max"("md"."headline") AS "headline",
                    "max"("md"."video_id") AS "video_id",
                    "sum"(COALESCE("md"."spend", (0)::numeric)) AS "spend",
                    "sum"(COALESCE("md"."impressions", 0)) AS "impressions",
                    "sum"(COALESCE("md"."clicks", 0)) AS "clicks",
                    "sum"(COALESCE("md"."inline_link_clicks", 0)) AS "inline_link_clicks"
                   FROM ("public"."meta_ads_daily" "md"
                     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "md"."client_id")))
                  GROUP BY "md"."client_id", "cb"."client_name", "cb"."client_slug", "md"."account_id", "md"."campaign_id", "md"."campaign_name", "md"."adset_id", "md"."adset_name", "md"."ad_id", "md"."ad_name", "md"."creative_id"
                ), "crm_leads" AS (
                 SELECT "v_crm_events_enriched"."client_id",
                    "v_crm_events_enriched"."meta_ad_id" AS "ad_id",
                    "count"(*) AS "crm_leads"
                   FROM "public"."v_crm_events_enriched"
                  WHERE (("v_crm_events_enriched"."event_code" = 'lead'::"text") AND ("v_crm_events_enriched"."meta_ad_id" IS NOT NULL))
                  GROUP BY "v_crm_events_enriched"."client_id", "v_crm_events_enriched"."meta_ad_id"
                ), "crm_opps" AS (
                 SELECT "v_crm_opportunities"."client_id",
                    "v_crm_opportunities"."meta_ad_id" AS "ad_id",
                    "count"(*) FILTER (WHERE ("v_crm_opportunities"."primeira_conversa_date" IS NOT NULL)) AS "crm_primeiras_conversas",
                    "count"(*) FILTER (WHERE ("v_crm_opportunities"."agendado_date" IS NOT NULL)) AS "crm_agendados",
                    "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_won" = true) AND ("v_crm_opportunities"."ganho_date" IS NOT NULL))) AS "crm_ganhos",
                    "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_lost" = true) AND ("v_crm_opportunities"."is_won" = false) AND ("v_crm_opportunities"."perdido_date" IS NOT NULL))) AS "crm_perdidos",
                    COALESCE("sum"("v_crm_opportunities"."valor_ganho_final") FILTER (WHERE ("v_crm_opportunities"."is_won" = true)), (0)::numeric) AS "receita"
                   FROM "public"."v_crm_opportunities"
                  WHERE ("v_crm_opportunities"."meta_ad_id" IS NOT NULL)
                  GROUP BY "v_crm_opportunities"."client_id", "v_crm_opportunities"."meta_ad_id"
                )
         SELECT "a"."client_id",
            "a"."client_name",
            "a"."client_slug",
            "a"."account_id",
            "a"."campaign_id",
            "a"."campaign_name",
            "a"."adset_id",
            "a"."adset_name",
            "a"."ad_id",
            "a"."ad_name",
            "a"."creative_id",
            "a"."creative_name",
            "a"."thumbnail_url",
            "a"."image_url",
            "a"."creative_url",
            "a"."destination_url",
            "a"."primary_text",
            "a"."headline",
            "a"."video_id",
            "a"."spend",
            "a"."impressions",
            "a"."clicks",
            "a"."inline_link_clicks",
            COALESCE("l"."crm_leads", (0)::bigint) AS "crm_leads",
            COALESCE("o"."crm_primeiras_conversas", (0)::bigint) AS "crm_primeiras_conversas",
            COALESCE("o"."crm_agendados", (0)::bigint) AS "crm_agendados",
            COALESCE("o"."crm_ganhos", (0)::bigint) AS "crm_ganhos",
            COALESCE("o"."crm_perdidos", (0)::bigint) AS "crm_perdidos",
            COALESCE("o"."receita", (0)::numeric) AS "receita",
                CASE
                    WHEN (COALESCE("l"."crm_leads", (0)::bigint) > 0) THEN ("a"."spend" / ("l"."crm_leads")::numeric)
                    ELSE NULL::numeric
                END AS "cpl_real",
                CASE
                    WHEN (COALESCE("o"."crm_agendados", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_agendados")::numeric)
                    ELSE NULL::numeric
                END AS "custo_por_agendado",
                CASE
                    WHEN (COALESCE("o"."crm_ganhos", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_ganhos")::numeric)
                    ELSE NULL::numeric
                END AS "cac",
                CASE
                    WHEN ("a"."spend" > (0)::numeric) THEN (COALESCE("o"."receita", (0)::numeric) / "a"."spend")
                    ELSE NULL::numeric
                END AS "roas_real"
           FROM (("ads" "a"
             LEFT JOIN "crm_leads" "l" ON ((("l"."client_id" = "a"."client_id") AND ("l"."ad_id" = "a"."ad_id"))))
             LEFT JOIN "crm_opps" "o" ON ((("o"."client_id" = "a"."client_id") AND ("o"."ad_id" = "a"."ad_id"))))) "gated"
  WHERE ("client_id" IN ( SELECT "financial_client_ids"."client_id"
           FROM "private"."financial_client_ids"() "financial_client_ids"("client_id")));


ALTER VIEW "public"."v_meta_creative_performance" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_meta_creative_performance" IS 'DEPRECATED: mistura mídia e CRM com metodologia antiga. Não usar em novas implementações.';



CREATE OR REPLACE VIEW "public"."v_sync_health" WITH ("security_barrier"='true', "security_invoker"='false') AS
 WITH "settings" AS (
         SELECT '02:00:00'::interval AS "workflow_sla",
            '36:00:00'::interval AS "recent_write_window",
            ("date_trunc"('day'::"text", ("clock_timestamp"() AT TIME ZONE 'America/Sao_Paulo'::"text")) AT TIME ZONE 'America/Sao_Paulo'::"text") AS "today_start",
            ((("clock_timestamp"() AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" - 1) AS "expected_max_data_date"
        ), "operation_matrix" AS (
         SELECT "cb"."id" AS "client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "cb"."ghl_location_id",
            "x"."platform",
            "x"."operation_type",
            "x"."workflow_key",
                CASE
                    WHEN ("x"."platform" = 'meta'::"text") THEN COALESCE("cb"."enable_meta_ads_sync", false)
                    ELSE COALESCE("cb"."enable_google_ads_sync", false)
                END AS "is_enabled",
                CASE
                    WHEN ("x"."platform" = 'meta'::"text") THEN "cb"."meta_ads_last_sync_at"
                    ELSE "cb"."google_ads_last_sync_at"
                END AS "saved_last_sync_at",
                CASE
                    WHEN ("x"."platform" = 'meta'::"text") THEN "cb"."meta_ads_last_backfill_at"
                    ELSE "cb"."google_ads_last_backfill_at"
                END AS "saved_last_backfill_at",
                CASE
                    WHEN ("x"."platform" = 'meta'::"text") THEN "cb"."media_backfill_status"
                    ELSE "cb"."google_ads_backfill_status"
                END AS "saved_backfill_status",
                CASE
                    WHEN ("x"."platform" = 'meta'::"text") THEN "cb"."media_backfill_error"
                    ELSE "cb"."google_ads_backfill_error"
                END AS "saved_backfill_error"
           FROM ("public"."clients_base" "cb"
             CROSS JOIN ( VALUES ('meta'::"text",'daily'::"text",'2.1'::"text"), ('google_ads'::"text",'daily'::"text",'2.2'::"text"), ('meta'::"text",'backfill'::"text",'0.1'::"text"), ('google_ads'::"text",'backfill'::"text",'0.4'::"text")) "x"("platform", "operation_type", "workflow_key"))
          WHERE ("cb"."status" = 'active'::"text")
        ), "resolved_logs" AS (
         SELECT "w"."id",
            "w"."workflow_key",
            "w"."workflow_name",
            "w"."workflow_category",
            "w"."n8n_execution_id",
            "w"."client_id",
            "w"."client_slug",
            "w"."client_name",
            "w"."ghl_location_id",
            "w"."status",
            "w"."stage",
            "w"."started_at",
            "w"."finished_at",
            "w"."duration_ms",
            "w"."items_processed",
            "w"."items_failed",
            "w"."error_message",
            "w"."error_node",
            "w"."stages",
            "w"."metadata",
            "w"."created_at",
            COALESCE("w"."client_id", "cb"."id") AS "resolved_client_id",
            "row_number"() OVER (PARTITION BY COALESCE("w"."client_id", "cb"."id"), "w"."workflow_key" ORDER BY
                CASE
                    WHEN (("w"."status" = 'error'::"text") OR ("w"."error_message" IS NOT NULL)) THEN 0
                    ELSE 1
                END, "w"."started_at" DESC,
                CASE
                    WHEN ("w"."finished_at" IS NOT NULL) THEN 0
                    ELSE 1
                END, "w"."id" DESC) AS "relevance_rank"
           FROM ("public"."workflow_execution_logs" "w"
             LEFT JOIN "public"."clients_base" "cb" ON (("cb"."ghl_location_id" = "w"."ghl_location_id")))
          WHERE ("w"."workflow_key" = ANY (ARRAY['2.1'::"text", '2.2'::"text", '0.1'::"text", '0.4'::"text"]))
        ), "log_stats" AS (
         SELECT "resolved_logs"."resolved_client_id" AS "client_id",
            "resolved_logs"."workflow_key",
            "max"("resolved_logs"."started_at") AS "last_attempt_at",
            "max"("resolved_logs"."started_at") FILTER (WHERE ("resolved_logs"."status" = 'success'::"text")) AS "last_success_at",
            "max"("resolved_logs"."finished_at") AS "last_finished_at"
           FROM "resolved_logs"
          WHERE ("resolved_logs"."resolved_client_id" IS NOT NULL)
          GROUP BY "resolved_logs"."resolved_client_id", "resolved_logs"."workflow_key"
        ), "last_log" AS (
         SELECT "resolved_logs"."id",
            "resolved_logs"."workflow_key",
            "resolved_logs"."workflow_name",
            "resolved_logs"."workflow_category",
            "resolved_logs"."n8n_execution_id",
            "resolved_logs"."client_id",
            "resolved_logs"."client_slug",
            "resolved_logs"."client_name",
            "resolved_logs"."ghl_location_id",
            "resolved_logs"."status",
            "resolved_logs"."stage",
            "resolved_logs"."started_at",
            "resolved_logs"."finished_at",
            "resolved_logs"."duration_ms",
            "resolved_logs"."items_processed",
            "resolved_logs"."items_failed",
            "resolved_logs"."error_message",
            "resolved_logs"."error_node",
            "resolved_logs"."stages",
            "resolved_logs"."metadata",
            "resolved_logs"."created_at",
            "resolved_logs"."resolved_client_id",
            "resolved_logs"."relevance_rank"
           FROM "resolved_logs"
          WHERE ("resolved_logs"."relevance_rank" = 1)
        ), "physical_union" AS (
         SELECT "meta_ads_daily"."client_id",
            'meta'::"text" AS "platform",
            "meta_ads_daily"."updated_at" AS "write_at",
            "meta_ads_daily"."date" AS "data_date"
           FROM "public"."meta_ads_daily"
        UNION ALL
         SELECT "google_ads_campaign_daily"."client_id",
            'google_ads'::"text" AS "text",
            "google_ads_campaign_daily"."updated_at",
            "google_ads_campaign_daily"."date"
           FROM "public"."google_ads_campaign_daily"
        UNION ALL
         SELECT "google_ads_keywords_daily"."client_id",
            'google_ads'::"text" AS "text",
            COALESCE("google_ads_keywords_daily"."synced_at", "google_ads_keywords_daily"."updated_at") AS "coalesce",
            "google_ads_keywords_daily"."date"
           FROM "public"."google_ads_keywords_daily"
        ), "physical" AS (
         SELECT "pu"."client_id",
            "pu"."platform",
            "max"("pu"."write_at") AS "last_physical_write_at",
            "max"("pu"."data_date") AS "max_data_date",
            "count"(*) FILTER (WHERE ("pu"."write_at" >= ("clock_timestamp"() - "s"."recent_write_window"))) AS "rows_written_recently"
           FROM ("physical_union" "pu"
             CROSS JOIN "settings" "s")
          GROUP BY "pu"."client_id", "pu"."platform"
        ), "joined" AS (
         SELECT "om"."client_id",
            "om"."client_name",
            "om"."client_slug",
            "om"."ghl_location_id",
            "om"."platform",
            "om"."operation_type",
            "om"."workflow_key",
            "om"."is_enabled",
            "om"."saved_last_sync_at",
            "om"."saved_last_backfill_at",
            "om"."saved_backfill_status",
            "om"."saved_backfill_error",
            "ls"."last_attempt_at",
            "ls"."last_success_at",
            "ls"."last_finished_at",
            "ll"."n8n_execution_id" AS "last_execution_id",
            "ll"."status" AS "last_source_status",
            "ll"."stage" AS "last_checkpoint",
            "ll"."error_node" AS "last_error_node",
            "ll"."error_message" AS "last_error_message",
            "ll"."started_at" AS "selected_log_started_at",
            "ll"."finished_at" AS "selected_log_finished_at",
            "ll"."duration_ms",
            "ll"."items_processed",
            "ll"."items_failed",
            "ll"."metadata" AS "selected_log_metadata",
            "p"."last_physical_write_at",
            "p"."max_data_date",
            COALESCE("p"."rows_written_recently", (0)::bigint) AS "rows_written_recently",
                CASE
                    WHEN ("om"."saved_backfill_error" IS NULL) THEN NULL::"text"
                    ELSE COALESCE(NULLIF(("om"."saved_backfill_error" ->> 'message'::"text"), ''::"text"), NULLIF(("om"."saved_backfill_error" ->> 'error'::"text"), ''::"text"), "left"(("om"."saved_backfill_error")::"text", 500))
                END AS "sanitized_backfill_error"
           FROM ((("operation_matrix" "om"
             LEFT JOIN "log_stats" "ls" ON ((("ls"."client_id" = "om"."client_id") AND ("ls"."workflow_key" = "om"."workflow_key"))))
             LEFT JOIN "last_log" "ll" ON ((("ll"."resolved_client_id" = "om"."client_id") AND ("ll"."workflow_key" = "om"."workflow_key") AND ("ll"."relevance_rank" = 1))))
             LEFT JOIN "physical" "p" ON ((("p"."client_id" = "om"."client_id") AND ("p"."platform" = "om"."platform"))))
        ), "classified" AS (
         SELECT "j"."client_id",
            "j"."client_name",
            "j"."client_slug",
            "j"."ghl_location_id",
            "j"."platform",
            "j"."operation_type",
            "j"."workflow_key",
            "j"."is_enabled",
            "j"."saved_last_sync_at",
            "j"."saved_last_backfill_at",
            "j"."saved_backfill_status",
            "j"."saved_backfill_error",
            "j"."last_attempt_at",
            "j"."last_success_at",
            "j"."last_finished_at",
            "j"."last_execution_id",
            "j"."last_source_status",
            "j"."last_checkpoint",
            "j"."last_error_node",
            "j"."last_error_message",
            "j"."selected_log_started_at",
            "j"."selected_log_finished_at",
            "j"."duration_ms",
            "j"."items_processed",
            "j"."items_failed",
            "j"."selected_log_metadata",
            "j"."last_physical_write_at",
            "j"."max_data_date",
            "j"."rows_written_recently",
            "j"."sanitized_backfill_error",
                CASE
                    WHEN (NOT "j"."is_enabled") THEN 'disabled'::"text"
                    WHEN (("j"."operation_type" = 'daily'::"text") AND (("j"."last_source_status" = 'error'::"text") OR ("j"."last_error_message" IS NOT NULL))) THEN 'error'::"text"
                    WHEN (("j"."operation_type" = 'daily'::"text") AND ("j"."last_source_status" = 'running'::"text") AND ("j"."selected_log_started_at" >= ("clock_timestamp"() - "s"."workflow_sla"))) THEN 'running'::"text"
                    WHEN (("j"."operation_type" = 'daily'::"text") AND ("j"."last_source_status" = 'running'::"text") AND ("j"."selected_log_started_at" < ("clock_timestamp"() - "s"."workflow_sla")) AND (("j"."saved_last_sync_at" >= "s"."today_start") OR ("j"."last_physical_write_at" >= "s"."today_start"))) THEN 'telemetry_not_closed'::"text"
                    WHEN (("j"."operation_type" = 'daily'::"text") AND ("j"."last_source_status" = 'success'::"text") AND (COALESCE("j"."items_processed", 0) = 0) AND ("j"."selected_log_finished_at" >= "s"."today_start")) THEN 'completed_no_data'::"text"
                    WHEN (("j"."operation_type" = 'daily'::"text") AND ("j"."saved_last_sync_at" >= "s"."today_start") AND (("j"."max_data_date" >= "s"."expected_max_data_date") OR (("j"."last_source_status" = 'success'::"text") AND (COALESCE("j"."items_processed", 0) = 0)))) THEN 'ok'::"text"
                    WHEN ("j"."operation_type" = 'daily'::"text") THEN 'not_run'::"text"
                    WHEN (("j"."operation_type" = 'backfill'::"text") AND (("j"."last_source_status" = 'error'::"text") OR ("j"."last_error_message" IS NOT NULL) OR ("j"."sanitized_backfill_error" IS NOT NULL))) THEN 'error'::"text"
                    WHEN (("j"."operation_type" = 'backfill'::"text") AND ("j"."last_source_status" = 'running'::"text") AND ("j"."selected_log_started_at" >= ("clock_timestamp"() - "s"."workflow_sla"))) THEN 'running'::"text"
                    WHEN (("j"."operation_type" = 'backfill'::"text") AND ("j"."last_source_status" = 'running'::"text") AND ("j"."selected_log_started_at" < ("clock_timestamp"() - "s"."workflow_sla")) AND (("j"."saved_last_backfill_at" IS NOT NULL) OR ("lower"(COALESCE("j"."saved_backfill_status", ''::"text")) = ANY (ARRAY['completed'::"text", 'success'::"text", 'done'::"text"])))) THEN 'telemetry_not_closed'::"text"
                    WHEN (("j"."operation_type" = 'backfill'::"text") AND ("lower"(COALESCE("j"."saved_backfill_status", ''::"text")) = ANY (ARRAY['completed'::"text", 'success'::"text", 'done'::"text"]))) THEN 'backfill_completed'::"text"
                    WHEN (("j"."operation_type" = 'backfill'::"text") AND ("j"."saved_last_backfill_at" IS NOT NULL)) THEN 'backfill_completed'::"text"
                    ELSE 'not_run'::"text"
                END AS "health_status",
                CASE
                    WHEN (NOT "j"."is_enabled") THEN 'Operação desativada em clients_base.'::"text"
                    WHEN (("j"."operation_type" = 'daily'::"text") AND (("j"."last_source_status" = 'error'::"text") OR ("j"."last_error_message" IS NOT NULL))) THEN COALESCE("j"."last_error_message", 'Erro técnico explícito no workflow de sync.'::"text")
                    WHEN (("j"."operation_type" = 'daily'::"text") AND ("j"."last_source_status" = 'running'::"text") AND ("j"."selected_log_started_at" >= ("clock_timestamp"() - "s"."workflow_sla"))) THEN 'Workflow em execução dentro da janela operacional.'::"text"
                    WHEN (("j"."operation_type" = 'daily'::"text") AND ("j"."last_source_status" = 'running'::"text") AND ("j"."selected_log_started_at" < ("clock_timestamp"() - "s"."workflow_sla")) AND (("j"."saved_last_sync_at" >= "s"."today_start") OR ("j"."last_physical_write_at" >= "s"."today_start"))) THEN 'O sync gravou ou confirmou dados, mas o log do workflow não foi encerrado.'::"text"
                    WHEN (("j"."operation_type" = 'daily'::"text") AND ("j"."last_source_status" = 'success'::"text") AND (COALESCE("j"."items_processed", 0) = 0) AND ("j"."selected_log_finished_at" >= "s"."today_start")) THEN 'O workflow concluiu corretamente e registrou zero itens processados.'::"text"
                    WHEN (("j"."operation_type" = 'daily'::"text") AND ("j"."saved_last_sync_at" >= "s"."today_start") AND ("j"."max_data_date" >= "s"."expected_max_data_date")) THEN 'Dados atualizados até a data operacional esperada.'::"text"
                    WHEN ("j"."operation_type" = 'daily'::"text") THEN 'Não existe evidência suficiente de execução e atualização dentro da janela esperada.'::"text"
                    WHEN (("j"."operation_type" = 'backfill'::"text") AND (("j"."last_source_status" = 'error'::"text") OR ("j"."last_error_message" IS NOT NULL) OR ("j"."sanitized_backfill_error" IS NOT NULL))) THEN COALESCE("j"."last_error_message", "j"."sanitized_backfill_error", 'Erro explícito no backfill.'::"text")
                    WHEN (("j"."operation_type" = 'backfill'::"text") AND ("j"."last_source_status" = 'running'::"text") AND ("j"."selected_log_started_at" >= ("clock_timestamp"() - "s"."workflow_sla"))) THEN 'Backfill em execução dentro da janela operacional.'::"text"
                    WHEN (("j"."operation_type" = 'backfill'::"text") AND ("j"."last_source_status" = 'running'::"text") AND ("j"."selected_log_started_at" < ("clock_timestamp"() - "s"."workflow_sla")) AND (("j"."saved_last_backfill_at" IS NOT NULL) OR ("lower"(COALESCE("j"."saved_backfill_status", ''::"text")) = ANY (ARRAY['completed'::"text", 'success'::"text", 'done'::"text"])))) THEN 'O backfill foi registrado como concluído, mas a telemetria do workflow não foi encerrada.'::"text"
                    WHEN (("j"."operation_type" = 'backfill'::"text") AND (("lower"(COALESCE("j"."saved_backfill_status", ''::"text")) = ANY (ARRAY['completed'::"text", 'success'::"text", 'done'::"text"])) OR ("j"."saved_last_backfill_at" IS NOT NULL))) THEN 'Backfill concluído conforme estado registrado em clients_base.'::"text"
                    ELSE 'Nenhuma execução de backfill foi registrada.'::"text"
                END AS "health_reason"
           FROM ("joined" "j"
             CROSS JOIN "settings" "s")
        )
 SELECT "client_id",
    "client_name",
    "client_slug",
    "platform",
    "operation_type",
    "workflow_key",
    "is_enabled",
    "last_attempt_at",
    "last_success_at",
    "last_finished_at",
    "last_execution_id",
    "last_source_status" AS "last_status",
    "last_checkpoint",
    "last_error_node",
    "last_error_message",
    "duration_ms",
    "items_processed",
    "items_failed",
    "last_physical_write_at",
    "max_data_date",
    "rows_written_recently",
        CASE
            WHEN ("operation_type" = 'backfill'::"text") THEN "saved_backfill_status"
            ELSE NULL::"text"
        END AS "backfill_status",
        CASE
            WHEN ("operation_type" = 'backfill'::"text") THEN "sanitized_backfill_error"
            ELSE NULL::"text"
        END AS "backfill_error",
        CASE
            WHEN ("operation_type" = 'backfill'::"text") THEN "saved_last_backfill_at"
            ELSE NULL::timestamp with time zone
        END AS "backfill_completed_at",
    "saved_last_sync_at",
    "jsonb_strip_nulls"("jsonb_build_object"('since', ("selected_log_metadata" ->> 'since'::"text"), 'until', ("selected_log_metadata" ->> 'until'::"text"), 'trigger_mode', ("selected_log_metadata" ->> 'trigger_mode'::"text"), 'client_scope', ("selected_log_metadata" ->> 'client_scope'::"text"))) AS "operation_metadata",
    "health_status",
    "health_reason"
   FROM "classified" "c"
  WHERE "private"."user_can_access_client"("client_id");


ALTER VIEW "public"."v_sync_health" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_sync_health" IS 'CANONICAL: uma linha por client_id + platform + operation_type. Consolida configuração, logs e escrita física. SLA workflow 2h; janela de escrita recente 36h. Sem credenciais ou payloads.';



CREATE OR REPLACE VIEW "public"."v_tracking_runtime_health" WITH ("security_invoker"='true') AS
 WITH "client_platforms" AS (
         SELECT "cb"."id" AS "client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "cb"."ghl_location_id",
            "cb"."tracking_ready",
            "cb"."tracking_status",
            "p"."platform",
            "p"."workflow_key",
                CASE "p"."platform"
                    WHEN 'meta'::"text" THEN (COALESCE("cb"."enable_meta_tracking", false) AND COALESCE("cb"."meta_enabled", false))
                    WHEN 'google_ads'::"text" THEN (COALESCE("cb"."enable_google_tracking", false) AND COALESCE("cb"."google_offline_enabled", false) AND COALESCE("cb"."google_data_manager_enabled", false))
                    ELSE false
                END AS "is_enabled",
                CASE "p"."platform"
                    WHEN 'meta'::"text" THEN (COALESCE("cb"."tracking_ready", false) AND COALESCE("cb"."meta_ready", false))
                    WHEN 'google_ads'::"text" THEN (COALESCE("cb"."tracking_ready", false) AND COALESCE("cb"."google_ads_ready", false) AND COALESCE("cb"."google_data_manager_enabled", false))
                    ELSE false
                END AS "configuration_ready"
           FROM ("public"."clients_base" "cb"
             CROSS JOIN ( VALUES ('meta'::"text",'1.2'::"text"), ('google_ads'::"text",'1.3'::"text")) "p"("platform", "workflow_key"))
          WHERE ("cb"."status" = 'active'::"text")
        ), "outbox_agg" AS (
         SELECT "en"."client_id",
            "co"."platform",
            "count"(*) AS "total_jobs",
            "count"(*) FILTER (WHERE ("co"."status" = 'pending'::"text")) AS "pending_count",
            "count"(*) FILTER (WHERE (("co"."status" = 'pending'::"text") AND ("co"."created_at" < ("now"() - '24:00:00'::interval)))) AS "overdue_pending_count",
            "count"(*) FILTER (WHERE (("co"."status" = 'failed'::"text") AND ("co"."updated_at" >= ("now"() - '7 days'::interval)))) AS "failed_7d",
            "count"(*) FILTER (WHERE (("co"."status" = 'sent'::"text") AND ("co"."sent_at" >= ("now"() - '7 days'::interval)))) AS "sent_7d",
            "count"(*) FILTER (WHERE (("co"."status" = 'skipped'::"text") AND ("co"."updated_at" >= ("now"() - '7 days'::interval)))) AS "skipped_7d",
            "max"("co"."created_at") AS "last_job_at",
            "max"("co"."sent_at") AS "last_sent_at",
            "max"("co"."updated_at") FILTER (WHERE (("co"."status" = ANY (ARRAY['failed'::"text", 'pending'::"text"])) AND (NULLIF("co"."last_error", ''::"text") IS NOT NULL))) AS "last_error_at"
           FROM ("public"."conversion_outbox" "co"
             JOIN "public"."events_normalized" "en" ON (("en"."id" = "co"."normalized_event_id")))
          GROUP BY "en"."client_id", "co"."platform"
        ), "latest_outbox_issue" AS (
         SELECT "ranked"."client_id",
            "ranked"."platform",
            "ranked"."issue_status",
            "ranked"."last_error",
            "ranked"."error_code",
            "ranked"."error_subcode",
            "ranked"."http_status",
            "ranked"."issue_at",
            "ranked"."error_details",
            "ranked"."rn"
           FROM ( SELECT "en"."client_id",
                    "co"."platform",
                    "co"."status" AS "issue_status",
                    "co"."last_error",
                    "co"."error_code",
                    "co"."error_subcode",
                    "co"."http_status",
                    "co"."updated_at" AS "issue_at",
                    "co"."error_details",
                    "row_number"() OVER (PARTITION BY "en"."client_id", "co"."platform" ORDER BY "co"."updated_at" DESC, "co"."id" DESC) AS "rn"
                   FROM ("public"."conversion_outbox" "co"
                     JOIN "public"."events_normalized" "en" ON (("en"."id" = "co"."normalized_event_id")))
                  WHERE (("co"."status" = ANY (ARRAY['failed'::"text", 'pending'::"text"])) AND (NULLIF("co"."last_error", ''::"text") IS NOT NULL))) "ranked"
          WHERE ("ranked"."rn" = 1)
        ), "workflow_logs_resolved" AS (
         SELECT COALESCE("w"."client_id", "cb"."id") AS "resolved_client_id",
                CASE "w"."workflow_key"
                    WHEN '1.2'::"text" THEN 'meta'::"text"
                    WHEN '1.3'::"text" THEN 'google_ads'::"text"
                    ELSE NULL::"text"
                END AS "platform",
            "w"."n8n_execution_id",
            "w"."status",
            "w"."stage",
            "w"."error_node",
            "w"."error_message",
            "w"."started_at",
            "w"."finished_at",
            "row_number"() OVER (PARTITION BY COALESCE("w"."client_id", "cb"."id"),
                CASE "w"."workflow_key"
                    WHEN '1.2'::"text" THEN 'meta'::"text"
                    WHEN '1.3'::"text" THEN 'google_ads'::"text"
                    ELSE NULL::"text"
                END ORDER BY "w"."started_at" DESC, "w"."id" DESC) AS "rn"
           FROM ("public"."workflow_execution_logs" "w"
             LEFT JOIN "public"."clients_base" "cb" ON (("cb"."ghl_location_id" = "w"."ghl_location_id")))
          WHERE (("w"."workflow_key" = ANY (ARRAY['1.2'::"text", '1.3'::"text"])) AND ("w"."status" <> 'aborted_legacy'::"text"))
        ), "latest_workflow" AS (
         SELECT "workflow_logs_resolved"."resolved_client_id",
            "workflow_logs_resolved"."platform",
            "workflow_logs_resolved"."n8n_execution_id",
            "workflow_logs_resolved"."status",
            "workflow_logs_resolved"."stage",
            "workflow_logs_resolved"."error_node",
            "workflow_logs_resolved"."error_message",
            "workflow_logs_resolved"."started_at",
            "workflow_logs_resolved"."finished_at",
            "workflow_logs_resolved"."rn"
           FROM "workflow_logs_resolved"
          WHERE ("workflow_logs_resolved"."rn" = 1)
        )
 SELECT "cp"."client_id",
    "cp"."client_name",
    "cp"."client_slug",
    "cp"."platform",
    "cp"."workflow_key",
    "cp"."is_enabled",
    "cp"."tracking_ready",
    "cp"."tracking_status",
    "cp"."configuration_ready",
        CASE
            WHEN (NOT "cp"."is_enabled") THEN 'disabled'::"text"
            WHEN (NOT "cp"."configuration_ready") THEN 'incomplete'::"text"
            ELSE 'ready'::"text"
        END AS "configuration_status",
    COALESCE("oa"."total_jobs", (0)::bigint) AS "total_jobs",
    COALESCE("oa"."pending_count", (0)::bigint) AS "pending_count",
    COALESCE("oa"."overdue_pending_count", (0)::bigint) AS "overdue_pending_count",
    COALESCE("oa"."failed_7d", (0)::bigint) AS "failed_7d",
    COALESCE("oa"."sent_7d", (0)::bigint) AS "sent_7d",
    COALESCE("oa"."skipped_7d", (0)::bigint) AS "skipped_7d",
    "oa"."last_job_at",
    "oa"."last_sent_at",
    "oa"."last_error_at",
    "lw"."n8n_execution_id" AS "last_execution_id",
    "lw"."status" AS "last_workflow_status",
    "lw"."stage" AS "last_checkpoint",
    "lw"."started_at" AS "last_workflow_started_at",
    "lw"."finished_at" AS "last_workflow_finished_at",
    "lw"."error_node" AS "last_workflow_error_node",
    "lw"."error_message" AS "last_workflow_error_message",
    "loi"."issue_status" AS "last_issue_status",
    "loi"."last_error",
    "loi"."error_code",
    "loi"."error_subcode",
    "loi"."http_status" AS "last_http_status",
    COALESCE(NULLIF(("loi"."error_details" ->> 'error_user_title'::"text"), ''::"text"), NULLIF(("loi"."error_details" ->> 'user_title'::"text"), ''::"text"), NULLIF(("loi"."error_details" #>> '{error,error_user_title}'::"text"[]), ''::"text"), NULLIF(("loi"."error_details" #>> '{body,error,error_user_title}'::"text"[]), ''::"text")) AS "platform_error_title",
    COALESCE(NULLIF(("loi"."error_details" ->> 'error_user_message'::"text"), ''::"text"), NULLIF(("loi"."error_details" ->> 'user_message'::"text"), ''::"text"), NULLIF(("loi"."error_details" #>> '{error,error_user_msg}'::"text"[]), ''::"text"), NULLIF(("loi"."error_details" #>> '{body,error,error_user_msg}'::"text"[]), ''::"text"), NULLIF(("loi"."error_details" #>> '{error,message}'::"text"[]), ''::"text"), NULLIF(("loi"."error_details" #>> '{body,error,message}'::"text"[]), ''::"text")) AS "platform_error_message",
        CASE
            WHEN (NOT "cp"."is_enabled") THEN 'disabled'::"text"
            WHEN (NOT "cp"."configuration_ready") THEN 'config_incomplete'::"text"
            WHEN (("lw"."status" = 'error'::"text") AND ("lw"."started_at" >= ("now"() - '24:00:00'::interval))) THEN 'error'::"text"
            WHEN (COALESCE("oa"."overdue_pending_count", (0)::bigint) > 0) THEN 'backlog'::"text"
            WHEN (COALESCE("oa"."failed_7d", (0)::bigint) > 0) THEN 'warning'::"text"
            WHEN (COALESCE("oa"."pending_count", (0)::bigint) > 0) THEN 'processing'::"text"
            WHEN (COALESCE("oa"."sent_7d", (0)::bigint) > 0) THEN 'healthy'::"text"
            ELSE 'idle'::"text"
        END AS "runtime_status",
        CASE
            WHEN (NOT "cp"."is_enabled") THEN 'Tracking desativado na configuração do cliente.'::"text"
            WHEN (NOT "cp"."configuration_ready") THEN 'Configuração de tracking incompleta.'::"text"
            WHEN (("lw"."status" = 'error'::"text") AND ("lw"."started_at" >= ("now"() - '24:00:00'::interval))) THEN COALESCE(NULLIF("lw"."error_message", ''::"text"), 'Erro recente no dispatcher.'::"text")
            WHEN (COALESCE("oa"."overdue_pending_count", (0)::bigint) > 0) THEN (("oa"."overdue_pending_count")::"text" || ' job(s) pendente(s) há mais de 24 horas.'::"text")
            WHEN (COALESCE("oa"."failed_7d", (0)::bigint) > 0) THEN (("oa"."failed_7d")::"text" || ' falha(s) registrada(s) nos últimos 7 dias.'::"text")
            WHEN (COALESCE("oa"."pending_count", (0)::bigint) > 0) THEN (("oa"."pending_count")::"text" || ' job(s) aguardando processamento.'::"text")
            WHEN (COALESCE("oa"."sent_7d", (0)::bigint) > 0) THEN 'Dispatcher enviando eventos normalmente.'::"text"
            ELSE 'Nenhum job recente; configuração pronta e operação ociosa.'::"text"
        END AS "runtime_reason",
    "now"() AS "evaluated_at"
   FROM ((("client_platforms" "cp"
     LEFT JOIN "outbox_agg" "oa" ON ((("oa"."client_id" = "cp"."client_id") AND ("oa"."platform" = "cp"."platform"))))
     LEFT JOIN "latest_outbox_issue" "loi" ON ((("loi"."client_id" = "cp"."client_id") AND ("loi"."platform" = "cp"."platform"))))
     LEFT JOIN "latest_workflow" "lw" ON ((("lw"."resolved_client_id" = "cp"."client_id") AND ("lw"."platform" = "cp"."platform"))))
  WHERE "private"."user_can_access_client"("cp"."client_id");


ALTER VIEW "public"."v_tracking_runtime_health" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_tracking_runtime_health" IS 'Separates tracking configuration readiness from dispatcher runtime health, backlog and recent platform/workflow errors.';



CREATE OR REPLACE VIEW "public"."v_workflow_health_daily" WITH ("security_invoker"='false') AS
 SELECT "date_trunc"('day'::"text", ("started_at" AT TIME ZONE 'America/Sao_Paulo'::"text")) AS "day",
    "workflow_key",
    "workflow_name",
    "workflow_category",
    "client_id",
    "client_name",
    "count"(*) AS "total_executions",
    "count"(*) FILTER (WHERE ("status" = 'success'::"text")) AS "success_count",
    "count"(*) FILTER (WHERE ("status" = 'error'::"text")) AS "error_count",
    "count"(*) FILTER (WHERE ("status" = 'partial'::"text")) AS "partial_count",
    "round"("avg"("duration_ms")) AS "avg_duration_ms",
    "max"("started_at") AS "last_execution_at"
   FROM "public"."workflow_execution_logs"
  WHERE (( SELECT "count"(*) AS "count"
           FROM "public"."client_users" "cu"
          WHERE (("cu"."user_id" = "auth"."uid"()) AND ("cu"."is_active" = true))) > 1)
  GROUP BY ("date_trunc"('day'::"text", ("started_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))), "workflow_key", "workflow_name", "workflow_category", "client_id", "client_name";


ALTER VIEW "public"."v_workflow_health_daily" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_workflow_health_daily" IS 'Agregação diária para o painel interno de saúde de workflows (não client-facing — não tem RLS por client_id aplicada aqui de propósito, uso interno da agência).';



ALTER TABLE ONLY "crm"."activities"
    ADD CONSTRAINT "activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."activities"
    ADD CONSTRAINT "activities_tenant_id_id_key" UNIQUE ("tenant_id", "id");



ALTER TABLE ONLY "crm"."canonical_loss_reasons"
    ADD CONSTRAINT "canonical_loss_reasons_code_key" UNIQUE ("code");



ALTER TABLE ONLY "crm"."canonical_loss_reasons"
    ADD CONSTRAINT "canonical_loss_reasons_label_key" UNIQUE ("label");



ALTER TABLE ONLY "crm"."canonical_loss_reasons"
    ADD CONSTRAINT "canonical_loss_reasons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."commercial_outcomes"
    ADD CONSTRAINT "commercial_outcomes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."commercial_outcomes"
    ADD CONSTRAINT "commercial_outcomes_tenant_id_id_key" UNIQUE ("tenant_id", "id");



ALTER TABLE ONLY "crm"."contact_identities"
    ADD CONSTRAINT "contact_identities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."contact_identities"
    ADD CONSTRAINT "contact_identities_tenant_id_id_key" UNIQUE ("tenant_id", "id");



ALTER TABLE ONLY "crm"."contact_identities"
    ADD CONSTRAINT "contact_identities_tenant_id_kind_value_normalized_key" UNIQUE ("tenant_id", "kind", "value_normalized");



ALTER TABLE ONLY "crm"."contacts"
    ADD CONSTRAINT "contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."contacts"
    ADD CONSTRAINT "contacts_tenant_id_id_key" UNIQUE ("tenant_id", "id");



ALTER TABLE ONLY "crm"."event_map"
    ADD CONSTRAINT "event_map_pkey" PRIMARY KEY ("event_code");



ALTER TABLE ONLY "crm"."event_map"
    ADD CONSTRAINT "event_map_stage_code_key" UNIQUE ("stage_code");



ALTER TABLE ONLY "crm"."event_map"
    ADD CONSTRAINT "event_map_version_event_code_key" UNIQUE ("version", "event_code");



ALTER TABLE ONLY "crm"."global_pipeline_stages"
    ADD CONSTRAINT "global_pipeline_stages_pipeline_version_id_code_key" UNIQUE ("pipeline_version_id", "code");



ALTER TABLE ONLY "crm"."global_pipeline_stages"
    ADD CONSTRAINT "global_pipeline_stages_pipeline_version_id_label_key" UNIQUE ("pipeline_version_id", "label");



ALTER TABLE ONLY "crm"."global_pipeline_stages"
    ADD CONSTRAINT "global_pipeline_stages_pipeline_version_id_position_key" UNIQUE ("pipeline_version_id", "position");



ALTER TABLE ONLY "crm"."global_pipeline_stages"
    ADD CONSTRAINT "global_pipeline_stages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."global_pipeline_versions"
    ADD CONSTRAINT "global_pipeline_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."global_pipeline_versions"
    ADD CONSTRAINT "global_pipeline_versions_version_no_key" UNIQUE ("version_no");



ALTER TABLE ONLY "crm"."opportunities"
    ADD CONSTRAINT "opportunities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."opportunities"
    ADD CONSTRAINT "opportunities_tenant_id_id_key" UNIQUE ("tenant_id", "id");



ALTER TABLE ONLY "crm"."opportunity_milestones"
    ADD CONSTRAINT "opportunity_milestones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."opportunity_stage_history"
    ADD CONSTRAINT "opportunity_stage_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."opportunity_stage_history"
    ADD CONSTRAINT "opportunity_stage_history_tenant_id_id_key" UNIQUE ("tenant_id", "id");



ALTER TABLE ONLY "crm"."opportunity_stage_history"
    ADD CONSTRAINT "opportunity_stage_history_tenant_id_id_opportunity_id_key" UNIQUE ("tenant_id", "id", "opportunity_id");



ALTER TABLE ONLY "crm"."processed_events"
    ADD CONSTRAINT "processed_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."processed_events"
    ADD CONSTRAINT "processed_events_tenant_id_raw_event_id_key" UNIQUE ("tenant_id", "raw_event_id");



ALTER TABLE ONLY "crm"."processed_events"
    ADD CONSTRAINT "processed_events_tenant_id_source_external_id_key" UNIQUE ("tenant_id", "source", "external_id");



ALTER TABLE ONLY "crm"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."tenant_memberships"
    ADD CONSTRAINT "tenant_memberships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."tenant_memberships"
    ADD CONSTRAINT "tenant_memberships_tenant_id_profile_id_key" UNIQUE ("tenant_id", "profile_id");



ALTER TABLE ONLY "crm"."tenants"
    ADD CONSTRAINT "tenants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "crm"."tenants"
    ADD CONSTRAINT "tenants_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."client_google_ads_accounts"
    ADD CONSTRAINT "client_google_ads_accounts_client_id_google_ads_customer_id_key" UNIQUE ("client_id", "google_ads_customer_id");



ALTER TABLE ONLY "public"."client_google_ads_accounts"
    ADD CONSTRAINT "client_google_ads_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_meta_ad_accounts"
    ADD CONSTRAINT "client_meta_ad_accounts_client_id_meta_ad_account_id_key" UNIQUE ("client_id", "meta_ad_account_id");



ALTER TABLE ONLY "public"."client_meta_ad_accounts"
    ADD CONSTRAINT "client_meta_ad_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_users"
    ADD CONSTRAINT "client_users_client_id_user_id_key" UNIQUE ("client_id", "user_id");



ALTER TABLE ONLY "public"."client_users"
    ADD CONSTRAINT "client_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clients_base"
    ADD CONSTRAINT "clients_base_ghl_location_id_key" UNIQUE ("ghl_location_id");



ALTER TABLE ONLY "public"."clients_base"
    ADD CONSTRAINT "clients_base_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."conversion_outbox"
    ADD CONSTRAINT "conversion_outbox_normalized_event_id_platform_route_meta_e_key" UNIQUE ("normalized_event_id", "platform", "route", "meta_event_name");



ALTER TABLE ONLY "public"."conversion_outbox"
    ADD CONSTRAINT "conversion_outbox_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."conversion_outbox"
    ADD CONSTRAINT "conversion_outbox_unique_event" UNIQUE ("normalized_event_id", "platform", "route", "meta_event_name");



ALTER TABLE ONLY "public"."database_documentation_registry"
    ADD CONSTRAINT "database_documentation_registry_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events_normalized"
    ADD CONSTRAINT "events_normalized_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events_normalized"
    ADD CONSTRAINT "events_normalized_raw_event_unique" UNIQUE ("raw_event_id");



ALTER TABLE ONLY "public"."events_raw"
    ADD CONSTRAINT "events_raw_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_ga4_raw"
    ADD CONSTRAINT "external_ga4_raw_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_ga4_raw"
    ADD CONSTRAINT "external_ga4_raw_row_key_uk" UNIQUE ("client_id", "source_row_key");



ALTER TABLE ONLY "public"."external_hotmart_raw"
    ADD CONSTRAINT "external_hotmart_raw_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_hotmart_raw"
    ADD CONSTRAINT "external_hotmart_raw_row_key_uk" UNIQUE ("client_id", "source_row_key");



ALTER TABLE ONLY "public"."external_meta_ads_raw"
    ADD CONSTRAINT "external_meta_ads_raw_grain_uk" UNIQUE ("client_id", "date", "account_id", "ad_id");



ALTER TABLE ONLY "public"."external_meta_ads_raw"
    ADD CONSTRAINT "external_meta_ads_raw_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."external_meta_ads_raw"
    ADD CONSTRAINT "external_meta_ads_raw_row_key_uk" UNIQUE ("client_id", "source_row_key");



ALTER TABLE ONLY "public"."form_intake_rate_limit"
    ADD CONSTRAINT "form_intake_rate_limit_pkey" PRIMARY KEY ("window_started", "ip", "form_intake_token");



ALTER TABLE ONLY "public"."google_ads_campaign_daily"
    ADD CONSTRAINT "google_ads_campaign_daily_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."google_ads_daily"
    ADD CONSTRAINT "google_ads_daily_client_id_date_customer_id_campaign_id_ad__key" UNIQUE ("client_id", "date", "customer_id", "campaign_id", "ad_group_id", "ad_id");



ALTER TABLE ONLY "public"."google_ads_daily"
    ADD CONSTRAINT "google_ads_daily_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."google_ads_keywords_daily"
    ADD CONSTRAINT "google_ads_keywords_daily_client_id_google_ads_customer_id__key" UNIQUE ("client_id", "google_ads_customer_id", "date", "campaign_id", "ad_group_id", "keyword_id");



ALTER TABLE ONLY "public"."google_ads_keywords_daily"
    ADD CONSTRAINT "google_ads_keywords_daily_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."meta_ads_daily"
    ADD CONSTRAINT "meta_ads_daily_client_id_date_account_id_campaign_id_adset__key" UNIQUE ("client_id", "date", "account_id", "campaign_id", "adset_id", "ad_id");



ALTER TABLE ONLY "public"."meta_ads_daily"
    ADD CONSTRAINT "meta_ads_daily_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stevo_events_raw"
    ADD CONSTRAINT "stevo_events_raw_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stevo_instances"
    ADD CONSTRAINT "stevo_instances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stevo_instances"
    ADD CONSTRAINT "stevo_instances_stevo_instance_id_key" UNIQUE ("stevo_instance_id");



ALTER TABLE ONLY "public"."workflow_execution_logs"
    ADD CONSTRAINT "workflow_execution_logs_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "activities_provider_message_unique" ON "crm"."activities" USING "btree" ("tenant_id", "provider_message_id") WHERE ("provider_message_id" IS NOT NULL);



CREATE UNIQUE INDEX "commercial_outcomes_one_current" ON "crm"."commercial_outcomes" USING "btree" ("tenant_id", "opportunity_id") WHERE "is_current";



CREATE INDEX "contact_identities_contact_idx" ON "crm"."contact_identities" USING "btree" ("tenant_id", "contact_id");



CREATE INDEX "contacts_tenant_id_idx" ON "crm"."contacts" USING "btree" ("tenant_id");



CREATE UNIQUE INDEX "global_pipeline_versions_one_active" ON "crm"."global_pipeline_versions" USING "btree" ("status") WHERE ("status" = 'active'::"text");



CREATE INDEX "opportunities_ctwa_idx" ON "crm"."opportunities" USING "btree" ("tenant_id", "ctwa_clid") WHERE ("ctwa_clid" IS NOT NULL);



CREATE INDEX "opportunities_meta_ad_idx" ON "crm"."opportunities" USING "btree" ("tenant_id", "meta_ad_id") WHERE ("meta_ad_id" IS NOT NULL);



CREATE INDEX "opportunities_open_recent_idx" ON "crm"."opportunities" USING "btree" ("tenant_id", "contact_id", "created_at" DESC) WHERE ("status" = 'open'::"text");



CREATE INDEX "opportunities_tenant_contact_idx" ON "crm"."opportunities" USING "btree" ("tenant_id", "contact_id");



CREATE UNIQUE INDEX "opportunity_stage_history_one_compensation" ON "crm"."opportunity_stage_history" USING "btree" ("tenant_id", "compensates_history_id") WHERE ("compensates_history_id" IS NOT NULL);



CREATE INDEX "opportunity_stage_history_timeline_idx" ON "crm"."opportunity_stage_history" USING "btree" ("tenant_id", "opportunity_id", "occurred_at", "created_at");



CREATE INDEX "clients_base_client_slug_idx" ON "public"."clients_base" USING "btree" ("client_slug");



CREATE UNIQUE INDEX "clients_base_form_intake_token_uidx" ON "public"."clients_base" USING "btree" ("form_intake_token");



CREATE UNIQUE INDEX "clients_base_ghl_location_id_uidx" ON "public"."clients_base" USING "btree" ("ghl_location_id");



CREATE INDEX "clients_base_google_ads_customer_id_idx" ON "public"."clients_base" USING "btree" ("google_ads_customer_id");



CREATE INDEX "clients_base_meta_ad_account_id_idx" ON "public"."clients_base" USING "btree" ("meta_ad_account_id");



CREATE INDEX "clients_base_tracking_status_idx" ON "public"."clients_base" USING "btree" ("tracking_status");



CREATE INDEX "events_normalized_crm_opportunity_idx" ON "public"."events_normalized" USING "btree" ("client_id", "opportunity_id", "event_code") WHERE ("source_system" = 'impuls_crm'::"text");



CREATE INDEX "google_ads_campaign_daily_channel_type_idx" ON "public"."google_ads_campaign_daily" USING "btree" ("client_id", "advertising_channel_type", "date" DESC);



CREATE INDEX "google_ads_campaign_daily_client_campaign_idx" ON "public"."google_ads_campaign_daily" USING "btree" ("client_id", "campaign_id");



CREATE INDEX "google_ads_campaign_daily_client_date_idx" ON "public"."google_ads_campaign_daily" USING "btree" ("client_id", "date" DESC);



CREATE INDEX "google_ads_campaign_daily_customer_date_idx" ON "public"."google_ads_campaign_daily" USING "btree" ("customer_id", "date" DESC);



CREATE UNIQUE INDEX "google_ads_campaign_daily_grain_uidx" ON "public"."google_ads_campaign_daily" USING "btree" ("client_id", "date", "customer_id", "campaign_id");



CREATE INDEX "idx_client_users_client_id" ON "public"."client_users" USING "btree" ("client_id");



CREATE INDEX "idx_client_users_user_client_active" ON "public"."client_users" USING "btree" ("user_id", "client_id") WHERE ("is_active" = true);



CREATE INDEX "idx_client_users_user_id" ON "public"."client_users" USING "btree" ("user_id");



CREATE INDEX "idx_clients_base_ghl_location_id" ON "public"."clients_base" USING "btree" ("ghl_location_id");



CREATE INDEX "idx_clients_base_status" ON "public"."clients_base" USING "btree" ("status");



CREATE INDEX "idx_conversion_outbox_client_created" ON "public"."conversion_outbox" USING "btree" ("ghl_location_id", "created_at" DESC);



CREATE INDEX "idx_conversion_outbox_event_code" ON "public"."conversion_outbox" USING "btree" ("event_code");



CREATE INDEX "idx_conversion_outbox_platform_status_next" ON "public"."conversion_outbox" USING "btree" ("platform", "status", "next_attempt_at");



CREATE INDEX "idx_conversion_outbox_status_created" ON "public"."conversion_outbox" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "idx_events_normalized_client_contact_event_time" ON "public"."events_normalized" USING "btree" ("client_id", "contact_id", "event_datetime", "received_at") WHERE ("contact_id" IS NOT NULL);



CREATE INDEX "idx_events_normalized_client_event" ON "public"."events_normalized" USING "btree" ("client_id", "event_code");



CREATE INDEX "idx_events_normalized_client_id" ON "public"."events_normalized" USING "btree" ("client_id");



CREATE INDEX "idx_events_normalized_client_received" ON "public"."events_normalized" USING "btree" ("client_id", "received_at");



CREATE INDEX "idx_events_normalized_client_source" ON "public"."events_normalized" USING "btree" ("client_id", "source_id") WHERE ("source_id" IS NOT NULL);



CREATE INDEX "idx_events_normalized_contact_id" ON "public"."events_normalized" USING "btree" ("contact_id");



CREATE INDEX "idx_events_normalized_ctwa_clid" ON "public"."events_normalized" USING "btree" ("ctwa_clid");



CREATE INDEX "idx_events_normalized_event_code" ON "public"."events_normalized" USING "btree" ("event_code");



CREATE INDEX "idx_events_normalized_event_datetime" ON "public"."events_normalized" USING "btree" ("event_datetime" DESC);



CREATE INDEX "idx_events_normalized_ghl_location_id" ON "public"."events_normalized" USING "btree" ("ghl_location_id");



CREATE INDEX "idx_events_normalized_google_ad" ON "public"."events_normalized" USING "btree" ("client_id", "google_campaign_id", "google_adgroup_id", "google_ad_id") WHERE ("google_campaign_id" IS NOT NULL);



CREATE INDEX "idx_events_normalized_google_campaign" ON "public"."events_normalized" USING "btree" ("client_id", "google_campaign_id") WHERE ("google_campaign_id" IS NOT NULL);



CREATE INDEX "idx_events_normalized_lead_client_contact_event_time" ON "public"."events_normalized" USING "btree" ("client_id", "contact_id", "event_datetime", "received_at") WHERE (("contact_id" IS NOT NULL) AND ("event_code" = 'lead'::"text"));



CREATE INDEX "idx_events_normalized_location_event" ON "public"."events_normalized" USING "btree" ("ghl_location_id", "event_code");



CREATE INDEX "idx_events_normalized_phone" ON "public"."events_normalized" USING "btree" ("phone");



CREATE INDEX "idx_events_normalized_raw_event_id" ON "public"."events_normalized" USING "btree" ("raw_event_id");



CREATE INDEX "idx_events_normalized_received_at" ON "public"."events_normalized" USING "btree" ("received_at");



CREATE INDEX "idx_events_raw_contact_id" ON "public"."events_raw" USING "btree" ("contact_id");



CREATE INDEX "idx_events_raw_event_type" ON "public"."events_raw" USING "btree" ("event_type");



CREATE INDEX "idx_events_raw_location_received" ON "public"."events_raw" USING "btree" ("location_id", "received_at" DESC);



CREATE INDEX "idx_events_raw_phone" ON "public"."events_raw" USING "btree" ("phone");



CREATE INDEX "idx_events_raw_received_at" ON "public"."events_raw" USING "btree" ("received_at" DESC);



CREATE INDEX "idx_events_raw_source_system" ON "public"."events_raw" USING "btree" ("source_system");



CREATE INDEX "idx_external_ga4_raw_campaign" ON "public"."external_ga4_raw" USING "btree" ("client_id", "session_campaign_id", "date" DESC);



CREATE INDEX "idx_external_ga4_raw_client_date" ON "public"."external_ga4_raw" USING "btree" ("client_id", "date" DESC);



CREATE INDEX "idx_external_ga4_raw_source_medium" ON "public"."external_ga4_raw" USING "btree" ("client_id", "session_source", "session_medium", "date" DESC);



CREATE INDEX "idx_external_hotmart_raw_campaign" ON "public"."external_hotmart_raw" USING "btree" ("client_id", "utm_campaign", "purchase_date" DESC);



CREATE INDEX "idx_external_hotmart_raw_client_purchase" ON "public"."external_hotmart_raw" USING "btree" ("client_id", "purchase_date" DESC);



CREATE INDEX "idx_external_hotmart_raw_product" ON "public"."external_hotmart_raw" USING "btree" ("client_id", "product_id", "purchase_date" DESC);



CREATE INDEX "idx_external_hotmart_raw_status" ON "public"."external_hotmart_raw" USING "btree" ("client_id", "transaction_status", "purchase_date" DESC);



CREATE INDEX "idx_external_meta_ads_raw_ad" ON "public"."external_meta_ads_raw" USING "btree" ("client_id", "ad_id", "date" DESC);



CREATE INDEX "idx_external_meta_ads_raw_adset" ON "public"."external_meta_ads_raw" USING "btree" ("client_id", "adset_id", "date" DESC);



CREATE INDEX "idx_external_meta_ads_raw_campaign" ON "public"."external_meta_ads_raw" USING "btree" ("client_id", "campaign_id", "date" DESC);



CREATE INDEX "idx_external_meta_ads_raw_client_date" ON "public"."external_meta_ads_raw" USING "btree" ("client_id", "date" DESC);



CREATE INDEX "idx_google_ads_daily_client_campaign" ON "public"."google_ads_daily" USING "btree" ("client_id", "campaign_id");



CREATE INDEX "idx_google_ads_daily_client_date" ON "public"."google_ads_daily" USING "btree" ("client_id", "date");



CREATE INDEX "idx_google_ads_keywords_daily_client_date" ON "public"."google_ads_keywords_daily" USING "btree" ("client_id", "date" DESC);



CREATE INDEX "idx_google_ads_keywords_daily_keyword" ON "public"."google_ads_keywords_daily" USING "btree" ("keyword_text");



CREATE INDEX "idx_meta_ads_daily_client_ad" ON "public"."meta_ads_daily" USING "btree" ("client_id", "ad_id");



CREATE INDEX "idx_meta_ads_daily_client_ad_latest" ON "public"."meta_ads_daily" USING "btree" ("client_id", "ad_id", "date" DESC, "updated_at" DESC, "created_at" DESC, "id" DESC) WHERE ("ad_id" IS NOT NULL);



CREATE INDEX "idx_meta_ads_daily_client_campaign" ON "public"."meta_ads_daily" USING "btree" ("client_id", "campaign_id");



CREATE INDEX "idx_meta_ads_daily_client_creative" ON "public"."meta_ads_daily" USING "btree" ("client_id", "creative_id") WHERE ("creative_id" IS NOT NULL);



CREATE INDEX "idx_meta_ads_daily_client_date" ON "public"."meta_ads_daily" USING "btree" ("client_id", "date");



CREATE INDEX "idx_stevo_events_raw_client" ON "public"."stevo_events_raw" USING "btree" ("client_id", "received_at" DESC);



CREATE INDEX "idx_stevo_events_raw_event_type" ON "public"."stevo_events_raw" USING "btree" ("event_type", "received_at" DESC);



CREATE INDEX "idx_stevo_events_raw_instance" ON "public"."stevo_events_raw" USING "btree" ("stevo_instance_id", "received_at" DESC);



CREATE INDEX "idx_stevo_events_raw_message_id" ON "public"."stevo_events_raw" USING "btree" ("external_message_id") WHERE ("external_message_id" IS NOT NULL);



CREATE INDEX "idx_stevo_events_raw_payload_hash" ON "public"."stevo_events_raw" USING "btree" ("payload_hash") WHERE ("payload_hash" IS NOT NULL);



CREATE INDEX "idx_stevo_events_raw_received_at" ON "public"."stevo_events_raw" USING "btree" ("received_at" DESC);



CREATE INDEX "idx_stevo_instances_client_id" ON "public"."stevo_instances" USING "btree" ("client_id");



CREATE INDEX "idx_stevo_instances_ghl_location_id" ON "public"."stevo_instances" USING "btree" ("ghl_location_id");



CREATE INDEX "idx_wf_logs_client_started" ON "public"."workflow_execution_logs" USING "btree" ("client_id", "started_at" DESC);



CREATE INDEX "idx_wf_logs_errors" ON "public"."workflow_execution_logs" USING "btree" ("started_at" DESC) WHERE ("status" = 'error'::"text");



CREATE INDEX "idx_wf_logs_location_started" ON "public"."workflow_execution_logs" USING "btree" ("ghl_location_id", "started_at" DESC);



CREATE INDEX "idx_wf_logs_status_started" ON "public"."workflow_execution_logs" USING "btree" ("status", "started_at" DESC);



CREATE INDEX "idx_wf_logs_workflow_started" ON "public"."workflow_execution_logs" USING "btree" ("workflow_key", "started_at" DESC);



CREATE UNIQUE INDEX "uniq_events_normalized_raw_event_id" ON "public"."events_normalized" USING "btree" ("raw_event_id") WHERE ("raw_event_id" IS NOT NULL);



CREATE UNIQUE INDEX "ux_external_hotmart_raw_transaction" ON "public"."external_hotmart_raw" USING "btree" ("client_id", "transaction_id") WHERE (("transaction_id" IS NOT NULL) AND ("btrim"("transaction_id") <> ''::"text"));



CREATE OR REPLACE TRIGGER "activities_validate_raw_tenant" BEFORE INSERT OR UPDATE ON "crm"."activities" FOR EACH ROW EXECUTE FUNCTION "crm"."validate_activity_raw_tenant"();



CREATE OR REPLACE TRIGGER "commercial_outcomes_append_only" BEFORE DELETE OR UPDATE ON "crm"."commercial_outcomes" FOR EACH ROW EXECUTE FUNCTION "crm"."restrict_outcome_revision"();



CREATE OR REPLACE TRIGGER "commercial_outcomes_validate" BEFORE INSERT ON "crm"."commercial_outcomes" FOR EACH ROW EXECUTE FUNCTION "crm"."validate_commercial_outcome"();



CREATE CONSTRAINT TRIGGER "commercial_outcomes_validate_opportunity_consistency" AFTER INSERT OR DELETE OR UPDATE ON "crm"."commercial_outcomes" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "crm"."validate_opportunity_outcome_consistency"();



CREATE OR REPLACE TRIGGER "opportunities_bump_stage_version" BEFORE UPDATE OF "current_stage_id" ON "crm"."opportunities" FOR EACH ROW EXECUTE FUNCTION "crm"."bump_stage_version"();



CREATE OR REPLACE TRIGGER "opportunities_emit_stage_event" AFTER INSERT OR UPDATE OF "current_stage_id" ON "crm"."opportunities" FOR EACH ROW EXECUTE FUNCTION "crm"."emit_opportunity_stage_event"();



CREATE OR REPLACE TRIGGER "opportunities_validate" BEFORE INSERT OR UPDATE ON "crm"."opportunities" FOR EACH ROW EXECUTE FUNCTION "crm"."validate_opportunity"();



CREATE CONSTRAINT TRIGGER "opportunities_validate_latest_history" AFTER UPDATE ON "crm"."opportunities" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "crm"."validate_opportunity_history_consistency"();



CREATE CONSTRAINT TRIGGER "opportunities_validate_outcome_consistency" AFTER INSERT OR UPDATE ON "crm"."opportunities" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "crm"."validate_opportunity_outcome_consistency"();



CREATE OR REPLACE TRIGGER "opportunities_validate_owners" BEFORE INSERT OR UPDATE OF "tenant_id", "crc_owner_profile_id", "sales_owner_profile_id" ON "crm"."opportunities" FOR EACH ROW EXECUTE FUNCTION "crm"."validate_opportunity_owners"();



CREATE OR REPLACE TRIGGER "opportunity_milestones_append_only" BEFORE DELETE OR UPDATE ON "crm"."opportunity_milestones" FOR EACH ROW EXECUTE FUNCTION "crm"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "opportunity_stage_history_append_only" BEFORE DELETE OR UPDATE ON "crm"."opportunity_stage_history" FOR EACH ROW EXECUTE FUNCTION "crm"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "opportunity_stage_history_validate" BEFORE INSERT ON "crm"."opportunity_stage_history" FOR EACH ROW EXECUTE FUNCTION "crm"."validate_stage_history"();



CREATE CONSTRAINT TRIGGER "opportunity_stage_history_validate_current_stage" AFTER INSERT ON "crm"."opportunity_stage_history" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "crm"."validate_opportunity_history_consistency"();



CREATE OR REPLACE TRIGGER "processed_events_validate" BEFORE INSERT OR UPDATE ON "crm"."processed_events" FOR EACH ROW EXECUTE FUNCTION "crm"."validate_processed_event"();



CREATE OR REPLACE TRIGGER "trg_external_ga4_raw_updated_at" BEFORE UPDATE ON "public"."external_ga4_raw" FOR EACH ROW EXECUTE FUNCTION "public"."fn_external_raw_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_external_hotmart_raw_updated_at" BEFORE UPDATE ON "public"."external_hotmart_raw" FOR EACH ROW EXECUTE FUNCTION "public"."fn_external_raw_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_external_meta_ads_raw_updated_at" BEFORE UPDATE ON "public"."external_meta_ads_raw" FOR EACH ROW EXECUTE FUNCTION "public"."fn_external_raw_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_stevo_events_raw_slim" BEFORE INSERT ON "public"."stevo_events_raw" FOR EACH ROW EXECUTE FUNCTION "public"."fn_stevo_events_raw_slim"();



CREATE OR REPLACE TRIGGER "trg_wf_logs_set_duration" BEFORE INSERT OR UPDATE ON "public"."workflow_execution_logs" FOR EACH ROW EXECUTE FUNCTION "public"."fn_workflow_execution_logs_set_duration"();



ALTER TABLE ONLY "crm"."activities"
    ADD CONSTRAINT "activities_raw_event_id_fkey" FOREIGN KEY ("raw_event_id") REFERENCES "public"."stevo_events_raw"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."activities"
    ADD CONSTRAINT "activities_tenant_id_actor_profile_id_fkey" FOREIGN KEY ("tenant_id", "actor_profile_id") REFERENCES "crm"."tenant_memberships"("tenant_id", "profile_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."activities"
    ADD CONSTRAINT "activities_tenant_id_contact_id_fkey" FOREIGN KEY ("tenant_id", "contact_id") REFERENCES "crm"."contacts"("tenant_id", "id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."activities"
    ADD CONSTRAINT "activities_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "crm"."tenants"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."activities"
    ADD CONSTRAINT "activities_tenant_id_opportunity_id_fkey" FOREIGN KEY ("tenant_id", "opportunity_id") REFERENCES "crm"."opportunities"("tenant_id", "id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."commercial_outcomes"
    ADD CONSTRAINT "commercial_outcomes_loss_reason_id_fkey" FOREIGN KEY ("loss_reason_id") REFERENCES "crm"."canonical_loss_reasons"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."commercial_outcomes"
    ADD CONSTRAINT "commercial_outcomes_tenant_id_actor_profile_id_fkey" FOREIGN KEY ("tenant_id", "actor_profile_id") REFERENCES "crm"."tenant_memberships"("tenant_id", "profile_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."commercial_outcomes"
    ADD CONSTRAINT "commercial_outcomes_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "crm"."tenants"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."commercial_outcomes"
    ADD CONSTRAINT "commercial_outcomes_tenant_id_opportunity_id_fkey" FOREIGN KEY ("tenant_id", "opportunity_id") REFERENCES "crm"."opportunities"("tenant_id", "id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."contact_identities"
    ADD CONSTRAINT "contact_identities_tenant_id_contact_id_fkey" FOREIGN KEY ("tenant_id", "contact_id") REFERENCES "crm"."contacts"("tenant_id", "id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."contact_identities"
    ADD CONSTRAINT "contact_identities_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "crm"."tenants"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."contacts"
    ADD CONSTRAINT "contacts_tenant_id_default_owner_profile_id_fkey" FOREIGN KEY ("tenant_id", "default_owner_profile_id") REFERENCES "crm"."tenant_memberships"("tenant_id", "profile_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."contacts"
    ADD CONSTRAINT "contacts_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "crm"."tenants"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."global_pipeline_stages"
    ADD CONSTRAINT "global_pipeline_stages_pipeline_version_id_fkey" FOREIGN KEY ("pipeline_version_id") REFERENCES "crm"."global_pipeline_versions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunities"
    ADD CONSTRAINT "opportunities_current_stage_id_fkey" FOREIGN KEY ("current_stage_id") REFERENCES "crm"."global_pipeline_stages"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunities"
    ADD CONSTRAINT "opportunities_pipeline_version_id_fkey" FOREIGN KEY ("pipeline_version_id") REFERENCES "crm"."global_pipeline_versions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunities"
    ADD CONSTRAINT "opportunities_tenant_crc_owner_profile_id_fkey" FOREIGN KEY ("tenant_id", "crc_owner_profile_id") REFERENCES "crm"."tenant_memberships"("tenant_id", "profile_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunities"
    ADD CONSTRAINT "opportunities_tenant_id_contact_id_fkey" FOREIGN KEY ("tenant_id", "contact_id") REFERENCES "crm"."contacts"("tenant_id", "id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunities"
    ADD CONSTRAINT "opportunities_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "crm"."tenants"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunities"
    ADD CONSTRAINT "opportunities_tenant_id_previous_opportunity_id_fkey" FOREIGN KEY ("tenant_id", "previous_opportunity_id") REFERENCES "crm"."opportunities"("tenant_id", "id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunities"
    ADD CONSTRAINT "opportunities_tenant_sales_owner_profile_id_fkey" FOREIGN KEY ("tenant_id", "sales_owner_profile_id") REFERENCES "crm"."tenant_memberships"("tenant_id", "profile_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunity_milestones"
    ADD CONSTRAINT "opportunity_milestones_tenant_id_actor_profile_id_fkey" FOREIGN KEY ("tenant_id", "actor_profile_id") REFERENCES "crm"."tenant_memberships"("tenant_id", "profile_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunity_milestones"
    ADD CONSTRAINT "opportunity_milestones_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "crm"."tenants"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunity_milestones"
    ADD CONSTRAINT "opportunity_milestones_tenant_id_opportunity_id_fkey" FOREIGN KEY ("tenant_id", "opportunity_id") REFERENCES "crm"."opportunities"("tenant_id", "id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunity_stage_history"
    ADD CONSTRAINT "opportunity_stage_history_from_stage_id_fkey" FOREIGN KEY ("from_stage_id") REFERENCES "crm"."global_pipeline_stages"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunity_stage_history"
    ADD CONSTRAINT "opportunity_stage_history_tenant_id_actor_profile_id_fkey" FOREIGN KEY ("tenant_id", "actor_profile_id") REFERENCES "crm"."tenant_memberships"("tenant_id", "profile_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunity_stage_history"
    ADD CONSTRAINT "opportunity_stage_history_tenant_id_compensates_history_id_fkey" FOREIGN KEY ("tenant_id", "compensates_history_id", "opportunity_id") REFERENCES "crm"."opportunity_stage_history"("tenant_id", "id", "opportunity_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunity_stage_history"
    ADD CONSTRAINT "opportunity_stage_history_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "crm"."tenants"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunity_stage_history"
    ADD CONSTRAINT "opportunity_stage_history_tenant_id_opportunity_id_fkey" FOREIGN KEY ("tenant_id", "opportunity_id") REFERENCES "crm"."opportunities"("tenant_id", "id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunity_stage_history"
    ADD CONSTRAINT "opportunity_stage_history_tenant_id_source_activity_id_fkey" FOREIGN KEY ("tenant_id", "source_activity_id") REFERENCES "crm"."activities"("tenant_id", "id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."opportunity_stage_history"
    ADD CONSTRAINT "opportunity_stage_history_to_stage_id_fkey" FOREIGN KEY ("to_stage_id") REFERENCES "crm"."global_pipeline_stages"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."processed_events"
    ADD CONSTRAINT "processed_events_raw_event_id_fkey" FOREIGN KEY ("raw_event_id") REFERENCES "public"."stevo_events_raw"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."processed_events"
    ADD CONSTRAINT "processed_events_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "crm"."tenants"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."tenant_memberships"
    ADD CONSTRAINT "tenant_memberships_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "crm"."profiles"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."tenant_memberships"
    ADD CONSTRAINT "tenant_memberships_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "crm"."tenants"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "crm"."tenants"
    ADD CONSTRAINT "tenants_id_fkey" FOREIGN KEY ("id") REFERENCES "public"."clients_base"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."client_google_ads_accounts"
    ADD CONSTRAINT "client_google_ads_accounts_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_meta_ad_accounts"
    ADD CONSTRAINT "client_meta_ad_accounts_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_users"
    ADD CONSTRAINT "client_users_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_users"
    ADD CONSTRAINT "client_users_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."database_documentation_registry"
    ADD CONSTRAINT "database_documentation_registry_supersedes_id_fkey" FOREIGN KEY ("supersedes_id") REFERENCES "public"."database_documentation_registry"("id");



ALTER TABLE ONLY "public"."events_normalized"
    ADD CONSTRAINT "events_normalized_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id");



ALTER TABLE ONLY "public"."events_normalized"
    ADD CONSTRAINT "events_normalized_raw_event_id_fkey" FOREIGN KEY ("raw_event_id") REFERENCES "public"."events_raw"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_ga4_raw"
    ADD CONSTRAINT "external_ga4_raw_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_hotmart_raw"
    ADD CONSTRAINT "external_hotmart_raw_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_meta_ads_raw"
    ADD CONSTRAINT "external_meta_ads_raw_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."google_ads_campaign_daily"
    ADD CONSTRAINT "google_ads_campaign_daily_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."google_ads_daily"
    ADD CONSTRAINT "google_ads_daily_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."google_ads_keywords_daily"
    ADD CONSTRAINT "google_ads_keywords_daily_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id");



ALTER TABLE ONLY "public"."meta_ads_daily"
    ADD CONSTRAINT "meta_ads_daily_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stevo_events_raw"
    ADD CONSTRAINT "stevo_events_raw_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."stevo_events_raw"
    ADD CONSTRAINT "stevo_events_raw_stevo_instance_row_id_fkey" FOREIGN KEY ("stevo_instance_row_id") REFERENCES "public"."stevo_instances"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."stevo_instances"
    ADD CONSTRAINT "stevo_instances_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."workflow_execution_logs"
    ADD CONSTRAINT "workflow_execution_logs_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients_base"("id");



ALTER TABLE "crm"."activities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."canonical_loss_reasons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."commercial_outcomes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."contact_identities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."event_map" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."global_pipeline_stages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."global_pipeline_versions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "global_read_loss_reasons" ON "crm"."canonical_loss_reasons" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "global_read_pipeline_stages" ON "crm"."global_pipeline_stages" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "global_read_pipeline_versions" ON "crm"."global_pipeline_versions" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "crm"."opportunities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."opportunity_milestones" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."opportunity_stage_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."processed_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "crm"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "service_write_activities" ON "crm"."activities" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_commercial_outcomes" ON "crm"."commercial_outcomes" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_contact_identities" ON "crm"."contact_identities" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_contacts" ON "crm"."contacts" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_loss_reasons" ON "crm"."canonical_loss_reasons" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_memberships" ON "crm"."tenant_memberships" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_milestones" ON "crm"."opportunity_milestones" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_opportunities" ON "crm"."opportunities" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_pipeline_stages" ON "crm"."global_pipeline_stages" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_pipeline_versions" ON "crm"."global_pipeline_versions" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_processed_events" ON "crm"."processed_events" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_profiles" ON "crm"."profiles" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_stage_history" ON "crm"."opportunity_stage_history" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_write_tenants" ON "crm"."tenants" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "crm"."tenant_memberships" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tenant_read_activities" ON "crm"."activities" FOR SELECT TO "authenticated" USING ("crm"."is_member"("tenant_id"));



CREATE POLICY "tenant_read_commercial_outcomes" ON "crm"."commercial_outcomes" FOR SELECT TO "authenticated" USING ("crm"."is_member"("tenant_id"));



CREATE POLICY "tenant_read_contact_identities" ON "crm"."contact_identities" FOR SELECT TO "authenticated" USING ("crm"."is_member"("tenant_id"));



CREATE POLICY "tenant_read_contacts" ON "crm"."contacts" FOR SELECT TO "authenticated" USING ("crm"."is_member"("tenant_id"));



CREATE POLICY "tenant_read_memberships" ON "crm"."tenant_memberships" FOR SELECT TO "authenticated" USING ("crm"."is_member"("tenant_id"));



CREATE POLICY "tenant_read_milestones" ON "crm"."opportunity_milestones" FOR SELECT TO "authenticated" USING ("crm"."is_member"("tenant_id"));



CREATE POLICY "tenant_read_opportunities" ON "crm"."opportunities" FOR SELECT TO "authenticated" USING ("crm"."is_member"("tenant_id"));



CREATE POLICY "tenant_read_processed_events" ON "crm"."processed_events" FOR SELECT TO "authenticated" USING ("crm"."is_member"("tenant_id"));



CREATE POLICY "tenant_read_profiles" ON "crm"."profiles" FOR SELECT TO "authenticated" USING ((("id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "crm"."tenant_memberships" "m"
  WHERE (("m"."profile_id" = "profiles"."id") AND ("m"."status" = 'active'::"text") AND "crm"."is_member"("m"."tenant_id"))))));



CREATE POLICY "tenant_read_stage_history" ON "crm"."opportunity_stage_history" FOR SELECT TO "authenticated" USING ("crm"."is_member"("tenant_id"));



CREATE POLICY "tenant_read_tenants" ON "crm"."tenants" FOR SELECT TO "authenticated" USING ("crm"."is_member"("id"));



ALTER TABLE "crm"."tenants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_google_ads_accounts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "client_google_ads_accounts_select_by_client_user" ON "public"."client_google_ads_accounts" FOR SELECT TO "authenticated" USING ("private"."user_can_access_client"("client_id"));



ALTER TABLE "public"."client_meta_ad_accounts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "client_meta_ad_accounts_select_by_client_user" ON "public"."client_meta_ad_accounts" FOR SELECT TO "authenticated" USING ("private"."user_can_access_client"("client_id"));



ALTER TABLE "public"."client_users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "client_users_select_own" ON "public"."client_users" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."clients_base" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "clients_base_select_by_client_user" ON "public"."clients_base" FOR SELECT TO "authenticated" USING ("private"."user_can_access_client"("id"));



ALTER TABLE "public"."conversion_outbox" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."database_documentation_registry" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."events_normalized" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "events_normalized_select_by_client_user" ON "public"."events_normalized" FOR SELECT TO "authenticated" USING (("client_id" IN ( SELECT "client_id"."client_id"
   FROM "private"."my_client_ids"() "client_id"("client_id"))));



ALTER TABLE "public"."events_raw" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."external_ga4_raw" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."external_hotmart_raw" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."external_meta_ads_raw" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."form_intake_rate_limit" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."google_ads_campaign_daily" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "google_ads_campaign_daily_select_by_client" ON "public"."google_ads_campaign_daily" FOR SELECT TO "authenticated" USING (("client_id" IN ( SELECT "financial_client_ids"."client_id"
   FROM "private"."financial_client_ids"() "financial_client_ids"("client_id"))));



ALTER TABLE "public"."google_ads_daily" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "google_ads_daily_select_by_client_user" ON "public"."google_ads_daily" FOR SELECT TO "authenticated" USING (("client_id" IN ( SELECT "financial_client_ids"."client_id"
   FROM "private"."financial_client_ids"() "financial_client_ids"("client_id"))));



ALTER TABLE "public"."google_ads_keywords_daily" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "google_ads_keywords_daily_select_by_client_user" ON "public"."google_ads_keywords_daily" FOR SELECT TO "authenticated" USING (("client_id" IN ( SELECT "financial_client_ids"."client_id"
   FROM "private"."financial_client_ids"() "financial_client_ids"("client_id"))));



ALTER TABLE "public"."meta_ads_daily" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "meta_ads_daily_select_by_client_user" ON "public"."meta_ads_daily" FOR SELECT TO "authenticated" USING (("client_id" IN ( SELECT "financial_client_ids"."client_id"
   FROM "private"."financial_client_ids"() "financial_client_ids"("client_id"))));



ALTER TABLE "public"."meta_leads_export_temp_temp" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stevo_events_raw" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "stevo_events_raw_select_by_client_user" ON "public"."stevo_events_raw" FOR SELECT TO "authenticated" USING ((("client_id" IS NOT NULL) AND "private"."user_can_access_client"("client_id")));



ALTER TABLE "public"."stevo_instances" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "stevo_instances_select_by_client_user" ON "public"."stevo_instances" FOR SELECT TO "authenticated" USING ((("client_id" IS NOT NULL) AND "private"."user_can_access_client"("client_id")));



ALTER TABLE "public"."workflow_execution_logs" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "crm" TO "authenticated";
GRANT USAGE ON SCHEMA "crm" TO "service_role";



GRANT USAGE ON SCHEMA "private" TO "authenticated";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "crm"."bump_stage_version"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."can_write"("p_tenant_id" "uuid", "p_profile_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "crm"."can_write"("p_tenant_id" "uuid", "p_profile_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "crm"."emit_opportunity_stage_event"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."is_member"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "crm"."is_member"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "crm"."is_member"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "crm"."reject_append_only_mutation"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."restrict_outcome_revision"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."stevo_ctwa_clid"("p_conversion_data" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."stevo_message_body"("p_message" "jsonb", "p_text" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."stevo_parse_messages"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "crm"."stevo_parse_messages"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "crm"."validate_activity_raw_tenant"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."validate_commercial_outcome"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."validate_opportunity"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."validate_opportunity_history_consistency"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."validate_opportunity_outcome_consistency"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."validate_opportunity_owners"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."validate_processed_event"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "crm"."validate_stage_history"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."can_view_client_financials"("p_client_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."can_view_client_financials"("p_client_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "private"."can_view_client_financials"("p_client_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "private"."financial_client_ids"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."financial_client_ids"() TO "authenticated";
GRANT ALL ON FUNCTION "private"."financial_client_ids"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."is_agency_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."is_agency_user"() TO "service_role";
GRANT ALL ON FUNCTION "private"."is_agency_user"() TO "authenticated";



REVOKE ALL ON FUNCTION "private"."my_client_ids"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."my_client_ids"() TO "authenticated";



REVOKE ALL ON FUNCTION "private"."user_can_access_client"("p_client_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."user_can_access_client"("p_client_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."am_i_agency_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."am_i_agency_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."am_i_agency_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."crm_board_counts"("p_client_id" "uuid", "p_opened_from" "date", "p_opened_to" "date", "p_owner_role" "text", "p_owner_profile_id" "uuid", "p_unassigned" boolean, "p_origin" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_board_counts"("p_client_id" "uuid", "p_opened_from" "date", "p_opened_to" "date", "p_owner_role" "text", "p_owner_profile_id" "uuid", "p_unassigned" boolean, "p_origin" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_board_counts"("p_client_id" "uuid", "p_opened_from" "date", "p_opened_to" "date", "p_owner_role" "text", "p_owner_profile_id" "uuid", "p_unassigned" boolean, "p_origin" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."crm_guard"("p_opportunity_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_guard"("p_opportunity_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_guard"("p_opportunity_id" "uuid") TO "service_role";



GRANT SELECT ON TABLE "crm"."activities" TO "authenticated";
GRANT ALL ON TABLE "crm"."activities" TO "service_role";



GRANT SELECT ON TABLE "crm"."contacts" TO "authenticated";
GRANT ALL ON TABLE "crm"."contacts" TO "service_role";



GRANT SELECT ON TABLE "crm"."global_pipeline_stages" TO "authenticated";
GRANT ALL ON TABLE "crm"."global_pipeline_stages" TO "service_role";



GRANT SELECT ON TABLE "crm"."opportunities" TO "authenticated";
GRANT ALL ON TABLE "crm"."opportunities" TO "service_role";



GRANT SELECT ON TABLE "crm"."profiles" TO "authenticated";
GRANT ALL ON TABLE "crm"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."clients_base" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("client_name") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("status") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("timezone") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("created_at") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("updated_at") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("client_slug") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("currency") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("tracking_status") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("tracking_ready") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("meta_ready") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("google_ads_ready") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("meta_ads_sync_ready") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("google_ads_sync_ready") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("sync_ready") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("meta_ads_last_backfill_at") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("google_ads_last_backfill_at") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("meta_ads_last_sync_at") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT("google_ads_last_sync_at") ON TABLE "public"."clients_base" TO "authenticated";



GRANT SELECT ON TABLE "public"."meta_ads_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."meta_ads_daily" TO "service_role";



GRANT ALL ON TABLE "public"."v_meta_ads_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."v_meta_ads_v2" TO "authenticated";



GRANT ALL ON TABLE "public"."v_crm_cards_v1" TO "authenticated";
GRANT ALL ON TABLE "public"."v_crm_cards_v1" TO "service_role";



REVOKE ALL ON FUNCTION "public"."crm_move_stage"("p_opportunity_id" "uuid", "p_to_stage_code" "text", "p_expected_stage_version" integer, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_move_stage"("p_opportunity_id" "uuid", "p_to_stage_code" "text", "p_expected_stage_version" integer, "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_move_stage"("p_opportunity_id" "uuid", "p_to_stage_code" "text", "p_expected_stage_version" integer, "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."crm_register_lost"("p_opportunity_id" "uuid", "p_loss_reason_code" "text", "p_expected_stage_version" integer, "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_register_lost"("p_opportunity_id" "uuid", "p_loss_reason_code" "text", "p_expected_stage_version" integer, "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_register_lost"("p_opportunity_id" "uuid", "p_loss_reason_code" "text", "p_expected_stage_version" integer, "p_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."crm_register_won"("p_opportunity_id" "uuid", "p_evidence" "text", "p_expected_stage_version" integer, "p_value" numeric, "p_currency" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_register_won"("p_opportunity_id" "uuid", "p_evidence" "text", "p_expected_stage_version" integer, "p_value" numeric, "p_currency" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_register_won"("p_opportunity_id" "uuid", "p_evidence" "text", "p_expected_stage_version" integer, "p_value" numeric, "p_currency" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."crm_set_owner"("p_opportunity_id" "uuid", "p_role" "text", "p_owner_profile_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_set_owner"("p_opportunity_id" "uuid", "p_role" "text", "p_owner_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_set_owner"("p_opportunity_id" "uuid", "p_role" "text", "p_owner_profile_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_external_raw_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_external_raw_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_external_raw_set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_stevo_events_raw_slim"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_stevo_events_raw_slim"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_stevo_events_raw_slim"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_workflow_execution_logs_set_duration"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_workflow_execution_logs_set_duration"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_workflow_execution_logs_set_duration"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_client_overview_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_client_overview_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_client_overview_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_google_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_google_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_google_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_internal_agency_overview"("p_start_date" "date", "p_end_date" "date", "p_client_ids" "uuid"[], "p_include_not_ready" boolean, "p_search" "text", "p_sort_by" "text", "p_sort_direction" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_internal_agency_overview"("p_start_date" "date", "p_end_date" "date", "p_client_ids" "uuid"[], "p_include_not_ready" boolean, "p_search" "text", "p_sort_by" "text", "p_sort_direction" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_internal_agency_overview"("p_start_date" "date", "p_end_date" "date", "p_client_ids" "uuid"[], "p_include_not_ready" boolean, "p_search" "text", "p_sort_by" "text", "p_sort_direction" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_internal_operations_feed"("p_section" "text", "p_event_layer" "text", "p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_status" "text", "p_search" "text", "p_limit" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_internal_operations_feed"("p_section" "text", "p_event_layer" "text", "p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_status" "text", "p_search" "text", "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_internal_operations_feed"("p_section" "text", "p_event_layer" "text", "p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_status" "text", "p_search" "text", "p_limit" integer, "p_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_meta_account_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_meta_account_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_meta_account_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_meta_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_meta_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_meta_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_meta_campaign_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_meta_campaign_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_meta_campaign_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_meta_creative_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_meta_creative_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_meta_creative_summary"("p_client_id" "uuid", "p_start" "date", "p_end" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."intake_form_lead"("p_client_slug" "text", "p_form_intake_token" "uuid", "p_full_name" "text", "p_phone" "text", "p_email" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text", "p_utm_source" "text", "p_utm_medium" "text", "p_utm_campaign" "text", "p_utm_content" "text", "p_utm_term" "text", "p_page_url" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."intake_form_lead"("p_client_slug" "text", "p_form_intake_token" "uuid", "p_full_name" "text", "p_phone" "text", "p_email" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text", "p_utm_source" "text", "p_utm_medium" "text", "p_utm_campaign" "text", "p_utm_content" "text", "p_utm_term" "text", "p_page_url" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_channel_source"("p_lead_origem" "text", "p_lead_entrada" "text", "p_meta_ad_id" "text", "p_google_campaign_id" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_channel_source"("p_lead_origem" "text", "p_lead_entrada" "text", "p_meta_ad_id" "text", "p_google_campaign_id" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_channel_source"("p_lead_origem" "text", "p_lead_entrada" "text", "p_meta_ad_id" "text", "p_google_campaign_id" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."resolve_lead_channel_v2"("p_lead_origem" "text", "p_meta_ad_id" "text", "p_google_campaign_id" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_lead_channel_v2"("p_lead_origem" "text", "p_meta_ad_id" "text", "p_google_campaign_id" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_lead_channel_v2"("p_lead_origem" "text", "p_meta_ad_id" "text", "p_google_campaign_id" "text", "p_gclid" "text", "p_gbraid" "text", "p_wbraid" "text") TO "service_role";



GRANT SELECT ON TABLE "crm"."canonical_loss_reasons" TO "authenticated";
GRANT ALL ON TABLE "crm"."canonical_loss_reasons" TO "service_role";



GRANT SELECT ON TABLE "crm"."commercial_outcomes" TO "authenticated";
GRANT ALL ON TABLE "crm"."commercial_outcomes" TO "service_role";



GRANT SELECT ON TABLE "crm"."contact_identities" TO "authenticated";
GRANT ALL ON TABLE "crm"."contact_identities" TO "service_role";



GRANT ALL ON TABLE "crm"."event_map" TO "service_role";



GRANT SELECT ON TABLE "crm"."global_pipeline_versions" TO "authenticated";
GRANT ALL ON TABLE "crm"."global_pipeline_versions" TO "service_role";



GRANT SELECT ON TABLE "crm"."opportunity_milestones" TO "authenticated";
GRANT ALL ON TABLE "crm"."opportunity_milestones" TO "service_role";



GRANT SELECT ON TABLE "crm"."opportunity_stage_history" TO "authenticated";
GRANT ALL ON TABLE "crm"."opportunity_stage_history" TO "service_role";



GRANT SELECT ON TABLE "crm"."processed_events" TO "authenticated";
GRANT ALL ON TABLE "crm"."processed_events" TO "service_role";



GRANT SELECT ON TABLE "crm"."tenant_memberships" TO "authenticated";
GRANT ALL ON TABLE "crm"."tenant_memberships" TO "service_role";



GRANT SELECT ON TABLE "crm"."tenants" TO "authenticated";
GRANT ALL ON TABLE "crm"."tenants" TO "service_role";



GRANT ALL ON TABLE "public"."client_google_ads_accounts" TO "anon";
GRANT ALL ON TABLE "public"."client_google_ads_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."client_google_ads_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."client_meta_ad_accounts" TO "anon";
GRANT ALL ON TABLE "public"."client_meta_ad_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."client_meta_ad_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."client_users" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."client_users" TO "authenticated";



GRANT SELECT("client_id") ON TABLE "public"."client_users" TO "authenticated";



GRANT SELECT("user_id") ON TABLE "public"."client_users" TO "authenticated";



GRANT SELECT("role") ON TABLE "public"."client_users" TO "authenticated";



GRANT SELECT("is_active") ON TABLE "public"."client_users" TO "authenticated";



GRANT SELECT("created_at") ON TABLE "public"."client_users" TO "authenticated";



GRANT SELECT("updated_at") ON TABLE "public"."client_users" TO "authenticated";



GRANT ALL ON TABLE "public"."conversion_outbox" TO "service_role";



GRANT ALL ON TABLE "public"."database_documentation_registry" TO "anon";
GRANT ALL ON TABLE "public"."database_documentation_registry" TO "authenticated";
GRANT ALL ON TABLE "public"."database_documentation_registry" TO "service_role";



GRANT ALL ON TABLE "public"."events_normalized" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("raw_event_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("client_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("ghl_location_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("ghl_location_name") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("client_name") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("event_code") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("event_name") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("funnel_step") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("event_datetime") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("source_system") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("source_event_type") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("source_workflow_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("source_workflow_name") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("contact_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("first_name") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("last_name") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("full_name") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("phone") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("email") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("contact_type") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("tags") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("lead_origem") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("lead_entrada") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("lead_agencias") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("conversion_source") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("entry_point_conversion_source") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("entry_point_conversion_app") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("source_type") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("source_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("source_url") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("source_ads") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("ad_title") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("ctwa_clid") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("ctwa_payload") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("fbp") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("fbc") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("fbclid") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("gclid") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("gbraid") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("wbraid") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("ga_client_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("ga_session_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("procedure_interest") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("procedure_closed") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("loss_reason_category") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("loss_reason_detail") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("normalization_status") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("normalization_error") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("created_at") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("updated_at") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("received_at") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("location_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("location_name") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("opportunity_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("pipeline_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("pipeline_name") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("pipeline_stage") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("status") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("phone_raw") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("utm_source") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("utm_medium") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("utm_campaign") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("utm_content") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("utm_term") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("procedimento_ganho") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("motivo_perda_categoria") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("motivo_perda_detalhe") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("google_campaign_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("google_adgroup_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("google_ad_id") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("google_keyword") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("google_network") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("google_device") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("produto_servico") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT SELECT("categoria_produto_servico") ON TABLE "public"."events_normalized" TO "authenticated";



GRANT ALL ON TABLE "public"."events_raw" TO "service_role";



GRANT ALL ON TABLE "public"."external_ga4_raw" TO "service_role";



GRANT ALL ON TABLE "public"."external_hotmart_raw" TO "service_role";



GRANT ALL ON TABLE "public"."external_meta_ads_raw" TO "service_role";



GRANT ALL ON TABLE "public"."form_intake_rate_limit" TO "service_role";



GRANT ALL ON TABLE "public"."google_ads_campaign_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."google_ads_campaign_daily" TO "service_role";



GRANT SELECT ON TABLE "public"."google_ads_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."google_ads_daily" TO "service_role";



GRANT ALL ON TABLE "public"."google_ads_keywords_daily" TO "anon";
GRANT ALL ON TABLE "public"."google_ads_keywords_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."google_ads_keywords_daily" TO "service_role";



GRANT ALL ON TABLE "public"."meta_leads_export_temp_temp" TO "anon";
GRANT ALL ON TABLE "public"."meta_leads_export_temp_temp" TO "authenticated";
GRANT ALL ON TABLE "public"."meta_leads_export_temp_temp" TO "service_role";



GRANT ALL ON TABLE "public"."stevo_events_raw" TO "service_role";



GRANT ALL ON TABLE "public"."stevo_instances" TO "anon";
GRANT ALL ON TABLE "public"."stevo_instances" TO "authenticated";
GRANT ALL ON TABLE "public"."stevo_instances" TO "service_role";



GRANT ALL ON TABLE "public"."v_ads_spend_daily" TO "service_role";
GRANT SELECT ON TABLE "public"."v_ads_spend_daily" TO "authenticated";



GRANT ALL ON TABLE "public"."v_crm_events_enriched" TO "service_role";
GRANT SELECT ON TABLE "public"."v_crm_events_enriched" TO "authenticated";



GRANT ALL ON TABLE "public"."v_crm_funnel_daily" TO "service_role";
GRANT SELECT ON TABLE "public"."v_crm_funnel_daily" TO "authenticated";



GRANT ALL ON TABLE "public"."v_channel_performance_daily" TO "service_role";
GRANT SELECT ON TABLE "public"."v_channel_performance_daily" TO "authenticated";



GRANT ALL ON TABLE "public"."v_client_daily_pulse" TO "service_role";
GRANT SELECT ON TABLE "public"."v_client_daily_pulse" TO "authenticated";



GRANT ALL ON TABLE "public"."v_client_lead_channel_daily" TO "anon";
GRANT ALL ON TABLE "public"."v_client_lead_channel_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."v_client_lead_channel_daily" TO "service_role";



GRANT ALL ON TABLE "public"."v_client_leads_by_stage" TO "anon";
GRANT ALL ON TABLE "public"."v_client_leads_by_stage" TO "authenticated";
GRANT ALL ON TABLE "public"."v_client_leads_by_stage" TO "service_role";



GRANT ALL ON TABLE "public"."v_crm_lead_journey_v2" TO "authenticated";
GRANT ALL ON TABLE "public"."v_crm_lead_journey_v2" TO "service_role";



GRANT ALL ON TABLE "public"."v_client_leads_by_stage_v2" TO "anon";
GRANT ALL ON TABLE "public"."v_client_leads_by_stage_v2" TO "authenticated";
GRANT ALL ON TABLE "public"."v_client_leads_by_stage_v2" TO "service_role";



GRANT ALL ON TABLE "public"."v_client_performance_daily" TO "service_role";
GRANT SELECT ON TABLE "public"."v_client_performance_daily" TO "authenticated";



GRANT ALL ON TABLE "public"."v_crm_opportunities_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."v_crm_opportunities_v2" TO "authenticated";



GRANT ALL ON TABLE "public"."v_crm_sales_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."v_crm_sales_v2" TO "authenticated";



GRANT ALL ON TABLE "public"."v_crm_sales_daily_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."v_crm_sales_daily_v2" TO "authenticated";



GRANT ALL ON TABLE "public"."v_google_ads_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."v_google_ads_v2" TO "authenticated";



GRANT ALL ON TABLE "public"."v_client_performance_daily_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."v_client_performance_daily_v2" TO "authenticated";



GRANT ALL ON TABLE "public"."v_client_profile_safe" TO "anon";
GRANT ALL ON TABLE "public"."v_client_profile_safe" TO "authenticated";
GRANT ALL ON TABLE "public"."v_client_profile_safe" TO "service_role";



GRANT ALL ON TABLE "public"."v_client_recent_events" TO "anon";
GRANT ALL ON TABLE "public"."v_client_recent_events" TO "authenticated";
GRANT ALL ON TABLE "public"."v_client_recent_events" TO "service_role";



GRANT ALL ON TABLE "public"."workflow_execution_logs" TO "service_role";



GRANT ALL ON TABLE "public"."v_client_workflow_health" TO "anon";
GRANT ALL ON TABLE "public"."v_client_workflow_health" TO "authenticated";
GRANT ALL ON TABLE "public"."v_client_workflow_health" TO "service_role";



GRANT ALL ON TABLE "public"."v_crm_activities_v1" TO "anon";
GRANT ALL ON TABLE "public"."v_crm_activities_v1" TO "authenticated";
GRANT ALL ON TABLE "public"."v_crm_activities_v1" TO "service_role";



GRANT ALL ON TABLE "public"."v_crm_board_counts_v1" TO "anon";
GRANT ALL ON TABLE "public"."v_crm_board_counts_v1" TO "authenticated";
GRANT ALL ON TABLE "public"."v_crm_board_counts_v1" TO "service_role";



GRANT ALL ON TABLE "public"."v_crm_card_history_v1" TO "service_role";
GRANT SELECT ON TABLE "public"."v_crm_card_history_v1" TO "authenticated";



GRANT ALL ON TABLE "public"."v_crm_channels_daily_v2" TO "anon";
GRANT ALL ON TABLE "public"."v_crm_channels_daily_v2" TO "authenticated";
GRANT ALL ON TABLE "public"."v_crm_channels_daily_v2" TO "service_role";



GRANT ALL ON TABLE "public"."v_crm_contacts_v1" TO "authenticated";
GRANT ALL ON TABLE "public"."v_crm_contacts_v1" TO "service_role";



GRANT ALL ON TABLE "public"."v_crm_events_feed_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."v_crm_events_feed_v2" TO "authenticated";



GRANT ALL ON TABLE "public"."v_crm_events_daily_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."v_crm_events_daily_v2" TO "authenticated";



GRANT ALL ON TABLE "public"."v_crm_funnel_daily_v2" TO "anon";
GRANT ALL ON TABLE "public"."v_crm_funnel_daily_v2" TO "authenticated";
GRANT ALL ON TABLE "public"."v_crm_funnel_daily_v2" TO "service_role";



GRANT ALL ON TABLE "public"."v_crm_loss_reasons_v1" TO "anon";
GRANT ALL ON TABLE "public"."v_crm_loss_reasons_v1" TO "authenticated";
GRANT ALL ON TABLE "public"."v_crm_loss_reasons_v1" TO "service_role";



GRANT ALL ON TABLE "public"."v_crm_my_role_v1" TO "anon";
GRANT ALL ON TABLE "public"."v_crm_my_role_v1" TO "authenticated";
GRANT ALL ON TABLE "public"."v_crm_my_role_v1" TO "service_role";



GRANT ALL ON TABLE "public"."v_crm_opportunities" TO "service_role";
GRANT SELECT ON TABLE "public"."v_crm_opportunities" TO "authenticated";



GRANT ALL ON TABLE "public"."v_crm_owners_v1" TO "authenticated";
GRANT ALL ON TABLE "public"."v_crm_owners_v1" TO "service_role";



GRANT ALL ON TABLE "public"."v_data_quality_v2" TO "authenticated";
GRANT ALL ON TABLE "public"."v_data_quality_v2" TO "service_role";



GRANT ALL ON TABLE "public"."v_event_tracking_audit" TO "authenticated";
GRANT ALL ON TABLE "public"."v_event_tracking_audit" TO "service_role";



GRANT ALL ON TABLE "public"."v_google_ads_keywords_daily" TO "service_role";
GRANT SELECT ON TABLE "public"."v_google_ads_keywords_daily" TO "authenticated";



GRANT ALL ON TABLE "public"."v_google_campaign_daily" TO "service_role";
GRANT SELECT ON TABLE "public"."v_google_campaign_daily" TO "authenticated";



GRANT ALL ON TABLE "public"."v_google_campaign_performance" TO "service_role";
GRANT SELECT ON TABLE "public"."v_google_campaign_performance" TO "authenticated";



GRANT ALL ON TABLE "public"."v_google_keywords_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."v_google_keywords_v2" TO "authenticated";



GRANT ALL ON TABLE "public"."v_meta_account_daily" TO "service_role";
GRANT SELECT ON TABLE "public"."v_meta_account_daily" TO "authenticated";



GRANT ALL ON TABLE "public"."v_meta_campaign_daily" TO "service_role";
GRANT SELECT ON TABLE "public"."v_meta_campaign_daily" TO "authenticated";



GRANT ALL ON TABLE "public"."v_meta_campaign_performance" TO "service_role";
GRANT SELECT ON TABLE "public"."v_meta_campaign_performance" TO "authenticated";



GRANT ALL ON TABLE "public"."v_meta_creative_daily" TO "service_role";
GRANT SELECT ON TABLE "public"."v_meta_creative_daily" TO "authenticated";



GRANT ALL ON TABLE "public"."v_meta_creative_performance" TO "service_role";
GRANT SELECT ON TABLE "public"."v_meta_creative_performance" TO "authenticated";



GRANT ALL ON TABLE "public"."v_sync_health" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sync_health" TO "service_role";



GRANT ALL ON TABLE "public"."v_tracking_runtime_health" TO "anon";
GRANT ALL ON TABLE "public"."v_tracking_runtime_health" TO "authenticated";
GRANT ALL ON TABLE "public"."v_tracking_runtime_health" TO "service_role";



GRANT ALL ON TABLE "public"."v_workflow_health_daily" TO "anon";
GRANT ALL ON TABLE "public"."v_workflow_health_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."v_workflow_health_daily" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
