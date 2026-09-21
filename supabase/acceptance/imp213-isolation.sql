\set ON_ERROR_STOP on

-- IMP-213 isolation acceptance: read-only, role-scoped, no fixture writes.
begin;
set local role postgres;
select id from public.clients_base where lower(client_name) = 'central' limit 1;
\gset imp213_central_
select id from public.clients_base where lower(client_name) = 'royal' limit 1;
\gset imp213_royal_

-- The old filter was intentionally not executed against production. This is the
-- RED query: because the scalar SETOF uuid row was referenced as client_id,
-- PostgreSQL could resolve it to the outer view column and admit every tenant.
-- Under the old definition, the following query must return a non-zero count
-- for a multi-client member and therefore fail the isolation contract:
-- select count(*) from public.v_crm_card_history_v1
-- where client_id <> :'imp213_central_id'::uuid
--   and client_id in (select client_id from private.my_client_ids());

select set_config('request.jwt.claims', json_build_object('sub', 'bb04435c-fabb-4ba8-b5b5-e0175d9ca17d', 'role', 'authenticated')::text, true);
set local role authenticated;
do $central$
declare
  expected uuid := :'imp213_central_id'::uuid;
  view_name text;
  leaked bigint;
  views text[] := array[
    'v_crm_card_history_v1',
    'v_ads_spend_daily', 'v_channel_performance_daily', 'v_client_daily_pulse',
    'v_client_performance_daily', 'v_client_performance_daily_v2',
    'v_crm_events_daily_v2', 'v_crm_events_enriched', 'v_crm_events_feed_v2',
    'v_crm_funnel_daily', 'v_crm_opportunities', 'v_crm_opportunities_v2',
    'v_crm_sales_daily_v2', 'v_crm_sales_v2', 'v_google_ads_keywords_daily',
    'v_google_ads_v2', 'v_google_campaign_daily', 'v_google_campaign_performance',
    'v_google_keywords_v2', 'v_meta_account_daily', 'v_meta_ads_v2',
    'v_meta_campaign_daily', 'v_meta_campaign_performance',
    'v_meta_creative_daily', 'v_meta_creative_performance'
  ];
begin
  foreach view_name in array views loop
    execute format(
      'select count(*) from (select distinct client_id from public.%I where client_id is distinct from %L::uuid) leaked_clients',
      view_name, expected
    ) into leaked;
    if leaked <> 0 then
      raise exception 'IMP213_ISOLATION: Central recebeu client_id externo na view %', view_name;
    end if;
  end loop;
end;
$central$;

select set_config('request.jwt.claims', json_build_object('sub', '7c3296f4-13c7-42d1-89eb-72aecec905ba', 'role', 'authenticated')::text, true);
do $royal$
declare
  expected uuid := :'imp213_royal_id'::uuid;
  view_name text;
  leaked bigint;
  views text[] := array[
    'v_crm_card_history_v1',
    'v_ads_spend_daily', 'v_channel_performance_daily', 'v_client_daily_pulse',
    'v_client_performance_daily', 'v_client_performance_daily_v2',
    'v_crm_events_daily_v2', 'v_crm_events_enriched', 'v_crm_events_feed_v2',
    'v_crm_funnel_daily', 'v_crm_opportunities', 'v_crm_opportunities_v2',
    'v_crm_sales_daily_v2', 'v_crm_sales_v2', 'v_google_ads_keywords_daily',
    'v_google_ads_v2', 'v_google_campaign_daily', 'v_google_campaign_performance',
    'v_google_keywords_v2', 'v_meta_account_daily', 'v_meta_ads_v2',
    'v_meta_campaign_daily', 'v_meta_campaign_performance',
    'v_meta_creative_daily', 'v_meta_creative_performance'
  ];
begin
  foreach view_name in array views loop
    execute format(
      'select count(*) from (select distinct client_id from public.%I where client_id is distinct from %L::uuid) leaked_clients',
      view_name, expected
    ) into leaked;
    if leaked <> 0 then
      raise exception 'IMP213_ISOLATION: Royal recebeu client_id externo na view %', view_name;
    end if;
  end loop;
end;
$royal$;

rollback;
