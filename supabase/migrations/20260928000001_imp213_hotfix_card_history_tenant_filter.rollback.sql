-- IMP-213 hotfix rollback: restaura a definicao anterior apenas para reversao emergencial.
-- ATENCAO: esta definicao anterior VAZAVA historico entre clientes porque
-- "select client_id from private.my_client_ids()" correlacionava client_id com a
-- coluna externa. NAO reaplique este rollback sem uma correcao equivalente.

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
 where gated.client_id in (select client_id from private.my_client_ids());
revoke all on table public.v_crm_card_history_v1 from public, anon, authenticated;
grant select on table public.v_crm_card_history_v1 to authenticated, service_role;

commit;
