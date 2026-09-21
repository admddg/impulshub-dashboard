-- IMP-214 rollback. ATENÇÃO: sales_owner_profile_id é descartado; apenas crc_owner_profile_id é restaurado em owner_profile_id.
-- Definições de views/funções de produção capturadas por SELECT antes da alteração.
-- A migração é executada transacionalmente pelo Supabase.
set local lock_timeout = '5s';

drop function public.crm_set_owner(uuid, text, uuid);
drop function public.crm_board_counts(uuid, date, date, text, uuid, boolean, text);
drop function public.crm_move_stage(uuid, text, integer, text);
drop function public.crm_register_won(uuid, text, integer, numeric, text);
drop function public.crm_register_lost(uuid, text, integer, text);

drop view public.v_crm_cards_v1;
drop view public.v_crm_contacts_v1;
drop view public.v_crm_owners_v1;
drop trigger if exists opportunities_validate_owners on crm.opportunities;
drop function if exists crm.validate_opportunity_owners();

alter table crm.opportunities drop constraint if exists opportunities_tenant_crc_owner_profile_id_fkey;
alter table crm.opportunities drop constraint if exists opportunities_tenant_sales_owner_profile_id_fkey;
alter table crm.opportunities add column owner_profile_id uuid;
update crm.opportunities set owner_profile_id = crc_owner_profile_id where crc_owner_profile_id is not null;
set constraints all immediate;
alter table crm.opportunities drop column crc_owner_profile_id;
alter table crm.opportunities drop column sales_owner_profile_id;
alter table crm.opportunities add constraint opportunities_tenant_id_owner_profile_id_fkey
  foreign key (tenant_id, owner_profile_id)
  references crm.tenant_memberships(tenant_id, profile_id) on delete restrict;
alter table crm.tenant_memberships drop column is_assignable;

create view public.v_crm_cards_v1 with (security_invoker = true) as
SELECT o.tenant_id AS client_id,
    o.id AS opportunity_id,
    o.contact_id,
    c.full_name AS contact_name,
    c.phone_normalized,
        CASE
            WHEN c.phone_normalized IS NOT NULL THEN 'https://wa.me/'::text || c.phone_normalized
            ELSE NULL::text
        END AS whatsapp_url,
    o.title,
    s.code AS stage_code,
    s.label AS stage_label,
    s."position" AS stage_position,
    s.is_terminal,
    o.status,
    o.stage_version,
    o.owner_profile_id,
    p.display_name AS owner_name,
    o.opened_at,
    o.closed_at,
    ( SELECT max(a.created_at) AS max
           FROM crm.activities a
          WHERE a.tenant_id = o.tenant_id AND a.contact_id = o.contact_id) AS last_activity_at,
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
   FROM crm.opportunities o
     JOIN crm.contacts c ON c.tenant_id = o.tenant_id AND c.id = o.contact_id
     JOIN crm.global_pipeline_stages s ON s.id = o.current_stage_id
     LEFT JOIN crm.profiles p ON p.id = o.owner_profile_id
     LEFT JOIN LATERAL ( SELECT m.ad_name,
            m.adset_name,
            m.campaign_name,
            m.creative_name,
            m.thumbnail_url
           FROM v_meta_ads_v2 m
          WHERE m.client_id = o.tenant_id AND m.ad_id = o.meta_ad_id
          ORDER BY m.date DESC
         LIMIT 1) ad ON o.meta_ad_id IS NOT NULL;
create view public.v_crm_contacts_v1 with (security_invoker = true) as
SELECT c.tenant_id AS client_id,
    c.id AS contact_id,
    c.full_name,
    c.phone_normalized,
    c.email,
        CASE
            WHEN c.phone_normalized IS NOT NULL THEN 'https://wa.me/'::text || c.phone_normalized
            ELSE NULL::text
        END AS whatsapp_url,
    c.status,
    act.last_activity_at,
    COALESCE(act.messages_total, 0::bigint) AS messages_total,
    o.id AS opportunity_id,
    s.code AS stage_code,
    s.label AS stage_label,
    s."position" AS stage_position,
    o.status AS opportunity_status,
    (lower(c.full_name) || ' '::text) || COALESCE(c.phone_normalized, ''::text) AS search_text,
    o.opened_at,
    o.owner_profile_id
   FROM crm.contacts c
     LEFT JOIN LATERAL ( SELECT max(a.created_at) AS last_activity_at,
            count(*) AS messages_total
           FROM crm.activities a
          WHERE a.tenant_id = c.tenant_id AND a.contact_id = c.id) act ON true
     LEFT JOIN LATERAL ( SELECT o2.id,
            o2.status,
            o2.current_stage_id,
            o2.opened_at,
            o2.owner_profile_id
           FROM crm.opportunities o2
          WHERE o2.tenant_id = c.tenant_id AND o2.contact_id = c.id
          ORDER BY o2.opened_at DESC, o2.created_at DESC
         LIMIT 1) o ON true
     LEFT JOIN crm.global_pipeline_stages s ON s.id = o.current_stage_id;
create view public.v_crm_owners_v1 with (security_invoker = true) as
SELECT tm.tenant_id AS client_id,
    tm.profile_id,
    p.display_name,
    tm.role AS membership_role,
    crm.can_write(tm.tenant_id, tm.profile_id) AS can_write
   FROM crm.tenant_memberships tm
     JOIN crm.profiles p ON p.id = tm.profile_id
  WHERE tm.status = 'active'::text;
revoke all on public.v_crm_cards_v1, public.v_crm_contacts_v1, public.v_crm_owners_v1 from public;
grant select on public.v_crm_cards_v1, public.v_crm_contacts_v1, public.v_crm_owners_v1 to anon, authenticated, service_role;
CREATE OR REPLACE FUNCTION public.crm_set_owner(p_opportunity_id uuid, p_owner_profile_id uuid)
 RETURNS SETOF v_crm_cards_v1
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.crm_board_counts(p_client_id uuid, p_opened_from date DEFAULT NULL::date, p_opened_to date DEFAULT NULL::date, p_owner_profile_id uuid DEFAULT NULL::uuid, p_unassigned boolean DEFAULT false)
 RETURNS TABLE(client_id uuid, stage_code text, stage_label text, stage_position smallint, is_terminal boolean, opportunities bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select t.id, s.code, s.label, s.position, s.is_terminal, count(o.id)
    from crm.tenants t
   cross join crm.global_pipeline_stages s
    join crm.global_pipeline_versions v
      on v.id = s.pipeline_version_id and v.status = 'active'
    left join crm.opportunities o
      on o.tenant_id = t.id
     and o.current_stage_id = s.id
     and (p_opened_from is null or o.opened_at >= p_opened_from::timestamptz)
     and (p_opened_to   is null or o.opened_at <  (p_opened_to + 1)::timestamptz)
     and (case
            when p_unassigned then o.owner_profile_id is null
            when p_owner_profile_id is not null then o.owner_profile_id = p_owner_profile_id
            else true
          end)
   where t.id = p_client_id
   group by t.id, s.code, s.label, s.position, s.is_terminal
$function$;

CREATE OR REPLACE FUNCTION public.crm_move_stage(p_opportunity_id uuid, p_to_stage_code text, p_expected_stage_version integer, p_reason text DEFAULT NULL::text)
 RETURNS SETOF v_crm_cards_v1
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.crm_register_won(p_opportunity_id uuid, p_evidence text, p_expected_stage_version integer, p_value numeric DEFAULT NULL::numeric, p_currency text DEFAULT 'BRL'::text)
 RETURNS SETOF v_crm_cards_v1
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if pg_catalog.length(pg_catalog.btrim(coalesce(p_evidence, ''))) = 0 then
    raise exception 'CRM_EVIDENCE_REQUIRED: observacao obrigatoria no ganho';
  end if;

  -- Valor ausente permanece pendente, nunca zero.
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
$function$;

CREATE OR REPLACE FUNCTION public.crm_register_lost(p_opportunity_id uuid, p_loss_reason_code text, p_expected_stage_version integer, p_note text DEFAULT NULL::text)
 RETURNS SETOF v_crm_cards_v1
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  -- origin='manual' exige evidence nao-vazio tambem aqui.
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

  -- Perda obriga value_status='pending'. Nao existe perdido com valor.
  insert into crm.commercial_outcomes
    (tenant_id, opportunity_id, outcome, origin, actor_profile_id,
     loss_reason_id, evidence, value, value_status, currency, is_current, occurred_at)
  values
    (v_tenant, p_opportunity_id, 'lost', 'manual', auth.uid(),
     v_reason_id, v_evidence, null, 'pending', null, true, pg_catalog.now());

  return query select * from public.v_crm_cards_v1 c
                where c.opportunity_id = p_opportunity_id;
end;
$function$;

revoke all on function public.crm_set_owner(uuid, uuid) from public, anon;
revoke all on function public.crm_board_counts(uuid, date, date, uuid, boolean) from public, anon;
revoke all on function public.crm_move_stage(uuid, text, integer, text) from public, anon;
revoke all on function public.crm_register_won(uuid, text, integer, numeric, text) from public, anon;
revoke all on function public.crm_register_lost(uuid, text, integer, text) from public, anon;
grant execute on function public.crm_set_owner(uuid, uuid) to authenticated, service_role;
grant execute on function public.crm_board_counts(uuid, date, date, uuid, boolean) to authenticated, service_role;
grant execute on function public.crm_move_stage(uuid, text, integer, text) to authenticated, service_role;
grant execute on function public.crm_register_won(uuid, text, integer, numeric, text) to authenticated, service_role;
grant execute on function public.crm_register_lost(uuid, text, integer, text) to authenticated, service_role;

do $gate$
declare
  v_sig text;
  v_view text;
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'crm' and table_name = 'opportunities'
       and column_name = 'owner_profile_id'
  ) then
    raise exception 'IMP214_ROLLBACK_GATE: owner_profile_id ausente';
  end if;
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'crm' and table_name = 'opportunities'
       and column_name in ('crc_owner_profile_id', 'sales_owner_profile_id')
  ) then
    raise exception 'IMP214_ROLLBACK_GATE: colunas de dois donos ainda existem';
  end if;
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'crm' and table_name = 'tenant_memberships'
       and column_name = 'is_assignable'
  ) then
    raise exception 'IMP214_ROLLBACK_GATE: is_assignable ainda existe';
  end if;
  foreach v_sig in array array[
    'public.crm_set_owner(uuid,uuid)',
    'public.crm_board_counts(uuid,date,date,uuid,boolean)',
    'public.crm_move_stage(uuid,text,integer,text)',
    'public.crm_register_won(uuid,text,integer,numeric,text)',
    'public.crm_register_lost(uuid,text,integer,text)'
  ] loop
    if to_regprocedure(v_sig) is null then
      raise exception 'IMP214_ROLLBACK_GATE: função antiga ausente: %', v_sig;
    end if;
    if has_function_privilege('anon', v_sig, 'execute') then
      raise exception 'IMP214_ROLLBACK_GATE: anon tem execute: %', v_sig;
    end if;
    if not has_function_privilege('authenticated', v_sig, 'execute') then
      raise exception 'IMP214_ROLLBACK_GATE: authenticated sem execute: %', v_sig;
    end if;
  end loop;
  foreach v_view in array array[
    'public.v_crm_cards_v1',
    'public.v_crm_contacts_v1',
    'public.v_crm_owners_v1'
  ] loop
    if to_regclass(v_view) is null then
      raise exception 'IMP214_ROLLBACK_GATE: view antiga ausente: %', v_view;
    end if;
    if not has_table_privilege('anon', v_view, 'select') then
      raise exception 'IMP214_ROLLBACK_GATE: anon sem select: %', v_view;
    end if;
  end loop;
end;
$gate$;
