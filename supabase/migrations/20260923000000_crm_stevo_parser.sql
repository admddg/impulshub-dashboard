-- IMP-204: materializa contatos, atividades e oportunidades a partir de public.stevo_events_raw.
--
-- Contrato verificado contra os dados reais de producao em 2026-09-18:
--   * a identidade do contato vem SEMPRE de data.Info.Chat. data.Info.Sender chega como
--     "<digitos>@lid" no outbound e identifica o dispositivo do atendente, nao o contato;
--   * sem normalizacao do nono digito brasileiro: 605 numeros reais, zero colisoes entre
--     as formas de 12 e 13 digitos. O JID do WhatsApp ja e canonico;
--   * o ctwa_clid vive em contextInfo.conversionData, codificado em base64;
--   * contato nao e oportunidade: das 319 conversas da QuickClean, 241 nao tem atribuicao
--     de anuncio. Criar oportunidade para todas tornaria o pipeline ~75% ruido.

set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- Auxiliares
-- ---------------------------------------------------------------------------

-- crm.activities exige body quando kind='message'. 1.640 mensagens reais nao tem texto.
create function crm.stevo_message_body(p_message jsonb, p_text text)
returns text
language sql
immutable
set search_path = ''
as $fn$
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
$fn$;

-- Decodifica o ctwa_clid. Devolve null para qualquer coisa fora do formato esperado,
-- em vez de gravar lixo: atribuicao errada e pior do que atribuicao ausente.
create function crm.stevo_ctwa_clid(p_conversion_data text)
returns text
language plpgsql
immutable
set search_path = ''
as $fn$
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
$fn$;

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------

create function crm.stevo_parse_messages(p_limit integer default 20000)
returns table (
  lidos                 integer,
  contatos_criados      integer,
  oportunidades_criadas integer,
  atendimentos          integer,
  ignorados_grupo       integer,
  ignorados_lid         integer,
  ignorados_duplicados  integer
)
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  ev                 record;
  v_pipeline_id      uuid;
  v_stage_lead       uuid;
  v_stage_atendim    uuid;
  v_chat             text;
  v_dominio          text;
  v_numero           text;
  v_de_mim           boolean;
  v_grupo            boolean;
  v_push             text;
  v_texto            text;
  v_msg              jsonb;
  v_ctx              jsonb;
  v_ar               jsonb;
  v_msg_id           text;
  v_ocorrido         timestamptz;
  v_conv_source      text;
  v_ctwa             text;
  v_ad_id            text;
  v_src_url          text;
  v_titulo           text;
  v_entry            text;
  v_contato_id       uuid;
  v_oportunidade_id  uuid;
  v_etapa_atual      uuid;
  v_atividade_id     uuid;
  v_inserido         integer;
begin
  lidos := 0; contatos_criados := 0; oportunidades_criadas := 0; atendimentos := 0;
  ignorados_grupo := 0; ignorados_lid := 0; ignorados_duplicados := 0;

  select v.id into v_pipeline_id
    from crm.global_pipeline_versions v
   where v.status = 'active';

  select s.id into v_stage_lead
    from crm.global_pipeline_stages s
   where s.pipeline_version_id = v_pipeline_id and s.code = 'lead';

  select s.id into v_stage_atendim
    from crm.global_pipeline_stages s
   where s.pipeline_version_id = v_pipeline_id and s.code = 'atendimento';

  if v_pipeline_id is null or v_stage_lead is null or v_stage_atendim is null then
    raise exception 'pipeline global ativo nao encontrado';
  end if;

  -- Ordem cronologica dentro de cada conversa: o estado final nao pode depender
  -- da ordem em que os eventos chegaram.
  for ev in
    select r.id, r.client_id, r.payload, r.payload_hash, r.event_timestamp, r.received_at
      from public.stevo_events_raw r
     where r.event_type = 'Message'
       and r.parse_status = 'raw'
       and r.client_id is not null
       and exists (select 1 from crm.tenants t where t.id = r.client_id)
     order by coalesce(r.event_timestamp, r.received_at), r.received_at, r.id
     limit p_limit
  loop
    lidos := lidos + 1;

    v_chat        := ev.payload #>> '{data,Info,Chat}';
    v_grupo       := (ev.payload #>> '{data,Info,IsGroup}')::boolean;
    v_de_mim      := (ev.payload #>> '{data,Info,IsFromMe}')::boolean;
    -- nullif e construcao SQL, nao funcao: nao pode ser qualificada com pg_catalog.
    v_push        := nullif(pg_catalog.btrim(coalesce(ev.payload #>> '{data,Info,PushName}', '')), '');
    v_texto       := ev.payload #>> '{data,text}';
    v_msg         := ev.payload #> '{data,Message}';
    v_msg_id      := ev.payload #>> '{data,Info,ID}';
    v_ocorrido    := coalesce(ev.event_timestamp, ev.received_at);
    v_ctx         := ev.payload #> '{data,Message,extendedTextMessage,contextInfo}';
    v_ar          := v_ctx #> '{externalAdReply}';
    v_conv_source := v_ctx #>> '{conversionSource}';
    v_ctwa        := crm.stevo_ctwa_clid(v_ctx #>> '{conversionData}');
    v_entry       := v_ctx #>> '{entryPointConversionSource}';
    v_ad_id       := v_ar  #>> '{sourceID}';
    v_src_url     := v_ar  #>> '{sourceURL}';
    v_titulo      := v_ar  #>> '{title}';

    if coalesce(v_grupo, false) then
      update public.stevo_events_raw set parse_status = 'skipped_group' where id = ev.id;
      ignorados_grupo := ignorados_grupo + 1;
      continue;
    end if;

    if v_chat is null or v_msg_id is null then
      update public.stevo_events_raw set parse_status = 'skipped_incomplete' where id = ev.id;
      continue;
    end if;

    v_numero  := pg_catalog.split_part(v_chat, '@', 1);
    v_dominio := pg_catalog.split_part(v_chat, '@', 2);

    -- Contato sem telefone exposto. crm.contacts exige telefone ou email e nao
    -- inventamos nenhum dos dois. Sao 7 conversas em 628; lacuna registrada.
    if v_dominio <> 's.whatsapp.net' then
      update public.stevo_events_raw set parse_status = 'skipped_lid' where id = ev.id;
      ignorados_lid := ignorados_lid + 1;
      continue;
    end if;

    -- Idempotencia. A unique (tenant_id, source, external_id) rejeita a segunda
    -- entrega da mesma mensagem do provedor; a unique (tenant_id, raw_event_id)
    -- garante que cada linha bruta so seja processada uma vez.
    insert into crm.processed_events
      (tenant_id, raw_event_id, source, external_id, payload_hash, status)
    values
      (ev.client_id, ev.id, 'stevo', v_msg_id, ev.payload_hash, 'processing')
    on conflict do nothing;

    get diagnostics v_inserido = row_count;

    if v_inserido = 0 then
      update public.stevo_events_raw set parse_status = 'duplicate' where id = ev.id;
      ignorados_duplicados := ignorados_duplicados + 1;
      continue;
    end if;

    -- Contato, resolvido pelo JID exatamente como veio.
    select ci.contact_id into v_contato_id
      from crm.contact_identities ci
     where ci.tenant_id = ev.client_id
       and ci.kind = 'phone'
       and ci.value_normalized = v_numero;

    if v_contato_id is null then
      -- 125 das 628 conversas nunca trazem PushName: o numero vira o nome exibido,
      -- que e o mesmo comportamento do proprio WhatsApp.
      insert into crm.contacts (tenant_id, full_name, phone_normalized)
      values (ev.client_id, coalesce(v_push, v_numero), v_numero)
      returning id into v_contato_id;

      insert into crm.contact_identities
        (tenant_id, contact_id, kind, value_normalized, provider)
      values
        (ev.client_id, v_contato_id, 'phone', v_numero, 'stevo');

      contatos_criados := contatos_criados + 1;

    elsif v_push is not null and not v_de_mim then
      -- O nome vem do PushName mais recente de mensagem recebida.
      update crm.contacts c
         set full_name = v_push, updated_at = pg_catalog.now()
       where c.tenant_id = ev.client_id
         and c.id = v_contato_id
         and c.full_name is distinct from v_push;
    end if;

    -- Oportunidade aberta do contato, se houver.
    v_oportunidade_id := null;
    v_etapa_atual := null;

    select o.id, o.current_stage_id into v_oportunidade_id, v_etapa_atual
      from crm.opportunities o
     where o.tenant_id = ev.client_id
       and o.contact_id = v_contato_id
       and o.status = 'open'
     order by o.created_at desc
     limit 1;

    -- Entrada comercial valida: mensagem RECEBIDA com origem de anuncio.
    -- Conversa sem atribuicao gera contato e atividade, nunca oportunidade.
    if v_oportunidade_id is null and not v_de_mim and v_conv_source is not null then
      insert into crm.opportunities
        (tenant_id, contact_id, pipeline_version_id, current_stage_id, title, status, opened_at,
         ctwa_clid, conversion_source, meta_ad_id, source_url, ad_title,
         entry_point_conversion_source)
      values
        (ev.client_id, v_contato_id, v_pipeline_id, v_stage_lead,
         coalesce(v_push, v_numero), 'open', v_ocorrido,
         v_ctwa, v_conv_source, v_ad_id, v_src_url, v_titulo, v_entry)
      returning id into v_oportunidade_id;

      v_etapa_atual := v_stage_lead;

      insert into crm.opportunity_stage_history
        (tenant_id, opportunity_id, from_stage_id, to_stage_id,
         transition_type, origin, occurred_at)
      values
        (ev.client_id, v_oportunidade_id, null, v_stage_lead,
         'automatic', 'sistema', v_ocorrido);

      insert into crm.opportunity_milestones
        (tenant_id, opportunity_id, kind, origin, evidence, occurred_at)
      values
        (ev.client_id, v_oportunidade_id, 'lead_received', 'sistema',
         'whatsapp:' || v_conv_source || coalesce(' ad:' || v_ad_id, ''), v_ocorrido);

      oportunidades_criadas := oportunidades_criadas + 1;
    end if;

    -- Atividade. O indice unico (tenant_id, provider_message_id) deduplica.
    v_atividade_id := null;

    insert into crm.activities
      (tenant_id, contact_id, opportunity_id, raw_event_id, kind, direction, body,
       provider_message_id, sent_confirmed_at, created_at)
    values
      (ev.client_id, v_contato_id, v_oportunidade_id, ev.id, 'message',
       case when v_de_mim then 'outbound' else 'inbound' end,
       crm.stevo_message_body(v_msg, v_texto),
       v_msg_id,
       case when v_de_mim then v_ocorrido else null end,
       v_ocorrido)
    on conflict do nothing
    returning id into v_atividade_id;

    -- Primeira resposta confirmada do atendente move Lead -> Atendimento.
    -- Limitacao conhecida e aceita: mensagem automatica de boas-vindas e
    -- indistinguivel de resposta humana nestes dados. O atendente corrige a mao.
    -- Nao existe heuristica de texto aqui de proposito.
    if v_de_mim
       and v_oportunidade_id is not null
       and v_etapa_atual = v_stage_lead then

      insert into crm.opportunity_stage_history
        (tenant_id, opportunity_id, from_stage_id, to_stage_id, transition_type,
         origin, source_activity_id, occurred_at)
      values
        (ev.client_id, v_oportunidade_id, v_stage_lead, v_stage_atendim,
         'automatic', 'sistema', v_atividade_id, v_ocorrido);

      update crm.opportunities o
         set current_stage_id = v_stage_atendim, updated_at = pg_catalog.now()
       where o.tenant_id = ev.client_id
         and o.id = v_oportunidade_id;

      insert into crm.opportunity_milestones
        (tenant_id, opportunity_id, kind, origin, evidence, occurred_at)
      values
        (ev.client_id, v_oportunidade_id, 'conversation_started', 'sistema',
         'whatsapp:primeira_resposta', v_ocorrido);

      atendimentos := atendimentos + 1;
    end if;

    update crm.processed_events pe
       set status = 'processed', processed_at = pg_catalog.now()
     where pe.tenant_id = ev.client_id
       and pe.raw_event_id = ev.id;

    update public.stevo_events_raw set parse_status = 'processed' where id = ev.id;
  end loop;

  return next;
end;
$fn$;

revoke all on function crm.stevo_parse_messages(integer) from public, authenticated;
grant execute on function crm.stevo_parse_messages(integer) to service_role;

revoke all on function crm.stevo_message_body(jsonb, text) from public, authenticated;
revoke all on function crm.stevo_ctwa_clid(text) from public, authenticated;
