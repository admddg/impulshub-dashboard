\set ON_ERROR_STOP on

-- Aceite IMP-213: isolamento entre clientes. Não executar contra produção sem
-- sessão autorizada; este script é transacional e termina em ROLLBACK.
-- Com o filtro antigo, "select client_id from private.my_client_ids()"
-- resolvia a coluna externa e este teste encontraria, por exemplo, Royal e
-- QuickClean para o atendente da Central.

begin;
set local statement_timeout = '8s';

-- Este catálogo tem 25 views: o histórico mais as 24 views financeiras.
-- A checagem também cobre as cinco tabelas que têm policy de leitura.
\set imp213_views '''v_ads_spend_daily'', ''v_channel_performance_daily'', ''v_client_daily_pulse'', ''v_client_performance_daily'', ''v_client_performance_daily_v2'', ''v_crm_card_history_v1'', ''v_crm_events_daily_v2'', ''v_crm_events_enriched'', ''v_crm_events_feed_v2'', ''v_crm_funnel_daily'', ''v_crm_opportunities'', ''v_crm_opportunities_v2'', ''v_crm_sales_daily_v2'', ''v_crm_sales_v2'', ''v_google_ads_keywords_daily'', ''v_google_ads_v2'', ''v_google_campaign_daily'', ''v_google_campaign_performance'', ''v_google_keywords_v2'', ''v_meta_account_daily'', ''v_meta_ads_v2'', ''v_meta_campaign_daily'', ''v_meta_campaign_performance'', ''v_meta_creative_daily'', ''v_meta_creative_performance'''
\set imp213_tables '''meta_ads_daily'', ''google_ads_daily'', ''google_ads_campaign_daily'', ''google_ads_keywords_daily'', ''events_normalized'''

set local role authenticated;

-- Atendente Central: o único client_id permitido é Central.
select set_config('request.jwt.claims', '{"sub":"bb04435c-fabb-4ba8-b5b5-e0175d9ca17d","role":"authenticated"}', true);
do $central$
declare
  object_name text;
  leaked uuid;
begin
  foreach object_name in array [:imp213_views]::text[] loop
    execute format('select distinct client_id from public.%I where client_id is distinct from %L::uuid limit 1', object_name, '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b') into leaked;
    if leaked is not null then
      raise exception 'IMP213_ISOLATION: % vazou %', object_name, leaked;
    end if;
  end loop;
  foreach object_name in array [:imp213_tables]::text[] loop
    execute format('select distinct client_id from public.%I where client_id is distinct from %L::uuid limit 1', object_name, '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b') into leaked;
    if leaked is not null then
      raise exception 'IMP213_ISOLATION: % vazou %', object_name, leaked;
    end if;
  end loop;
end;
$central$;

-- Gestor Royal: o único client_id permitido é Royal.
select set_config('request.jwt.claims', '{"sub":"7c3296f4-13c7-42d1-89eb-72aecec905ba","role":"authenticated"}', true);
do $royal$
declare
  object_name text;
  leaked uuid;
begin
  foreach object_name in array [:imp213_views]::text[] loop
    execute format('select distinct client_id from public.%I where client_id is distinct from %L::uuid limit 1', object_name, 'fa6fc071-7529-4317-93cb-9b0bfea3bca3') into leaked;
    if leaked is not null then
      raise exception 'IMP213_ISOLATION: % vazou %', object_name, leaked;
    end if;
  end loop;
  foreach object_name in array [:imp213_tables]::text[] loop
    execute format('select distinct client_id from public.%I where client_id is distinct from %L::uuid limit 1', object_name, 'fa6fc071-7529-4317-93cb-9b0bfea3bca3') into leaked;
    if leaked is not null then
      raise exception 'IMP213_ISOLATION: % vazou %', object_name, leaked;
    end if;
  end loop;
end;
$royal$;

rollback;
