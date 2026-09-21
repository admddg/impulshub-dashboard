\set ON_ERROR_STOP on

begin;
set local statement_timeout = '8s';

-- Cria dados sintéticos somente dentro desta transação. Não imprime evidence,
-- payloads ou valores financeiros.
set local role postgres;
select o.id as opportunity_id, o.tenant_id
  from crm.opportunities o
  join crm.commercial_outcomes co
    on co.tenant_id = o.tenant_id
   and co.opportunity_id = o.id
   and co.is_current
   and co.value is not null
   and co.value_status = 'valid'
 where o.tenant_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'
 order by co.occurred_at desc
 limit 1
\gset imp213_card_

select 'imp213_acceptance_' || md5(clock_timestamp()::text) as evidence
\gset imp213_

insert into crm.opportunity_milestones (tenant_id, opportunity_id, kind, origin, evidence)
values (:'imp213_card_tenant_id', :'imp213_card_opportunity_id', 'revenue', 'manual', :'imp213_evidence')
returning id
\gset imp213_milestone_

select co.value, co.value_status, co.currency
  from crm.commercial_outcomes co
 where co.tenant_id = :'imp213_card_tenant_id'
   and co.opportunity_id = :'imp213_card_opportunity_id'
   and co.is_current
   and co.value is not null
   and co.value_status = 'valid'
 order by co.occurred_at desc
 limit 1
\gset imp213_expected_

-- Atendente Central: o card continua operacional, mas evidence e os três
-- campos financeiros ficam nulos.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"bb04435c-fabb-4ba8-b5b5-e0175d9ca17d","role":"authenticated"}', true);
do $attendant$
begin
  if (select count(*) from public.v_crm_card_history_v1
       where client_id = :'imp213_card_tenant_id'
         and opportunity_id = :'imp213_card_opportunity_id'
         and milestone_kind = 'revenue') = 0 then
    raise exception 'IMP213_ACCEPTANCE: milestone revenue não visível ao atendente';
  end if;
  if exists (select 1 from public.v_crm_card_history_v1
       where client_id = :'imp213_card_tenant_id'
         and opportunity_id = :'imp213_card_opportunity_id'
         and milestone_kind = 'revenue'
         and (evidence is not null or value is not null or value_status is not null or currency is not null)) then
    raise exception 'IMP213_ACCEPTANCE: atendente recebeu campo financeiro ou evidence';
  end if;
  if exists (select 1 from public.v_crm_card_history_v1
       where client_id = :'imp213_card_tenant_id'
         and opportunity_id = :'imp213_card_opportunity_id'
         and event_kind = 'outcome'
         and (value is not null or value_status is not null or currency is not null)) then
    raise exception 'IMP213_ACCEPTANCE: atendente recebeu outcome financeiro';
  end if;
end;
$attendant$;

-- Gestor Royal: o mesmo marco e o outcome financeiro aparecem completos.
select set_config('request.jwt.claims', '{"sub":"7c3296f4-13c7-42d1-89eb-72aecec905ba","role":"authenticated"}', true);
do $manager$
declare
  got_value numeric;
  got_status text;
  got_currency text;
begin
  select value, value_status, currency
    into got_value, got_status, got_currency
    from public.v_crm_card_history_v1
   where client_id = :'imp213_card_tenant_id'
     and opportunity_id = :'imp213_card_opportunity_id'
     and event_kind = 'outcome'
     and value is not null
   order by occurred_at desc
   limit 1;
  if got_value is distinct from :'imp213_expected_value'::numeric
     or got_status is distinct from :'imp213_expected_value_status'::text
     or got_currency is distinct from :'imp213_expected_currency'::text then
    raise exception 'IMP213_ACCEPTANCE: gestor não recebeu o financeiro esperado';
  end if;
  if not exists (select 1 from public.v_crm_card_history_v1
       where client_id = :'imp213_card_tenant_id'
         and opportunity_id = :'imp213_card_opportunity_id'
         and milestone_kind = 'revenue'
         and evidence = :'imp213_evidence') then
    raise exception 'IMP213_ACCEPTANCE: gestor não recebeu evidence do marco';
  end if;
end;
$manager$;

-- O marco não persiste além do rollback desta própria acceptance.
set local role postgres;
do $cleanup$
begin
  if not exists (select 1 from crm.opportunity_milestones where id = :'imp213_milestone_id') then
    raise exception 'IMP213_ACCEPTANCE: marco sintético desapareceu antes do rollback';
  end if;
end;
$cleanup$;

rollback;

-- Consulta pós-rollback: não deve sobrar o marco sintético.
select count(*) as synthetic_rows
  from crm.opportunity_milestones
 where id = :'imp213_milestone_id';
