begin;
set constraints all deferred;
select current_database() as database_name,
       current_user as current_user_name,
       to_regclass('cron.job') as cron_job,
       count(*) filter (where parse_status = 'raw') as raw_pending
from public.stevo_events_raw;
select tg.tgname,
       pg_get_triggerdef(tg.oid) as trigger_definition
from pg_trigger tg
join pg_class c on c.oid = tg.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'crm'
  and c.relname in ('opportunities', 'opportunity_stage_history')
  and not tg.tgisinternal
order by tg.tgname;
select pg_get_functiondef('crm.validate_opportunity_history_consistency()'::regprocedure) as validator_definition;
select * from crm.stevo_parse_messages(1);
select * from crm.stevo_parse_messages(2);
set constraints all immediate;
rollback;
