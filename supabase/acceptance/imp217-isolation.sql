-- IMP-217 tenant isolation; read-only assertions, transaction ends ROLLBACK.
begin;
set local statement_timeout = '8s';
set local role postgres;
do $isolation$
declare
  v_central uuid := 'bb04435c-fabb-4ba8-b5b5-e0175d9ca17d';
  v_royal uuid := '7c3296f4-13c7-42d1-89eb-72aecec905ba';
  v_central_clients int; v_royal_clients int;
begin
  select count(distinct e.client_id) into v_central_clients from public.events_normalized e where e.client_id=v_central;
  select count(distinct e.client_id) into v_royal_clients from public.events_normalized e where e.client_id=v_royal;
  if v_central_clients <> 1 or v_royal_clients <> 1 then raise exception 'IMP217_ISOLATION: event scope crossed'; end if;
  if exists (select 1 from public.events_normalized e where e.client_id=v_central and e.client_id<>v_central) then raise exception 'IMP217_ISOLATION: central crossed'; end if;
  if exists (select 1 from public.events_normalized e where e.client_id=v_royal and e.client_id<>v_royal) then raise exception 'IMP217_ISOLATION: royal crossed'; end if;
  raise notice 'IMP217_ISOLATION OK central_clients=% royal_clients=%',v_central_clients,v_royal_clients;
end
$isolation$;
rollback;
