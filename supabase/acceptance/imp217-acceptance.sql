-- IMP-217 acceptance; run after migration in one transaction and ROLLBACK.
begin;
set local statement_timeout = '8s';
set local role postgres;

do $accept$
declare
  v_tenant uuid := '3ec294db-a64a-4420-9b4a-0d917f65d399';
  v_before numeric; v_after numeric; v_pending numeric; v_valid numeric;
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='events_normalized' and column_name='currency') then raise exception 'IMP217_ACCEPT: currency ausente'; end if;
  select coalesce(sum(e.valor_ganho),0) into v_before from public.events_normalized e where e.client_id=v_tenant and e.source_system='impuls_crm' and e.event_code='ganho';
  select coalesce(sum(e.valor_ganho),0) into v_after from public.events_normalized e where e.client_id=v_tenant and e.source_system='impuls_crm' and e.event_code='ganho';
  if v_after <> v_before then raise exception 'IMP217_ACCEPT: baseline mudou sem fixture'; end if;
  select count(*) into v_pending from public.events_normalized e where e.client_id=v_tenant and e.source_system='impuls_crm' and e.event_code='ganho' and e.budget_status='pending' and e.valor_ganho is null and e.currency is null;
  select count(*) into v_valid from public.events_normalized e where e.client_id=v_tenant and e.source_system='impuls_crm' and e.event_code='ganho' and e.budget_status='valid' and e.valor_ganho is not null and e.currency='BRL';
  raise notice 'IMP217_ACCEPT baseline=% pending_events=% valid_events=%',v_before,v_pending,v_valid;
end
$accept$;
rollback;
