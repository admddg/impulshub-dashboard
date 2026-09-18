-- IMP-206/207: camada de leitura em public para a aba CRM.
--
-- O PostgREST so expoe o schema public, e pgrst.db_schemas nao esta definido
-- neste projeto. O navegador nao alcanca o schema crm nem para ler: antes
-- destas views, nao havia uma unica view ou funcao em public que o tocasse.
--
-- security_invoker = true faz cada view rodar como o usuario que consulta,
-- entao a RLS por crm.is_member(tenant_id) continua valendo dentro delas.
--
-- Contrato completo em docs/CONTRATO-TELA-CRM.md.

set local lock_timeout = '5s';

-- Contagem por coluna do kanban. Sempre 6 linhas por cliente, inclusive as
-- zeradas: a coluna vazia precisa aparecer. O frontend nao conta linha.
create view public.v_crm_board_counts_v1
with (security_invoker = true) as
select t.id                                as client_id,
       s.code                              as stage_code,
       s.label                             as stage_label,
       s.position                          as stage_position,
       s.is_terminal,
       count(o.id)                         as opportunities
  from crm.tenants t
 cross join crm.global_pipeline_stages s
  join crm.global_pipeline_versions v
    on v.id = s.pipeline_version_id and v.status = 'active'
  left join crm.opportunities o
    on o.tenant_id = t.id and o.current_stage_id = s.id
 group by t.id, s.code, s.label, s.position, s.is_terminal;

-- O card. O distinct on no join de midia e obrigatorio: v_meta_ads_v2 tem grao
-- de anuncio-por-dia e 293 de 304 ad_id aparecem em mais de uma data. Sem ele,
-- 240 cards viram 17.401 e a contagem para de bater com o board -- silenciosamente.
create view public.v_crm_cards_v1
with (security_invoker = true) as
select o.tenant_id                          as client_id,
       o.id                                 as opportunity_id,
       o.contact_id,
       c.full_name                          as contact_name,
       c.phone_normalized,
       case when c.phone_normalized is not null
            then 'https://wa.me/' || c.phone_normalized end as whatsapp_url,
       o.title,
       s.code                               as stage_code,
       s.label                              as stage_label,
       s.position                           as stage_position,
       s.is_terminal,
       o.status,
       o.stage_version,
       o.owner_profile_id,
       p.display_name                       as owner_name,
       o.opened_at,
       o.closed_at,
       (select max(a.created_at) from crm.activities a
         where a.tenant_id = o.tenant_id and a.contact_id = o.contact_id) as last_activity_at,
       o.meta_ad_id,
       ad.ad_name,
       ad.adset_name,
       ad.campaign_name,
       ad.creative_name,
       ad.thumbnail_url,
       o.ctwa_clid,
       o.conversion_source,
       o.entry_point_conversion_source,
       o.source_url,
       o.ad_title
  from crm.opportunities o
  join crm.contacts c
    on c.tenant_id = o.tenant_id and c.id = o.contact_id
  join crm.global_pipeline_stages s
    on s.id = o.current_stage_id
  left join crm.profiles p
    on p.id = o.owner_profile_id
  left join lateral (
       select m.ad_name, m.adset_name, m.campaign_name, m.creative_name, m.thumbnail_url
         from public.v_meta_ads_v2 m
        where m.client_id = o.tenant_id and m.ad_id = o.meta_ad_id
        order by m.date desc
        limit 1
  ) ad on o.meta_ad_id is not null;

-- Lista de contatos com busca. opportunity_id e a MAIS RECENTE do contato:
-- hoje e 1:1, mas o schema suporta ciclos via previous_opportunity_id.
create view public.v_crm_contacts_v1
with (security_invoker = true) as
select c.tenant_id                          as client_id,
       c.id                                 as contact_id,
       c.full_name,
       c.phone_normalized,
       c.email,
       case when c.phone_normalized is not null
            then 'https://wa.me/' || c.phone_normalized end as whatsapp_url,
       c.status,
       act.last_activity_at,
       coalesce(act.messages_total, 0)      as messages_total,
       o.id                                 as opportunity_id,
       s.code                               as stage_code,
       s.label                              as stage_label,
       s.position                           as stage_position,
       o.status                             as opportunity_status,
       pg_catalog.lower(c.full_name) || ' ' || coalesce(c.phone_normalized, '') as search_text
  from crm.contacts c
  left join lateral (
       select max(a.created_at) as last_activity_at, count(*) as messages_total
         from crm.activities a
        where a.tenant_id = c.tenant_id and a.contact_id = c.id
  ) act on true
  left join lateral (
       select o2.id, o2.status, o2.current_stage_id
         from crm.opportunities o2
        where o2.tenant_id = c.tenant_id and o2.contact_id = c.id
        order by o2.opened_at desc, o2.created_at desc
        limit 1
  ) o on true
  left join crm.global_pipeline_stages s on s.id = o.current_stage_id;

-- Linha do tempo do card: uniao das tres tabelas append-only.
-- A tela mostra; nunca reescreve. Os triggers append_only ja garantem isso.
create view public.v_crm_card_history_v1
with (security_invoker = true) as
select h.tenant_id as client_id, h.opportunity_id, h.occurred_at,
       'stage'::text as event_kind,
       h.transition_type, h.origin,
       fs.code as from_stage_code, fs.label as from_stage_label,
       ts.code as to_stage_code,   ts.label as to_stage_label,
       null::text as milestone_kind, null::text as outcome,
       null::text as loss_reason_code, null::text as loss_reason_label,
       null::numeric as value, null::text as value_status, null::text as currency,
       null::text as evidence, h.reason,
       h.actor_profile_id, ap.display_name as actor_name
  from crm.opportunity_stage_history h
  left join crm.global_pipeline_stages fs on fs.id = h.from_stage_id
  join crm.global_pipeline_stages ts on ts.id = h.to_stage_id
  left join crm.profiles ap on ap.id = h.actor_profile_id
union all
select m.tenant_id, m.opportunity_id, m.occurred_at,
       'milestone', null, m.origin,
       null, null, null, null,
       m.kind, null, null, null,
       null, null, null,
       m.evidence, null,
       m.actor_profile_id, ap.display_name
  from crm.opportunity_milestones m
  left join crm.profiles ap on ap.id = m.actor_profile_id
union all
select co.tenant_id, co.opportunity_id, co.occurred_at,
       'outcome', null, co.origin,
       null, null, null, null,
       null, co.outcome,
       lr.code, lr.label,
       co.value, co.value_status, co.currency,
       co.evidence, null,
       co.actor_profile_id, ap.display_name
  from crm.commercial_outcomes co
  left join crm.canonical_loss_reasons lr on lr.id = co.loss_reason_id
  left join crm.profiles ap on ap.id = co.actor_profile_id;

-- Mensagens. Escopada por CONTATO, nao por oportunidade: 5.827 das 8.887
-- atividades nao tem opportunity_id. Uma view por oportunidade esconderia
-- dois tercos da conversa, e ninguem perceberia -- a tela mostraria
-- mensagens, so que menos.
create view public.v_crm_activities_v1
with (security_invoker = true) as
select a.tenant_id as client_id, a.contact_id, a.opportunity_id,
       a.id as activity_id, a.created_at, a.kind, a.direction,
       a.body, a.provider_message_id
  from crm.activities a;

-- Quem pode ser dono. Base obrigatoria e tenant_memberships: a FK composta de
-- opportunities.owner_profile_id aponta para (tenant_id, profile_id) de la.
-- can_write sai de public.client_users, que e de onde o trigger le.
create view public.v_crm_owners_v1
with (security_invoker = true) as
select tm.tenant_id as client_id,
       tm.profile_id,
       p.display_name,
       tm.role as membership_role,
       coalesce(cu.is_active and pg_catalog.lower(cu.role) <> 'viewer', false) as can_write
  from crm.tenant_memberships tm
  join crm.profiles p on p.id = tm.profile_id
  left join public.client_users cu
    on cu.client_id = tm.tenant_id and cu.user_id = tm.profile_id
 where tm.status = 'active';

-- Motivos canonicos de perda. Sem escopo de cliente: a policy e using(true).
create view public.v_crm_loss_reasons_v1
with (security_invoker = true) as
select code, label, requires_note, active
  from crm.canonical_loss_reasons;

-- O papel do usuario corrente. E o que esconde os botoes de acao do viewer,
-- em vez de deixar o usuario clicar e tomar erro de trigger.
create view public.v_crm_my_role_v1
with (security_invoker = true) as
select cu.client_id,
       cu.role,
       (cu.is_active and pg_catalog.lower(cu.role) <> 'viewer') as can_write
  from public.client_users cu
 where cu.user_id = auth.uid();

grant select on
  public.v_crm_board_counts_v1,
  public.v_crm_cards_v1,
  public.v_crm_contacts_v1,
  public.v_crm_card_history_v1,
  public.v_crm_activities_v1,
  public.v_crm_owners_v1,
  public.v_crm_loss_reasons_v1,
  public.v_crm_my_role_v1
to authenticated;
