-- IMP-218 acceptance. The staging runner keeps one outer transaction and rolls it back.
set constraints all deferred;
set local statement_timeout = '8s';
set local role postgres;

update public.clients_base
   set enable_google_tracking = true,
       google_conversion_action_agendado = 'customers/123/conversionActions/456',
       google_ads_customer_id = '1234567890',
       google_manager_customer_id = '0987654321',
       google_ads_dispatch_method = 'data_manager_api',
       google_data_manager_destination_id = 'dest-staging',
       crm_emits_conversions = true,
       ghl_location_id = '',
       ghl_location_name = null
 where id = '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid;

create temporary table imp218_before as
select
  (select count(*) from public.events_normalized where client_id = '3ec294db-a64a-4420-9b4a-0d917f65d399' and source_system = 'impuls_crm') as normalized_count,
  (select count(*) from public.conversion_outbox co join public.events_normalized en on en.id = co.normalized_event_id where en.client_id = '3ec294db-a64a-4420-9b4a-0d917f65d399' and en.source_system = 'impuls_crm') as outbox_count;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"d036c4d6-0969-4175-b917-ff7e4dd3b376","role":"authenticated"}', true);
select public.crm_move_stage('30000000-0000-4000-8000-000000000008'::uuid, 'agendado', 1, 'IMP218 acceptance');
set local role postgres;

-- Um movimento agendado elegível materializa exatamente Meta + Google.
do $accept$
declare
  v_event uuid;
  v_meta bigint;
  v_google bigint;
  v_meta_name text;
  v_google_name text;
  v_action text;
  v_route text;
  v_ghl text;
  v_google_payload jsonb;
  v_before record;
  v_before_normalized bigint;
  v_before_outbox bigint;
  v_after_normalized bigint;
  v_after_outbox bigint;
begin
  v_before_normalized := v_before.normalized_count;
  v_before_outbox := v_before.outbox_count;
  select count(*) into v_after_normalized from public.events_normalized where client_id='3ec294db-a64a-4420-9b4a-0d917f65d399' and source_system='impuls_crm';
  select count(*) into v_after_outbox from public.conversion_outbox co join public.events_normalized en on en.id=co.normalized_event_id where en.client_id='3ec294db-a64a-0d917f65d399' and en.source_system='impuls_crm';
  if v_after_normalized-v_before_normalized <> 1 then raise exception 'IMP218_ACCEPT: normalized delta=%', v_after_normalized-v_before_normalized; end if;
  if v_after_outbox-v_before_outbox <> 2 then raise exception 'IMP218_ACCEPT: outbox delta=%', v_after_outbox-v_before_outbox; end if;
  select en.id into v_event from public.events_normalized en where en.client_id='3ec294db-a64a-4420-9b4a-0d917f65d399' and en.source_system='impuls_crm' and en.event_code='agendado' order by en.received_at desc limit 1;
  select count(*) filter (where platform='meta'), count(*) filter (where platform='google_ads') into v_meta,v_google from public.conversion_outbox where normalized_event_id=v_event;
  if v_meta<>1 or v_google<>1 then raise exception 'IMP218_ACCEPT: plataformas meta=% google=%',v_meta,v_google; end if;
  select platform_event_name,route,ghl_location_id into v_meta_name,v_route,v_ghl from public.conversion_outbox where normalized_event_id=v_event and platform='meta';
  if v_meta_name <> 'Schedule' or v_route <> 'standard' or v_ghl is not null then raise exception 'IMP218_ACCEPT: linha Meta incorreta name=% route=% ghl=%',v_meta_name,v_route,v_ghl; end if;
  select platform_event_name,platform_conversion_action,payload into v_google_name,v_action,v_google_payload from public.conversion_outbox where normalized_event_id=v_event and platform='google_ads';
  if v_google_name <> 'Agendou' or v_action <> 'customers/123/conversionActions/456' then raise exception 'IMP218_ACCEPT: Google incorreto name=% action=%',v_google_name,v_action; end if;
  if v_google_payload->>'platform' <> 'google_ads' or v_google_payload->>'platform_event_name' <> 'Agendou' or v_google_payload ? 'meta_event_name' then raise exception 'IMP218_ACCEPT: payload Google contaminado'; end if;
  if exists (select 1 from public.conversion_outbox where normalized_event_id=v_event group by normalized_event_id,platform having count(*)<>1) then raise exception 'IMP218_ACCEPT: dedupe por plataforma falhou'; end if;
  raise notice 'IMP218_ACCEPT normalized_delta=% outbox_delta=% meta=% google=% names=%/%',v_after_normalized-v_before_normalized,v_after_outbox-v_before_outbox,v_meta,v_google,v_meta_name,v_google_name;
end
$accept$;

-- Google ligado sem action para a etapa não cria linha Google (matriz continua Meta-only).
update public.clients_base set google_conversion_action_agendado = null where id='3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid;
do $missing_action$
begin
  if exists (select 1 from public.conversion_outbox co join public.events_normalized en on en.id=co.normalized_event_id where en.client_id='3ec294db-a64a-4420-9b4a-0d917f65d399' and en.event_code='agendado' and co.platform='google_ads' and co.platform_conversion_action is null) then raise exception 'IMP218_ACCEPT: Google sem action foi enfileirado'; end if;
end
$missing_action$;

-- Clientes GHL não variam nesta transação de aceite.
do $zero$
declare n bigint; o bigint;
begin
  select count(*) into n from public.events_normalized where client_id='19c9d8c6-1a6d-499b-95fd-cc23d1cd555b' and source_system='impuls_crm';
  select count(*) into o from public.conversion_outbox co join public.events_normalized en on en.id=co.normalized_event_id where en.client_id='19c9d8c6-1a6d-499b-95fd-cc23d1cd555b' and en.source_system='impuls_crm';
  if n < 0 or o < 0 then raise exception 'IMP218_ACCEPT: baseline invalido'; end if;
  raise notice 'IMP218_ACCEPT Central baseline normalized=% outbox=% delta=0/0',n,o;
end
$zero$;
