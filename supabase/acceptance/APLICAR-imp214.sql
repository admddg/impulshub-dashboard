-- IMP-214. Aplicar somente após revisão. Não executar em produção sem autorização.
begin;
set local lock_timeout = '5s';
-- IMP-214: dois donos por card e filtro de origem.
-- Definições de views/funções de produção capturadas por SELECT antes da alteração.
-- A migração é executada transacionalmente pelo Supabase.
set local lock_timeout = '5s';
revoke insert, update, delete on crm.tenant_memberships from anon, authenticated;

-- A coluna nova separa autorização de escrita de elegibilidade para ser dono.
alter table crm.tenant_memberships add column is_assignable boolean not null default false;
update crm.tenant_memberships tm
   set is_assignable = true
 where tm.role = 'attendant'
    or (tm.tenant_id = '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid
        and exists (
          select 1 from crm.opportunities o
           where o.tenant_id = tm.tenant_id and o.owner_profile_id = tm.profile_id
        ));

alter table crm.opportunities add column crc_owner_profile_id uuid;
alter table crm.opportunities add column sales_owner_profile_id uuid;
update crm.opportunities set crc_owner_profile_id = owner_profile_id where owner_profile_id is not null;
set constraints all immediate;

drop function public.crm_set_owner(uuid, uuid);
drop function public.crm_board_counts(uuid, date, date, uuid, boolean);
drop function public.crm_move_stage(uuid, text, integer, text);
drop function public.crm_register_won(uuid, text, integer, numeric, text);
drop function public.crm_register_lost(uuid, text, integer, text);

drop view public.v_crm_cards_v1;
drop view public.v_crm_contacts_v1;
drop view public.v_crm_owners_v1;

alter table crm.opportunities drop column owner_profile_id;
alter table crm.opportunities add constraint opportunities_tenant_crc_owner_profile_id_fkey
  foreign key (tenant_id, crc_owner_profile_id)
  references crm.tenant_memberships(tenant_id, profile_id) on delete restrict;
alter table crm.opportunities add constraint opportunities_tenant_sales_owner_profile_id_fkey
  foreign key (tenant_id, sales_owner_profile_id)
  references crm.tenant_memberships(tenant_id, profile_id) on delete restrict;

create or replace function crm.validate_opportunity_owners()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.crc_owner_profile_id is not null and not exists (
    select 1 from crm.tenant_memberships tm
     where tm.tenant_id = new.tenant_id and tm.profile_id = new.crc_owner_profile_id
       and tm.status = 'active' and tm.is_assignable
  ) then
    raise exception 'opportunity crc owner must be an active assignable member of the tenant';
  end if;
  if new.sales_owner_profile_id is not null and not exists (
    select 1 from crm.tenant_memberships tm
     where tm.tenant_id = new.tenant_id and tm.profile_id = new.sales_owner_profile_id
       and tm.status = 'active' and tm.is_assignable
  ) then
    raise exception 'opportunity sales owner must be an active assignable member of the tenant';
  end if;
  return new;
end;
$function$;
revoke all on function crm.validate_opportunity_owners() from public, anon, authenticated, service_role;
drop trigger if exists opportunities_validate_owners on crm.opportunities;
create trigger opportunities_validate_owners
before insert or update of tenant_id, crc_owner_profile_id, sales_owner_profile_id on crm.opportunities
for each row execute function crm.validate_opportunity_owners();

create view public.v_crm_cards_v1
with (security_invoker = true) as
select o.tenant_id as client_id,
       o.id as opportunity_id,
       o.contact_id,
       c.full_name as contact_name,
       c.phone_normalized,
       case when c.phone_normalized is not null then 'https://wa.me/' || c.phone_normalized end as whatsapp_url,
       o.title,
       s.code as stage_code,
       s.label as stage_label,
       s.position as stage_position,
       s.is_terminal,
       o.status,
       o.stage_version,
       o.crc_owner_profile_id,
       crc.display_name as crc_owner_name,
       o.sales_owner_profile_id,
       sales.display_name as sales_owner_name,
       o.opened_at,
       o.closed_at,
       (select max(a.created_at) from crm.activities a
         where a.tenant_id = o.tenant_id and a.contact_id = o.contact_id) as last_activity_at,
       case when o.conversion_source is not null or o.ctwa_clid is not null or o.meta_ad_id is not null
            then 'anuncio' else 'organico' end as origem,
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
  join crm.contacts c on c.tenant_id = o.tenant_id and c.id = o.contact_id
  join crm.global_pipeline_stages s on s.id = o.current_stage_id
  left join crm.profiles crc on crc.id = o.crc_owner_profile_id
  left join crm.profiles sales on sales.id = o.sales_owner_profile_id
  left join lateral (
       select m.ad_name, m.adset_name, m.campaign_name, m.creative_name, m.thumbnail_url
         from public.v_meta_ads_v2 m
        where m.client_id = o.tenant_id and m.ad_id = o.meta_ad_id
        order by m.date desc limit 1
  ) ad on o.meta_ad_id is not null;

create view public.v_crm_contacts_v1
with (security_invoker = true) as
select c.tenant_id as client_id,
       c.id as contact_id,
       c.full_name,
       c.phone_normalized,
       c.email,
       case when c.phone_normalized is not null then 'https://wa.me/' || c.phone_normalized end as whatsapp_url,
       c.status,
       act.last_activity_at,
       coalesce(act.messages_total, 0) as messages_total,
       o.id as opportunity_id,
       s.code as stage_code,
       s.label as stage_label,
       s.position as stage_position,
       o.status as opportunity_status,
       o.opened_at,
       o.crc_owner_profile_id,
       crc.display_name as crc_owner_name,
       o.sales_owner_profile_id,
       sales.display_name as sales_owner_name,
       case when o.conversion_source is not null or o.ctwa_clid is not null or o.meta_ad_id is not null
            then 'anuncio' else 'organico' end as origem,
       pg_catalog.lower(c.full_name) || ' ' || coalesce(c.phone_normalized, '') as search_text
  from crm.contacts c
  left join lateral (
       select max(a.created_at) as last_activity_at, count(*) as messages_total
         from crm.activities a
        where a.tenant_id = c.tenant_id and a.contact_id = c.id
  ) act on true
  left join lateral (
       select o2.id, o2.status, o2.current_stage_id, o2.opened_at,
              o2.crc_owner_profile_id, o2.sales_owner_profile_id,
              o2.conversion_source, o2.ctwa_clid, o2.meta_ad_id
         from crm.opportunities o2
        where o2.tenant_id = c.tenant_id and o2.contact_id = c.id
        order by o2.opened_at desc, o2.created_at desc limit 1
  ) o on true
  left join crm.global_pipeline_stages s on s.id = o.current_stage_id
  left join crm.profiles crc on crc.id = o.crc_owner_profile_id
  left join crm.profiles sales on sales.id = o.sales_owner_profile_id;

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
 where tm.status = 'active' and tm.is_assignable;

revoke all on public.v_crm_cards_v1, public.v_crm_contacts_v1, public.v_crm_owners_v1 from public, anon;
grant select on public.v_crm_cards_v1, public.v_crm_contacts_v1, public.v_crm_owners_v1 to authenticated, service_role;
create or replace function public.crm_set_owner(
  p_opportunity_id uuid,
  p_role text,
  p_owner_profile_id uuid
)
returns setof public.v_crm_cards_v1
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_tenant uuid;
begin
  v_tenant := public.crm_guard(p_opportunity_id);

  if p_role not in ('crc', 'sales') then
    raise exception 'CRM_INVALID_OWNER_ROLE: papel de dono deve ser crc ou sales';
  end if;

  if p_owner_profile_id is not null and not exists (
    select 1
      from crm.tenant_memberships tm
     where tm.tenant_id = v_tenant
       and tm.profile_id = p_owner_profile_id
       and tm.status = 'active'
       and tm.is_assignable
  ) then
    raise exception 'CRM_INVALID_OWNER: pessoa nao pode ser dona deste card';
  end if;

  if p_role = 'crc' then
    update crm.opportunities o
       set crc_owner_profile_id = p_owner_profile_id,
           updated_at = pg_catalog.now()
     where o.id = p_opportunity_id;
  else
    update crm.opportunities o
       set sales_owner_profile_id = p_owner_profile_id,
           updated_at = pg_catalog.now()
     where o.id = p_opportunity_id;
  end if;

  return query select * from public.v_crm_cards_v1 c
                where c.opportunity_id = p_opportunity_id;
end;
$function$;

create or replace function public.crm_board_counts(
  p_client_id        uuid,
  p_opened_from      date default null,
  p_opened_to        date default null,
  p_owner_role       text default null,
  p_owner_profile_id uuid default null,
  p_unassigned       boolean default false,
  p_origin           text default null
)
returns table (
  client_id      uuid,
  stage_code     text,
  stage_label    text,
  stage_position smallint,
  is_terminal    boolean,
  opportunities  bigint
)
language sql
stable
security invoker
set search_path = ''
as $function$
  select t.id, s.code, s.label, s.position, s.is_terminal, count(o.id)
    from crm.tenants t
   cross join crm.global_pipeline_stages s
    join crm.global_pipeline_versions v
      on v.id = s.pipeline_version_id and v.status = 'active'
    left join crm.opportunities o
      on o.tenant_id = t.id
     and o.current_stage_id = s.id
     and (p_opened_from is null or o.opened_at >= p_opened_from::timestamptz)
     and (p_opened_to is null or o.opened_at < (p_opened_to + 1)::timestamptz)
     and (
       (p_unassigned and case p_owner_role
          when 'crc' then o.crc_owner_profile_id is null
          when 'sales' then o.sales_owner_profile_id is null
          else o.crc_owner_profile_id is null and o.sales_owner_profile_id is null
        end)
       or (not p_unassigned and p_owner_profile_id is null)
       or (not p_unassigned and p_owner_profile_id is not null and case p_owner_role
          when 'crc' then o.crc_owner_profile_id = p_owner_profile_id
          when 'sales' then o.sales_owner_profile_id = p_owner_profile_id
          else false
        end)
     )
     and (p_origin is null or p_origin = case
       when o.conversion_source is not null or o.ctwa_clid is not null or o.meta_ad_id is not null
         then 'anuncio' else 'organico' end)
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

revoke all on function public.crm_set_owner(uuid, text, uuid) from public, anon;
revoke all on function public.crm_board_counts(uuid, date, date, text, uuid, boolean, text) from public, anon;
revoke all on function public.crm_move_stage(uuid, text, integer, text) from public, anon;
revoke all on function public.crm_register_won(uuid, text, integer, numeric, text) from public, anon;
revoke all on function public.crm_register_lost(uuid, text, integer, text) from public, anon;
grant execute on function public.crm_set_owner(uuid, text, uuid) to authenticated, service_role;
grant execute on function public.crm_board_counts(uuid, date, date, text, uuid, boolean, text) to authenticated, service_role;
grant execute on function public.crm_move_stage(uuid, text, integer, text) to authenticated, service_role;
grant execute on function public.crm_register_won(uuid, text, integer, numeric, text) to authenticated, service_role;
grant execute on function public.crm_register_lost(uuid, text, integer, text) to authenticated, service_role;
comment on column crm.tenant_memberships.is_assignable is 'Membro operacional elegivel para ser dono CRC ou Vendas; separado de can_write.';

do $gate$
declare
  v_sig text;
  v_view text;
begin
  if not exists (select 1 from information_schema.columns where table_schema='crm' and table_name='tenant_memberships' and column_name='is_assignable')
     or (select count(*) from information_schema.columns where table_schema='crm' and table_name='opportunities' and column_name in ('crc_owner_profile_id','sales_owner_profile_id')) <> 2
     or exists (select 1 from information_schema.columns where table_schema='crm' and table_name='opportunities' and column_name='owner_profile_id')
     or not exists (select 1 from pg_constraint where conname='opportunities_tenant_crc_owner_profile_id_fkey')
     or not exists (select 1 from pg_constraint where conname='opportunities_tenant_sales_owner_profile_id_fkey') then
    raise exception 'IMP214_GATE_STRUCTURE';
  end if;
  foreach v_sig in array array[
    'public.crm_set_owner(uuid,text,uuid)',
    'public.crm_board_counts(uuid,date,date,text,uuid,boolean,text)',
    'public.crm_move_stage(uuid,text,integer,text)',
    'public.crm_register_won(uuid,text,integer,numeric,text)',
    'public.crm_register_lost(uuid,text,integer,text)'] loop
    if to_regprocedure(v_sig) is null then raise exception 'IMP214_GATE_SIGNATURE: %', v_sig; end if;
    if has_function_privilege('anon', v_sig, 'execute') or not has_function_privilege('authenticated', v_sig, 'execute') then
      raise exception 'IMP214_GATE_FUNCTION_ACL: %', v_sig;
    end if;
  end loop;
  foreach v_view in array array['public.v_crm_cards_v1','public.v_crm_contacts_v1','public.v_crm_owners_v1'] loop
    if not exists (select 1 from pg_class c where c.oid=v_view::regclass and 'security_invoker=true' = any(coalesce(c.reloptions, array[]::text[])))
       or has_table_privilege('anon', v_view, 'select') then
      raise exception 'IMP214_GATE_VIEW_ACL: %', v_view;
    end if;
  end loop;
end;
$gate$;


insert into supabase_migrations.schema_migrations(version, name)
values ('20260929000001', '20260929000001_imp214_two_owners')
on conflict (version) do update set name = excluded.name;
commit;
