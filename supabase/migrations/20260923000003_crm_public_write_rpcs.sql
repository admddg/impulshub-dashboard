-- IMP-206/207: camada de escrita em public para a aba CRM.
--
-- SECURITY DEFINER porque o navegador nao alcanca o schema crm. A autoridade
-- nunca vem do cliente: o tenant e resolvido pela propria oportunidade e o ator
-- e sempre auth.uid().
--
-- Todas devolvem a linha atualizada de v_crm_cards_v1, para a tela
-- re-renderizar do banco em vez de adivinhar o estado novo.
--
-- Contrato completo em docs/CONTRATO-TELA-CRM.md.

set local lock_timeout = '5s';

-- Guarda comum das quatro. Devolve o tenant e trava a oportunidade.
create function public.crm_guard(p_opportunity_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_tenant uuid;
begin
  select o.tenant_id into v_tenant
    from crm.opportunities o
   where o.id = p_opportunity_id
     for update;

  if v_tenant is null then
    raise exception 'CRM_FORBIDDEN: oportunidade inexistente ou inacessivel';
  end if;

  if not crm.is_member(v_tenant) then
    raise exception 'CRM_FORBIDDEN: sem acesso a este cliente';
  end if;

  if not exists (
    select 1 from public.client_users cu
     where cu.client_id = v_tenant
       and cu.user_id = auth.uid()
       and cu.is_active
       and pg_catalog.lower(cu.role) <> 'viewer'
  ) then
    raise exception 'CRM_FORBIDDEN: papel sem permissao de escrita';
  end if;

  return v_tenant;
end;
$fn$;

create function public.crm_move_stage(
  p_opportunity_id uuid,
  p_to_stage_code text,
  p_expected_stage_version integer,
  p_reason text default null
)
returns setof public.v_crm_cards_v1
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_tenant uuid;
  v_from_pos smallint; v_from_id uuid; v_status text; v_version integer;
  v_to_id uuid; v_to_pos smallint; v_pipeline uuid;
  v_milestone text;
begin
  v_tenant := public.crm_guard(p_opportunity_id);

  select o.current_stage_id, o.status, o.stage_version, o.pipeline_version_id
    into v_from_id, v_status, v_version, v_pipeline
    from crm.opportunities o where o.id = p_opportunity_id;

  if v_version is distinct from p_expected_stage_version then
    raise exception 'CRM_STAGE_CONFLICT: o card foi movido por outra pessoa';
  end if;
  if v_status <> 'open' then
    raise exception 'CRM_TERMINAL: oportunidade ja encerrada';
  end if;
  if p_to_stage_code in ('ganho', 'perdido') then
    raise exception 'CRM_USE_OUTCOME_RPC: use crm_register_won ou crm_register_lost';
  end if;

  select s.id, s.position into v_to_id, v_to_pos
    from crm.global_pipeline_stages s
   where s.pipeline_version_id = v_pipeline and s.code = p_to_stage_code;
  if v_to_id is null then
    raise exception 'CRM_INVALID_STAGE: etapa desconhecida';
  end if;

  select s.position into v_from_pos
    from crm.global_pipeline_stages s where s.id = v_from_id;

  if v_to_pos < v_from_pos
     and pg_catalog.length(pg_catalog.btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'CRM_REASON_REQUIRED: regressao exige motivo';
  end if;

  insert into crm.opportunity_stage_history
    (tenant_id, opportunity_id, from_stage_id, to_stage_id,
     transition_type, origin, actor_profile_id, reason, occurred_at)
  values
    (v_tenant, p_opportunity_id, v_from_id, v_to_id,
     'manual', 'manual', auth.uid(), p_reason, pg_catalog.now());

  update crm.opportunities o
     set current_stage_id = v_to_id,
         stage_version = o.stage_version + 1,
         updated_at = pg_catalog.now()
   where o.id = p_opportunity_id;

  v_milestone := case p_to_stage_code
                   when 'agendado' then 'appointment'
                   when 'compareceu' then 'attendance' end;

  if v_milestone is not null then
    insert into crm.opportunity_milestones
      (tenant_id, opportunity_id, kind, origin, actor_profile_id, evidence, occurred_at)
    values
      (v_tenant, p_opportunity_id, v_milestone, 'manual', auth.uid(),
       coalesce(p_reason, 'movimento manual pelo painel'), pg_catalog.now());
  end if;

  return query select * from public.v_crm_cards_v1 c
                where c.opportunity_id = p_opportunity_id;
end;
$fn$;

create function public.crm_set_owner(
  p_opportunity_id uuid,
  p_owner_profile_id uuid
)
returns setof public.v_crm_cards_v1
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_tenant uuid;
begin
  v_tenant := public.crm_guard(p_opportunity_id);

  if p_owner_profile_id is not null and not exists (
    select 1 from crm.tenant_memberships tm
     where tm.tenant_id = v_tenant
       and tm.profile_id = p_owner_profile_id
       and tm.status = 'active'
  ) then
    raise exception 'CRM_INVALID_OWNER: pessoa nao e membro ativo deste cliente';
  end if;

  update crm.opportunities o
     set owner_profile_id = p_owner_profile_id,
         updated_at = pg_catalog.now()
   where o.id = p_opportunity_id;

  return query select * from public.v_crm_cards_v1 c
                where c.opportunity_id = p_opportunity_id;
end;
$fn$;

create function public.crm_register_won(
  p_opportunity_id uuid,
  p_evidence text,
  p_expected_stage_version integer,
  p_value numeric default null,
  p_currency text default 'BRL'
)
returns setof public.v_crm_cards_v1
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_tenant uuid; v_from_id uuid; v_status text; v_version integer; v_pipeline uuid;
  v_ganho uuid; v_value numeric; v_value_status text; v_currency text;
begin
  v_tenant := public.crm_guard(p_opportunity_id);

  select o.current_stage_id, o.status, o.stage_version, o.pipeline_version_id
    into v_from_id, v_status, v_version, v_pipeline
    from crm.opportunities o where o.id = p_opportunity_id;

  if v_version is distinct from p_expected_stage_version then
    raise exception 'CRM_STAGE_CONFLICT: o card foi movido por outra pessoa';
  end if;
  if v_status <> 'open' then
    raise exception 'CRM_TERMINAL: oportunidade ja encerrada';
  end if;

  -- validate_commercial_outcome exige evidence nao-vazio para TODO outcome
  -- com origin='manual', inclusive Ganho. Sem o campo de observacao na tela,
  -- todo Ganho seria recusado pelo banco.
  if pg_catalog.length(pg_catalog.btrim(coalesce(p_evidence, ''))) = 0 then
    raise exception 'CRM_EVIDENCE_REQUIRED: observacao obrigatoria no ganho';
  end if;

  -- Valor ausente permanece pendente, nunca zero. Nao existe caminho aqui
  -- que produza value = 0; p_value = 0 e recusado antes do CHECK, para o
  -- atendente ver uma mensagem em vez de um 23514.
  if p_value is null then
    v_value := null; v_value_status := 'pending'; v_currency := null;
  elsif p_value > 0 then
    v_value := p_value; v_value_status := 'valid'; v_currency := coalesce(p_currency, 'BRL');
  else
    raise exception 'CRM_INVALID_VALUE: valor deve ser positivo ou nao informado';
  end if;

  select s.id into v_ganho from crm.global_pipeline_stages s
   where s.pipeline_version_id = v_pipeline and s.code = 'ganho';

  insert into crm.opportunity_stage_history
    (tenant_id, opportunity_id, from_stage_id, to_stage_id,
     transition_type, origin, actor_profile_id, occurred_at)
  values
    (v_tenant, p_opportunity_id, v_from_id, v_ganho,
     'manual', 'manual', auth.uid(), pg_catalog.now());

  update crm.opportunities o
     set current_stage_id = v_ganho, status = 'won',
         closed_at = pg_catalog.now(),
         stage_version = o.stage_version + 1,
         updated_at = pg_catalog.now()
   where o.id = p_opportunity_id;

  insert into crm.commercial_outcomes
    (tenant_id, opportunity_id, outcome, origin, actor_profile_id,
     evidence, value, value_status, currency, is_current, occurred_at)
  values
    (v_tenant, p_opportunity_id, 'won', 'manual', auth.uid(),
     p_evidence, v_value, v_value_status, v_currency, true, pg_catalog.now());

  insert into crm.opportunity_milestones
    (tenant_id, opportunity_id, kind, origin, actor_profile_id, evidence, occurred_at)
  values
    (v_tenant, p_opportunity_id, 'sale', 'manual', auth.uid(), p_evidence, pg_catalog.now());

  if v_value is not null then
    insert into crm.opportunity_milestones
      (tenant_id, opportunity_id, kind, origin, actor_profile_id, evidence, occurred_at)
    values
      (v_tenant, p_opportunity_id, 'revenue', 'manual', auth.uid(),
       v_currency || ' ' || v_value::text, pg_catalog.now());
  end if;

  return query select * from public.v_crm_cards_v1 c
                where c.opportunity_id = p_opportunity_id;
end;
$fn$;

create function public.crm_register_lost(
  p_opportunity_id uuid,
  p_loss_reason_code text,
  p_expected_stage_version integer,
  p_note text default null
)
returns setof public.v_crm_cards_v1
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_tenant uuid; v_from_id uuid; v_status text; v_version integer; v_pipeline uuid;
  v_perdido uuid; v_reason_id uuid; v_requires_note boolean; v_label text; v_evidence text;
begin
  v_tenant := public.crm_guard(p_opportunity_id);

  select o.current_stage_id, o.status, o.stage_version, o.pipeline_version_id
    into v_from_id, v_status, v_version, v_pipeline
    from crm.opportunities o where o.id = p_opportunity_id;

  if v_version is distinct from p_expected_stage_version then
    raise exception 'CRM_STAGE_CONFLICT: o card foi movido por outra pessoa';
  end if;
  if v_status <> 'open' then
    raise exception 'CRM_TERMINAL: oportunidade ja encerrada';
  end if;

  select r.id, r.requires_note, r.label
    into v_reason_id, v_requires_note, v_label
    from crm.canonical_loss_reasons r
   where r.code = p_loss_reason_code and r.active;
  if v_reason_id is null then
    raise exception 'CRM_INVALID_REASON: motivo de perda desconhecido ou inativo';
  end if;

  if v_requires_note
     and pg_catalog.length(pg_catalog.btrim(coalesce(p_note, ''))) = 0 then
    raise exception 'CRM_NOTE_REQUIRED: este motivo exige observacao';
  end if;

  -- origin='manual' exige evidence nao-vazio tambem aqui: cai para o label
  -- do motivo quando o atendente nao escreveu nota.
  v_evidence := coalesce(nullif(pg_catalog.btrim(coalesce(p_note, '')), ''), v_label);

  select s.id into v_perdido from crm.global_pipeline_stages s
   where s.pipeline_version_id = v_pipeline and s.code = 'perdido';

  insert into crm.opportunity_stage_history
    (tenant_id, opportunity_id, from_stage_id, to_stage_id,
     transition_type, origin, actor_profile_id, reason, occurred_at)
  values
    (v_tenant, p_opportunity_id, v_from_id, v_perdido,
     'manual', 'manual', auth.uid(), v_evidence, pg_catalog.now());

  update crm.opportunities o
     set current_stage_id = v_perdido, status = 'lost',
         closed_at = pg_catalog.now(),
         stage_version = o.stage_version + 1,
         updated_at = pg_catalog.now()
   where o.id = p_opportunity_id;

  -- commercial_outcomes_check2: perda obriga value_status='pending'.
  -- Nao existe Perdido com valor, e a RPC nem recebe valor.
  insert into crm.commercial_outcomes
    (tenant_id, opportunity_id, outcome, origin, actor_profile_id,
     loss_reason_id, evidence, value, value_status, currency, is_current, occurred_at)
  values
    (v_tenant, p_opportunity_id, 'lost', 'manual', auth.uid(),
     v_reason_id, v_evidence, null, 'pending', null, true, pg_catalog.now());

  return query select * from public.v_crm_cards_v1 c
                where c.opportunity_id = p_opportunity_id;
end;
$fn$;

revoke execute on function
  public.crm_guard(uuid),
  public.crm_move_stage(uuid, text, integer, text),
  public.crm_set_owner(uuid, uuid),
  public.crm_register_won(uuid, text, integer, numeric, text),
  public.crm_register_lost(uuid, text, integer, text)
from public, anon;

grant execute on function
  public.crm_move_stage(uuid, text, integer, text),
  public.crm_set_owner(uuid, uuid),
  public.crm_register_won(uuid, text, integer, numeric, text),
  public.crm_register_lost(uuid, text, integer, text)
to authenticated;
