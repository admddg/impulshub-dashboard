\set ON_ERROR_STOP on

begin;
set local statement_timeout = '8s';
set local role authenticated;

-- O bloco é intencionalmente transacional e termina em ROLLBACK.
-- Não imprimir payloads, evidências ou valores financeiros nesta prova.

-- Agência: as três consultas financeiras devem executar para qualquer cliente.
select set_config('request.jwt.claims', '{"sub":"d036c4d6-0969-4175-b917-ff7e4dd3b376","role":"authenticated"}', true);
select count(*) from public.get_client_overview_v2('fa6fc071-7529-4317-93cb-9b0bfea3bca3', '2026-08-22', '2026-09-20');
select count(*) from public.get_meta_ads_summary_v2('fa6fc071-7529-4317-93cb-9b0bfea3bca3', '2026-08-22', '2026-09-20', 'campaign');
select count(*) from public.get_google_ads_summary_v2('fa6fc071-7529-4317-93cb-9b0bfea3bca3', '2026-08-22', '2026-09-20', 'campaign');

-- Gestor Royal: as três consultas também devem executar.
select set_config('request.jwt.claims', '{"sub":"7c3296f4-13c7-42d1-89eb-72aecec905ba","role":"authenticated"}', true);
select count(*) from public.get_client_overview_v2('fa6fc071-7529-4317-93cb-9b0bfea3bca3', '2026-08-22', '2026-09-20');
select count(*) from public.get_meta_ads_summary_v2('fa6fc071-7529-4317-93cb-9b0bfea3bca3', '2026-08-22', '2026-09-20', 'campaign');
select count(*) from public.get_google_ads_summary_v2('fa6fc071-7529-4317-93cb-9b0bfea3bca3', '2026-08-22', '2026-09-20', 'campaign');

-- Atendente: overview pode retornar zero; as duas RPCs específicas devem falhar 42501.
select set_config('request.jwt.claims', '{"sub":"bb04435c-fabb-4ba8-b5b5-e0175d9ca17d","role":"authenticated"}', true);
do $attendant$
declare
  n bigint;
  failed boolean;
begin
  select count(*) into n from public.get_client_overview_v2('fa6fc071-7529-4317-93cb-9b0bfea3bca3', '2026-08-22', '2026-09-20');
  failed := false;
  begin
    perform * from public.get_meta_ads_summary_v2('fa6fc071-7529-4317-93cb-9b0bfea3bca3', '2026-08-22', '2026-09-20', 'campaign');
  exception when insufficient_privilege then
    failed := true;
  end;
  if not failed then raise exception 'IMP213_ACCEPTANCE: Meta deveria falhar 42501'; end if;
  failed := false;
  begin
    perform * from public.get_google_ads_summary_v2('fa6fc071-7529-4317-93cb-9b0bfea3bca3', '2026-08-22', '2026-09-20', 'campaign');
  exception when insufficient_privilege then
    failed := true;
  end;
  if not failed then raise exception 'IMP213_ACCEPTANCE: Google deveria falhar 42501'; end if;
end;
$attendant$;

-- As 24 views financeiras sem o histórico operacional devem retornar zero ao atendente.
do $views$
declare
  view_name text;
  n bigint;
begin
  foreach view_name in array[
    'v_ads_spend_daily','v_channel_performance_daily','v_client_daily_pulse',
    'v_client_performance_daily','v_client_performance_daily_v2','v_crm_events_daily_v2',
    'v_crm_events_enriched','v_crm_events_feed_v2','v_crm_funnel_daily',
    'v_crm_opportunities','v_crm_opportunities_v2','v_crm_sales_daily_v2','v_crm_sales_v2',
    'v_google_ads_keywords_daily','v_google_ads_v2','v_google_campaign_daily',
    'v_google_campaign_performance','v_google_keywords_v2','v_meta_account_daily',
    'v_meta_ads_v2','v_meta_campaign_daily','v_meta_campaign_performance',
    'v_meta_creative_daily','v_meta_creative_performance'
  ] loop
    execute format('select count(*) from public.%I', view_name) into n;
    if n <> 0 then raise exception 'IMP213_ACCEPTANCE: % retornou % linhas', view_name, n; end if;
  end loop;
end;
$views$;

-- Histórico operacional continua legível, mas os três campos financeiros e
-- evidence de milestones de receita devem permanecer mascarados.
select count(*) from public.v_crm_card_history_v1;
do $mask$
declare
  financial_nonnull bigint;
  revenue_evidence_nonnull bigint;
begin
  select
    count(*) filter (where value is not null or value_status is not null or currency is not null),
    count(*) filter (where milestone_kind = 'revenue' and evidence is not null)
  into financial_nonnull, revenue_evidence_nonnull
  from public.v_crm_card_history_v1;
  if financial_nonnull <> 0 or revenue_evidence_nonnull <> 0 then
    raise exception 'IMP213_ACCEPTANCE: máscara falhou (% campos financeiros, % evidências)', financial_nonnull, revenue_evidence_nonnull;
  end if;
end;
$mask$;

rollback;
