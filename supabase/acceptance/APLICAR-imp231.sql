-- IMP-231 — aplicação manual em produção.
-- Executar somente após revisão e autorização explícita do Caio/Head.
-- Não executar em staging. Este arquivo altera dados antigos de meta_ads_daily
-- e cria um job pg_cron; o rollback não restaura jsonb apagado.

begin;
set local lock_timeout = '5s';

create extension if not exists pg_cron;

update public.meta_ads_daily
   set source_payload = null, ad_raw = null, creative_raw = null,
       asset_feed_spec = null, object_story_spec = null, actions_raw = null,
       conversions_raw = null, action_values_raw = null, conversion_values_raw = null
 where date < current_date - 14
   and (source_payload is not null or ad_raw is not null or creative_raw is not null
     or asset_feed_spec is not null or object_story_spec is not null
     or actions_raw is not null or conversions_raw is not null
     or action_values_raw is not null or conversion_values_raw is not null);

select cron.schedule(
  'meta-ads-raw-retention-daily', '15 3 * * *',
  $job$update public.meta_ads_daily set source_payload = null, ad_raw = null,
       creative_raw = null, asset_feed_spec = null, object_story_spec = null,
       actions_raw = null, conversions_raw = null, action_values_raw = null,
       conversion_values_raw = null
 where date < current_date - 14
   and (source_payload is not null or ad_raw is not null or creative_raw is not null
     or asset_feed_spec is not null or object_story_spec is not null
     or actions_raw is not null or conversions_raw is not null
     or action_values_raw is not null or conversion_values_raw is not null);$job$
);

do $gate$
declare
  command_text text;
  expected text := 'update public.meta_ads_daily set source_payload = null, ad_raw = null, creative_raw = null, asset_feed_spec = null, object_story_spec = null, actions_raw = null, conversions_raw = null, action_values_raw = null, conversion_values_raw = null where date < current_date - 14 and ( source_payload is not null or ad_raw is not null or creative_raw is not null or asset_feed_spec is not null or object_story_spec is not null or actions_raw is not null or conversions_raw is not null or action_values_raw is not null or conversion_values_raw is not null );';
begin
  if to_regclass('cron.job') is null then raise exception 'IMP231_GATE: cron.job ausente'; end if;
  if (select count(*) from cron.job where jobname = 'meta-ads-raw-retention-daily') <> 1 then raise exception 'IMP231_GATE: job não é único'; end if;
  select lower(regexp_replace(command, '\s+', ' ', 'g')) into command_text from cron.job where jobname = 'meta-ads-raw-retention-daily';
  if (select schedule from cron.job where jobname = 'meta-ads-raw-retention-daily') <> '15 3 * * *' or command_text is distinct from lower(regexp_replace(expected, '\s+', ' ', 'g')) then raise exception 'IMP231_GATE: schedule/comando divergente'; end if;
  if exists (select 1 from public.meta_ads_daily where date < current_date - 14 and (source_payload is not null or ad_raw is not null or creative_raw is not null or asset_feed_spec is not null or object_story_spec is not null or actions_raw is not null or conversions_raw is not null or action_values_raw is not null or conversion_values_raw is not null)) then raise exception 'IMP231_GATE: retenção incompleta'; end if;
end
$gate$;

insert into supabase_migrations.schema_migrations (version, name)
values ('20261001000000', 'imp231_meta_ads_raw_retention')
on conflict (version) do nothing;

commit;
