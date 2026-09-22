-- IMP-231 — retenção formal de payloads brutos do Meta Ads.
--
-- O Head já executou em produção, fora do fluxo de Executor, a limpeza abaixo
-- durante o incidente de cota de disco: aproximadamente 9.652 linhas com date
-- anterior a 14 dias tiveram os nove jsonb zerados; o banco caiu de 636 MB
-- (136%) para 452 MB (90%). Esta migration NÃO repete o VACUUM FULL manual.
-- O UPDATE é idempotente e só alcança linhas que ainda tenham algum payload.
-- VACUUM FULL continua sendo uma ação manual, decidida pelo Head/Caio quando
-- o inchaço do TOAST justificar; não faz parte do job automático.

set local lock_timeout = '5s';

create extension if not exists pg_cron;

update public.meta_ads_daily
   set source_payload = null,
       ad_raw = null,
       creative_raw = null,
       asset_feed_spec = null,
       object_story_spec = null,
       actions_raw = null,
       conversions_raw = null,
       action_values_raw = null,
       conversion_values_raw = null
 where date < current_date - 14
   and (
     source_payload is not null
     or ad_raw is not null
     or creative_raw is not null
     or asset_feed_spec is not null
     or object_story_spec is not null
     or actions_raw is not null
     or conversions_raw is not null
     or action_values_raw is not null
     or conversion_values_raw is not null
   );

select cron.schedule(
  'meta-ads-raw-retention-daily',
  '15 3 * * *',
  $job$update public.meta_ads_daily
   set source_payload = null,
       ad_raw = null,
       creative_raw = null,
       asset_feed_spec = null,
       object_story_spec = null,
       actions_raw = null,
       conversions_raw = null,
       action_values_raw = null,
       conversion_values_raw = null
 where date < current_date - 14
   and (
     source_payload is not null
     or ad_raw is not null
     or creative_raw is not null
     or asset_feed_spec is not null
     or object_story_spec is not null
     or actions_raw is not null
     or conversions_raw is not null
     or action_values_raw is not null
     or conversion_values_raw is not null
   );$job$
);

-- Gate: sem pg_cron, job, schedule ou predicado idempotente a migration aborta.
do $gate$
declare
  expected_command constant text := 'update public.meta_ads_daily set source_payload = null, ad_raw = null, creative_raw = null, asset_feed_spec = null, object_story_spec = null, actions_raw = null, conversions_raw = null, action_values_raw = null, conversion_values_raw = null where date < current_date - 14 and ( source_payload is not null or ad_raw is not null or creative_raw is not null or asset_feed_spec is not null or object_story_spec is not null or actions_raw is not null or conversions_raw is not null or action_values_raw is not null or conversion_values_raw is not null );';
  job_count integer;
  command_text text;
begin
  if to_regclass('cron.job') is null then
    raise exception 'IMP231_GATE: extensão pg_cron ou cron.job indisponível';
  end if;

  -- Comparacao robusta a formatacao: remove TODO espaco em branco (nao so
  -- colapsa run de espacos), para nao depender de como cada arquivo quebra
  -- linha dentro do corpo do job (achado do Head: o gate quebrou sozinho por
  -- causa de um espaco a mais depois de um parenteses).
  select count(*), max(lower(regexp_replace(command, '\s+', '', 'g')))
    into job_count, command_text
    from cron.job
   where jobname = 'meta-ads-raw-retention-daily';

  if job_count <> 1 then
    raise exception 'IMP231_GATE: esperado exatamente um job meta-ads-raw-retention-daily, encontrado %', job_count;
  end if;
  if not exists (
    select 1 from cron.job
     where jobname = 'meta-ads-raw-retention-daily'
       and schedule = '15 3 * * *'
  ) then
    raise exception 'IMP231_GATE: schedule esperado não encontrado';
  end if;
  if command_text is distinct from lower(regexp_replace(expected_command, '\s+', '', 'g')) then
    raise exception 'IMP231_GATE: comando do job não é o UPDATE idempotente esperado';
  end if;
  if exists (
    select 1 from public.meta_ads_daily
     where date < current_date - 14
       and (source_payload is not null or ad_raw is not null or creative_raw is not null
         or asset_feed_spec is not null or object_story_spec is not null or actions_raw is not null
         or conversions_raw is not null or action_values_raw is not null
         or conversion_values_raw is not null)
  ) then
    raise exception 'IMP231_GATE: ainda existem payloads brutos fora da janela de retenção';
  end if;
end
$gate$;
