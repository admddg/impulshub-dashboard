\set ON_ERROR_STOP on

begin;
set local statement_timeout = '8s';
set local role authenticated;

-- Agência Caio.
select set_config('request.jwt.claims', '{"sub":"d036c4d6-0969-4175-b917-ff7e4dd3b376","role":"authenticated"}', true);
do $agency$
declare
  meta_count bigint;
  meta_spend numeric;
  events_count bigint;
begin
  select count(*), coalesce(sum(spend), 0)
    into meta_count, meta_spend
    from public.meta_ads_daily;
  select count(*) into events_count
    from public.events_normalized
   where client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3';
  if meta_count <> 10100 or meta_spend <> 162998.35 or events_count <> 8839 then
    raise exception 'IMP229_ACCEPTANCE agência: resultado inesperado';
  end if;
end;
$agency$;

-- Gestor Royal.
select set_config('request.jwt.claims', '{"sub":"7c3296f4-13c7-42d1-89eb-72aecec905ba","role":"authenticated"}', true);
do $manager$
declare
  meta_count bigint;
  meta_spend numeric;
  events_count bigint;
begin
  select count(*), coalesce(sum(spend), 0)
    into meta_count, meta_spend
    from public.meta_ads_daily;
  select count(*) into events_count
    from public.events_normalized
   where client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3';
  if meta_count <> 6241 or meta_spend <> 101946.99 or events_count <> 8839 then
    raise exception 'IMP229_ACCEPTANCE gestor Royal: resultado inesperado';
  end if;
end;
$manager$;

-- Atendente Central.
select set_config('request.jwt.claims', '{"sub":"bb04435c-fabb-4ba8-b5b5-e0175d9ca17d","role":"authenticated"}', true);
do $attendant$
declare
  meta_count bigint;
  meta_spend numeric;
  events_count bigint;
begin
  select count(*), coalesce(sum(spend), 0)
    into meta_count, meta_spend
    from public.meta_ads_daily;
  select count(*) into events_count
    from public.events_normalized
   where client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3';
  if meta_count <> 379 or meta_spend <> 11472.76 or events_count <> 0 then
    raise exception 'IMP229_ACCEPTANCE atendente Central: resultado inesperado';
  end if;
end;
$attendant$;

rollback;
