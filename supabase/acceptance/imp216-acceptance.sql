\set ON_ERROR_STOP on

-- Aceite IMP-216. Executar somente em sessao autorizada; termina em ROLLBACK.
begin;
-- a migration deixa as constraints em immediate; o app roda com o padrao (deferred).
set constraints all deferred;
set local statement_timeout = '8s';

-- Esperados calculados como postgres antes de trocar o papel.
set local role postgres;

-- A prova simula o cliente sem GHL dentro da transacao. Se a coluna deixar
-- de aceitar NULL, o aceite falha explicitamente em vez de mascarar o caso.
-- clients_base.ghl_location_id e NOT NULL: cliente sem GHL e simulado com ''.

create temporary table imp216_expected as
select cb.id as client_id,
       count(en.id)::bigint as normalized_count,
       (select count(*)::bigint
          from public.conversion_outbox co
         where co.normalized_event_id in (
           select en2.id
             from public.events_normalized en2
            where en2.client_id = cb.id
              and en2.source_system = 'impuls_crm'
         )) as outbox_count
  from public.clients_base cb
  left join public.events_normalized en
    on en.client_id = cb.id
   and en.source_system = 'impuls_crm'
 where cb.id = any(array[
   '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid,
   '3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid,
   'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid
 ])
 group by cb.id;

-- Fixtures dinamicas: um card do ImpulsHub e cards GHL com proxima etapa.
create temporary table imp216_fixture as
select o.id as opportunity_id,
       o.stage_version,
       s2.code as next_stage_code
  from crm.opportunities o
  join crm.global_pipeline_stages s1 on s1.id = o.current_stage_id
  join crm.global_pipeline_stages s2
    on s2.pipeline_version_id = o.pipeline_version_id
   and s2.position = s1.position + 1
 where o.tenant_id = '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid
   and o.status = 'open'
   and not s1.is_terminal
   and not s2.is_terminal
 order by o.updated_at, o.id
 limit 1;

create temporary table imp216_ghl_fixture as
select o.tenant_id as client_id,
       o.id as opportunity_id,
       o.stage_version,
       s2.code as next_stage_code
  from crm.opportunities o
  join crm.global_pipeline_stages s1 on s1.id = o.current_stage_id
  join crm.global_pipeline_stages s2
    on s2.pipeline_version_id = o.pipeline_version_id
   and s2.position = s1.position + 1
 where o.tenant_id = any(array[
   '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid,
   '3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid,
   'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid
 ])
   and o.status = 'open'
   and not s1.is_terminal
   and not s2.is_terminal
 order by o.tenant_id, o.updated_at, o.id;

select count(*) as impuls_fixture_count from imp216_fixture;
select count(*) as ghl_fixture_count from imp216_ghl_fixture;

-- Simula cliente sem GHL antes do movimento; tudo sera desfeito no ROLLBACK.
update public.clients_base
   set ghl_location_id = '',
       ghl_location_name = null
 where id = '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid;

grant select on imp216_expected, imp216_fixture, imp216_ghl_fixture to authenticated;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"d036c4d6-0969-4175-b917-ff7e4dd3b376","role":"authenticated"}', true);

do $imp216_moves$
declare
  f record;
  g record;
  royal_count integer;
begin
  select * into f from imp216_fixture;
  if not found then
    raise exception 'IMP216_ACCEPTANCE: fixture sem GHL ausente no tenant ImpulsHub';
  end if;
  perform public.crm_move_stage(f.opportunity_id, f.next_stage_code, f.stage_version, 'IMP216 acceptance');

  select count(*) into royal_count
    from imp216_ghl_fixture
   where client_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid;
  if royal_count = 0 then
    raise exception 'IMP216_ACCEPTANCE: fixture GHL ausente para Royal';
  end if;

  -- Royal e, quando houver card elegivel, Central e QuickClean: flags desligadas.
  for g in select * from imp216_ghl_fixture order by client_id, opportunity_id loop
    perform public.crm_move_stage(g.opportunity_id, g.next_stage_code, g.stage_version, 'IMP216 GHL zero delta');
  end loop;
end
$imp216_moves$;

set local role postgres;
do $imp216_assert$
declare
  f record;
  before_count bigint;
  after_count bigint;
  before_outbox bigint;
  after_outbox bigint;
  c record;
  v_version integer;
  v_stage_code text;
  exception_seen boolean := false;
begin
  select * into f from imp216_fixture;

  select normalized_count, outbox_count
    into before_count, before_outbox
    from imp216_expected
   where client_id = '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid;
  select count(*) into after_count
    from public.events_normalized
   where client_id = '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid
     and source_system = 'impuls_crm';
  select count(*) into after_outbox
    from public.conversion_outbox co
    join public.events_normalized en on en.id = co.normalized_event_id
   where en.client_id = '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid
     and en.source_system = 'impuls_crm';
  if after_count - before_count <> 1 then
    raise exception 'IMP216_ACCEPTANCE: evento sem GHL nao aumentou exatamente 1 (delta=%)', after_count - before_count;
  end if;
  if after_outbox - before_outbox <> 0 then
    raise exception 'IMP216_ACCEPTANCE: conversion_outbox recebeu linha sem flag (delta=%)', after_outbox - before_outbox;
  end if;

  -- Repetir a mesma etapa: a chave oportunidade/evento deve ser no-op.
  select o.stage_version, s.code
    into v_version, v_stage_code
    from crm.opportunities o
    join crm.global_pipeline_stages s on s.id = o.current_stage_id
   where o.id = f.opportunity_id;
  set local role authenticated;
  perform public.crm_move_stage(f.opportunity_id, v_stage_code, v_version, 'IMP216 reentrada');
  set local role postgres;
  select count(*) into after_count
    from public.events_normalized
   where client_id = '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid
     and source_system = 'impuls_crm';
  if after_count <> before_count + 1 then
    raise exception 'IMP216_ACCEPTANCE: reentrada criou evento (count=%)', after_count;
  end if;

  -- Variação zero real para cada cliente com GHL que tinha fixture elegivel.
  for c in
    select *
      from imp216_expected
     where client_id <> '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid
  loop
    select count(*) into after_count
      from public.events_normalized
     where client_id = c.client_id and source_system = 'impuls_crm';
    select count(*) into after_outbox
      from public.conversion_outbox co
      join public.events_normalized en on en.id = co.normalized_event_id
     where en.client_id = c.client_id and en.source_system = 'impuls_crm';
    if after_count <> c.normalized_count or after_outbox <> c.outbox_count then
      raise exception 'IMP216_ACCEPTANCE: variacao em cliente GHL % (events %, outbox %; esperados %, %)',
        c.client_id, after_count - c.normalized_count, after_outbox - c.outbox_count,
        c.normalized_count, c.outbox_count;
    end if;
  end loop;

  -- Com emissao ligada e GHL vazio, a conversao continua bloqueada.
  update public.clients_base
     set crm_emits_conversions = true,
         ghl_location_id = ''
   where id = '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid;
  set local role authenticated;
  begin
    select o.stage_version, s2.code
      into v_version, v_stage_code
      from crm.opportunities o
      join crm.global_pipeline_stages s1 on s1.id = o.current_stage_id
      join crm.global_pipeline_stages s2
        on s2.pipeline_version_id = o.pipeline_version_id
       and s2.position = s1.position + 1
     where o.id = f.opportunity_id
       and not s2.is_terminal;
    if v_stage_code is null then
      raise exception 'IMP216_ACCEPTANCE: fixture sem GHL nao tem segunda etapa para guard';
    end if;
    perform public.crm_move_stage(f.opportunity_id, v_stage_code, v_version, 'IMP216 conversion guard');
  exception when others then
    if sqlerrm not like 'IMP-216 ghl_location_id is required only for conversion emission%' then
      raise;
    end if;
    exception_seen := true;
  end;
  if not exception_seen then
    raise exception 'IMP216_ACCEPTANCE: conversao sem GHL nao levantou a excecao esperada';
  end if;
  set local role postgres;
end
$imp216_assert$;

rollback;
