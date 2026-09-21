-- IMP-213 hotfix: v_crm_card_history_v1 vazava historico entre clientes.
-- Causa: "select client_id from private.my_client_ids()" resolvia client_id como coluna EXTERNA (correlacionada),
-- porque my_client_ids() devolve uma coluna sem nome client_id. O filtro virava sempre verdadeiro para qualquer membro.
-- Correcao: nomear a coluna do helper no proprio FROM (alias m) e comparar com m.

begin;
set local lock_timeout = '5s';

create or replace view public.v_crm_card_history_v1
with (security_barrier = true, security_invoker = false) as
select gated.*
  from (
SELECT h.tenant_id AS client_id,
    h.opportunity_id,
    h.occurred_at,
    'stage'::text AS event_kind,
    h.transition_type,
    h.origin,
    fs.code AS from_stage_code,
    fs.label AS from_stage_label,
    ts.code AS to_stage_code,
    ts.label AS to_stage_label,
    NULL::text AS milestone_kind,
    NULL::text AS outcome,
    NULL::text AS loss_reason_code,
    NULL::text AS loss_reason_label,
    NULL::numeric AS value,
    NULL::text AS value_status,
    NULL::text AS currency,
    NULL::text AS evidence,
    h.reason,
    h.actor_profile_id,
    ap.display_name AS actor_name
   FROM crm.opportunity_stage_history h
     LEFT JOIN crm.global_pipeline_stages fs ON fs.id = h.from_stage_id
     JOIN crm.global_pipeline_stages ts ON ts.id = h.to_stage_id
     LEFT JOIN crm.profiles ap ON ap.id = h.actor_profile_id
UNION ALL
 SELECT m.tenant_id AS client_id,
    m.opportunity_id,
    m.occurred_at,
    'milestone'::text AS event_kind,
    NULL::text AS transition_type,
    m.origin,
    NULL::text AS from_stage_code,
    NULL::text AS from_stage_label,
    NULL::text AS to_stage_code,
    NULL::text AS to_stage_label,
    m.kind AS milestone_kind,
    NULL::text AS outcome,
    NULL::text AS loss_reason_code,
    NULL::text AS loss_reason_label,
    NULL::numeric AS value,
    NULL::text AS value_status,
    NULL::text AS currency,
    CASE WHEN m.kind = 'revenue' AND NOT (m.tenant_id IN (SELECT client_id FROM private.financial_client_ids())) THEN NULL::text ELSE m.evidence END AS evidence,
    NULL::text AS reason,
    m.actor_profile_id,
    ap.display_name AS actor_name
   FROM crm.opportunity_milestones m
     LEFT JOIN crm.profiles ap ON ap.id = m.actor_profile_id
UNION ALL
 SELECT co.tenant_id AS client_id,
    co.opportunity_id,
    co.occurred_at,
    'outcome'::text AS event_kind,
    NULL::text AS transition_type,
    co.origin,
    NULL::text AS from_stage_code,
    NULL::text AS from_stage_label,
    NULL::text AS to_stage_code,
    NULL::text AS to_stage_label,
    NULL::text AS milestone_kind,
    co.outcome,
    lr.code AS loss_reason_code,
    lr.label AS loss_reason_label,
    CASE WHEN co.tenant_id IN (SELECT client_id FROM private.financial_client_ids()) THEN co.value ELSE NULL::numeric END AS value,
    CASE WHEN co.tenant_id IN (SELECT client_id FROM private.financial_client_ids()) THEN co.value_status ELSE NULL::text END AS value_status,
    CASE WHEN co.tenant_id IN (SELECT client_id FROM private.financial_client_ids()) THEN co.currency ELSE NULL::text END AS currency,
    co.evidence,
    NULL::text AS reason,
    co.actor_profile_id,
    ap.display_name AS actor_name
   FROM crm.commercial_outcomes co
     LEFT JOIN crm.canonical_loss_reasons lr ON lr.id = co.loss_reason_id
     LEFT JOIN crm.profiles ap ON ap.id = co.actor_profile_id
  ) as gated
 where gated.client_id in (select m from private.my_client_ids() as m);
revoke all on table public.v_crm_card_history_v1 from public, anon, authenticated;
grant select on table public.v_crm_card_history_v1 to authenticated, service_role;

do $gate$
begin
  if pg_get_viewdef('public.v_crm_card_history_v1'::regclass, true) ~ 'SELECT gated\.client_id\s+FROM private\.my_client_ids' then
    raise exception 'IMP213_HOTFIX: filtro ainda correlacionado';
  end if;
  if not exists (select 1 from pg_class c where c.oid='public.v_crm_card_history_v1'::regclass and c.reloptions @> array['security_barrier=true','security_invoker=false']) then
    raise exception 'IMP213_HOTFIX: opcoes da view perdidas';
  end if;
  if has_table_privilege('anon','public.v_crm_card_history_v1','select') then
    raise exception 'IMP213_HOTFIX: anon le a view';
  end if;
end;
$gate$;

insert into supabase_migrations.schema_migrations (version, name)
values ('20260928000001', 'imp213_hotfix_card_history_tenant_filter')
on conflict (version) do nothing;

commit;
