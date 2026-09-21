\set ON_ERROR_STOP on

begin;
set local statement_timeout = '8s';

-- Cada bloco calcula o esperado como postgres, antes de ativar a RLS.
-- Os valores conhecidos não são usados: a membership ativa é a fonte do esperado.

set local role postgres;
select count(*)::bigint as meta_count,
       coalesce(sum(m.spend), 0)::numeric as meta_spend,
       (select count(*)::bigint
          from public.events_normalized e
         where e.client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'
           and e.client_id in (select cu.client_id from public.client_users cu
                                where cu.user_id = 'd036c4d6-0969-4175-b917-ff7e4dd3b376'
                                  and cu.is_active)) as events_count
  from public.meta_ads_daily m
 where m.client_id in (select cu.client_id from public.client_users cu
                        where cu.user_id = 'd036c4d6-0969-4175-b917-ff7e4dd3b376'
                          and cu.is_active)
\gset agency_expected_
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"d036c4d6-0969-4175-b917-ff7e4dd3b376","role":"authenticated"}', true);
do $agency$
begin
  if (select count(*)::bigint from public.meta_ads_daily) <> :'agency_expected_meta_count'::bigint
     or (select coalesce(sum(spend), 0)::numeric from public.meta_ads_daily) <> :'agency_expected_meta_spend'::numeric
     or (select count(*)::bigint from public.events_normalized where client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3') <> :'agency_expected_events_count'::bigint then
    raise exception 'IMP229_ACCEPTANCE: agência divergiu do esperado';
  end if;
end;
$agency$;

set local role postgres;
select count(*)::bigint as meta_count,
       coalesce(sum(m.spend), 0)::numeric as meta_spend,
       (select count(*)::bigint
          from public.events_normalized e
         where e.client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'
           and e.client_id in (select cu.client_id from public.client_users cu
                                where cu.user_id = '7c3296f4-13c7-42d1-89eb-72aecec905ba'
                                  and cu.is_active)) as events_count
  from public.meta_ads_daily m
 where m.client_id in (select cu.client_id from public.client_users cu
                        where cu.user_id = '7c3296f4-13c7-42d1-89eb-72aecec905ba'
                          and cu.is_active)
\gset manager_expected_
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"7c3296f4-13c7-42d1-89eb-72aecec905ba","role":"authenticated"}', true);
do $manager$
begin
  if (select count(*)::bigint from public.meta_ads_daily) <> :'manager_expected_meta_count'::bigint
     or (select coalesce(sum(spend), 0)::numeric from public.meta_ads_daily) <> :'manager_expected_meta_spend'::numeric
     or (select count(*)::bigint from public.events_normalized where client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3') <> :'manager_expected_events_count'::bigint then
    raise exception 'IMP229_ACCEPTANCE: gestor Royal divergiu do esperado';
  end if;
end;
$manager$;

set local role postgres;
select count(*)::bigint as meta_count,
       coalesce(sum(m.spend), 0)::numeric as meta_spend,
       (select count(*)::bigint
          from public.events_normalized e
         where e.client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'
           and e.client_id in (select cu.client_id from public.client_users cu
                                where cu.user_id = 'bb04435c-fabb-4ba8-b5b5-e0175d9ca17d'
                                  and cu.is_active)) as events_count
  from public.meta_ads_daily m
 where m.client_id in (select cu.client_id from public.client_users cu
                        where cu.user_id = 'bb04435c-fabb-4ba8-b5b5-e0175d9ca17d'
                          and cu.is_active)
\gset attendant_expected_
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"bb04435c-fabb-4ba8-b5b5-e0175d9ca17d","role":"authenticated"}', true);
do $attendant$
begin
  if (select count(*)::bigint from public.meta_ads_daily) <> :'attendant_expected_meta_count'::bigint
     or (select coalesce(sum(spend), 0)::numeric from public.meta_ads_daily) <> :'attendant_expected_meta_spend'::numeric
     or (select count(*)::bigint from public.events_normalized where client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3') <> :'attendant_expected_events_count'::bigint then
    raise exception 'IMP229_ACCEPTANCE: atendente Central divergiu do esperado';
  end if;
  if (select count(*)::bigint from public.events_normalized where client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3') <> 0 then
    raise exception 'IMP229_ACCEPTANCE: atendente Central deveria ter zero eventos Royal';
  end if;
end;
$attendant$;

rollback;
