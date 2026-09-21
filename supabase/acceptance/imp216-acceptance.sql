\set ON_ERROR_STOP on

-- Aceite IMP-216. Executar somente em sessao autorizada; termina em ROLLBACK.
begin;
set local statement_timeout = '8s';

-- Esperados calculados como postgres antes de trocar o papel.
set local role postgres;
create temporary table imp216_expected as
select cb.id as client_id,
       count(en.id)::bigint as normalized_count,
       (select count(*)::bigint from public.conversion_outbox co where co.normalized_event_id in (
          select en2.id from public.events_normalized en2 where en2.client_id = cb.id and en2.source_system = 'impuls_crm'
       )) as outbox_count
  from public.clients_base cb
  left join public.events_normalized en on en.client_id = cb.id and en.source_system = 'impuls_crm'
 where cb.id = any(array[
   '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid,
   '3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid,
   'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid
 ])
 group by cb.id;

-- Fixture dinamica: um card aberto do tenant interno e sua proxima etapa.
create temporary table imp216_fixture as
select o.id as opportunity_id, o.stage_version, s2.code as next_stage_code
  from crm.opportunities o
  join crm.global_pipeline_stages s1 on s1.id = o.current_stage_id
  join crm.global_pipeline_stages s2 on s2.pipeline_version_id = o.pipeline_version_id
                                       and s2.position = s1.position + 1
 where o.tenant_id = '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid
   and o.status = 'open'
   and not s1.is_terminal and not s2.is_terminal
 order by o.updated_at, o.id
 limit 1;

select count(*) as fixture_count from imp216_fixture;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"d036c4d6-0969-4175-b917-ff7e4dd3b376","role":"authenticated"}', true);
do $imp216_move$
declare
  f record;
begin
  select * into f from imp216_fixture;
  if not found then
    raise exception 'IMP216_ACCEPTANCE: fixture sem GHL ausente no tenant ImpulsHub';
  end if;
  perform public.crm_move_stage(f.opportunity_id, f.next_stage_code, f.stage_version, 'IMP216 acceptance');
end
$imp216_move$;

set local role postgres;
do $imp216_assert$
declare
  f record;
  before_count bigint;
  after_count bigint;
  after_outbox bigint;
  expected_count bigint;
  expected_outbox bigint;
  c record;
begin
  select * into f from imp216_fixture;
  select count(*) into after_count from public.events_normalized
   where client_id='3ec294db-a64a-4420-9b4a-0d917f65d399' and source_system='impuls_crm';
  if after_count = 0 then raise exception 'IMP216_ACCEPTANCE: movimento sem evento normalizado'; end if;
  select count(*) into after_outbox from public.conversion_outbox co
   join public.events_normalized en on en.id=co.normalized_event_id
  where en.client_id='3ec294db-a64a-4420-9b4a-0d917f65d399' and en.source_system='impuls_crm';
  if after_outbox <> 0 then raise exception 'IMP216_ACCEPTANCE: conversion_outbox recebeu linha sem flag'; end if;

  -- Reentrada no mesmo estagio: o trigger deve ser no-op.
  update crm.opportunities set current_stage_id=current_stage_id where id=f.opportunity_id;
  select count(*) into before_count from public.events_normalized
   where client_id='3ec294db-a64a-4420-9b4a-0d917f65d399' and source_system='impuls_crm';
  if before_count <> after_count then raise exception 'IMP216_ACCEPTANCE: reentrada criou evento'; end if;

  for c in select * from imp216_expected loop
    select count(*) into expected_count from public.events_normalized where client_id=c.client_id and source_system='impuls_crm';
    select count(*) into expected_outbox from public.conversion_outbox co join public.events_normalized en on en.id=co.normalized_event_id where en.client_id=c.client_id and en.source_system='impuls_crm';
    if expected_count <> c.normalized_count or expected_outbox <> c.outbox_count then
      raise exception 'IMP216_ACCEPTANCE: variacao em cliente GHL %', c.client_id;
    end if;
  end loop;
end
$imp216_assert$;

rollback;
