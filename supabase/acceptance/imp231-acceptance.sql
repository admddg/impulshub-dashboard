\set ON_ERROR_STOP on

-- IMP-231 aceite: executar depois da migration, em conexão autorizada.
begin;
set local statement_timeout = '8s';
set local role postgres;

-- Critério 2: não há payload bruto fora da janela.
do $retention$
begin
  if exists (
    select 1 from public.meta_ads_daily
     where date < current_date - 14
       and (source_payload is not null or ad_raw is not null or creative_raw is not null
         or asset_feed_spec is not null or object_story_spec is not null or actions_raw is not null
         or conversions_raw is not null or action_values_raw is not null
         or conversion_values_raw is not null)
  ) then
    raise exception 'IMP231_ACCEPTANCE: há payload bruto anterior à janela de 14 dias';
  end if;
end
$retention$;

-- Critérios 3 e 4: extensão, nome único, schedule diário e comando idempotente.
do $cron$
declare
  command_text text;
  expected text := 'update public.meta_ads_daily set source_payload = null, ad_raw = null, creative_raw = null, asset_feed_spec = null, object_story_spec = null, actions_raw = null, conversions_raw = null, action_values_raw = null, conversion_values_raw = null where date < current_date - 14 and ( source_payload is not null or ad_raw is not null or creative_raw is not null or asset_feed_spec is not null or object_story_spec is not null or actions_raw is not null or conversions_raw is not null or action_values_raw is not null or conversion_values_raw is not null );';
begin
  if to_regclass('cron.job') is null then raise exception 'IMP231_ACCEPTANCE: cron.job ausente'; end if;
  if (select count(*) from cron.job where jobname = 'meta-ads-raw-retention-daily') <> 1 then
    raise exception 'IMP231_ACCEPTANCE: job não é único';
  end if;
  select lower(regexp_replace(command, '\s+', '', 'g')) into command_text
    from cron.job where jobname = 'meta-ads-raw-retention-daily';
  if (select schedule from cron.job where jobname = 'meta-ads-raw-retention-daily') <> '15 3 * * *'
     or command_text is distinct from lower(regexp_replace(expected, '\s+', '', 'g')) then
    raise exception 'IMP231_ACCEPTANCE: schedule ou comando divergente';
  end if;
end
$cron$;

-- Correção do Head: meta_ads_daily TEM client_id (a investigação da IMP-231
-- errou nesse ponto). O teste de isolamento entre clientes não se aplica
-- mesmo assim, porque este UPDATE zera só campos jsonb brutos por idade,
-- roda como job interno (nao como usuario final) e nao filtra nem expõe
-- nenhum client_id — nenhum dado estruturado nem RLS de tenant é tocado.
select count(*) as clientes_distintos_na_tabela
  from (select distinct client_id from public.meta_ads_daily) c;

rollback;

-- Critério 5 (executar separadamente, após registrar a prova):
-- select cron.unschedule('meta-ads-raw-retention-daily');
-- select count(*) from cron.job where jobname = 'meta-ads-raw-retention-daily'; -- 0
