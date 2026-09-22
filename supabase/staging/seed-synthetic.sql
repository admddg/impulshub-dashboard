begin;
set constraints all deferred;

-- Fixture 100% sintética. IDs de clientes e usuários são os UUIDs canônicos
-- usados pelos aceites; nenhum dado real é copiado.
-- auth.users foi conferida no staging antes deste INSERT:
-- confirmed_at é GENERATED ALWAYS e fica omitida. auth.identities.email também.
insert into auth.users
  (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
   raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('d036c4d6-0969-4175-b917-ff7e4dd3b376', null, 'authenticated', 'authenticated', 'agency.synthetic@staging.invalid', 'synthetic-not-a-real-hash', timestamp '2026-01-01', '{"provider":"email","providers":["email"]}', '{"display_name":"Agency Synthetic"}', timestamp '2026-01-01', timestamp '2026-01-01'),
  ('4848733f-a369-4c8c-87cd-e62bbaa7b8f5', null, 'authenticated', 'authenticated', 'igor.synthetic@staging.invalid', 'synthetic-not-a-real-hash', timestamp '2026-01-01', '{"provider":"email","providers":["email"]}', '{"display_name":"Igor Synthetic"}', timestamp '2026-01-01', timestamp '2026-01-01'),
  ('bb04435c-fabb-4ba8-b5b5-e0175d9ca17d', null, 'authenticated', 'authenticated', 'atendente.central@staging.invalid', 'synthetic-not-a-real-hash', timestamp '2026-01-01', '{"provider":"email","providers":["email"]}', '{"display_name":"Atendente Central Synthetic"}', timestamp '2026-01-01', timestamp '2026-01-01'),
  ('7c3296f4-13c7-42d1-89eb-72aecec905ba', null, 'authenticated', 'authenticated', 'gestor.royal@staging.invalid', 'synthetic-not-a-real-hash', timestamp '2026-01-01', '{"provider":"email","providers":["email"]}', '{"display_name":"Gestor Royal Synthetic"}', timestamp '2026-01-01', timestamp '2026-01-01'),
  ('aa04435c-fabb-4ba8-b5b5-e0175d9ca17d', null, 'authenticated', 'authenticated', 'atendente.royal@staging.invalid', 'synthetic-not-a-real-hash', timestamp '2026-01-01', '{"provider":"email","providers":["email"]}', '{"display_name":"Atendente Royal Synthetic"}', timestamp '2026-01-01', timestamp '2026-01-01')
on conflict (id) do update set email = excluded.email, raw_user_meta_data = excluded.raw_user_meta_data, updated_at = excluded.updated_at;

insert into auth.identities
  (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values
  ('d036c4d6-0969-4175-b917-ff7e4dd3b001', 'd036c4d6-0969-4175-b917-ff7e4dd3b376', 'd036c4d6-0969-4175-b917-ff7e4dd3b376', jsonb_build_object('sub', 'd036c4d6-0969-4175-b917-ff7e4dd3b376', 'email', 'agency.synthetic@staging.invalid'), 'email', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01')
on conflict (id) do nothing;
insert into auth.identities
  (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values
  ('4848733f-a369-4c8c-87cd-e62bbaa7b001', '4848733f-a369-4c8c-87cd-e62bbaa7b8f5', '4848733f-a369-4c8c-87cd-e62bbaa7b8f5', jsonb_build_object('sub', '4848733f-a369-4c8c-87cd-e62bbaa7b8f5', 'email', 'igor.synthetic@staging.invalid'), 'email', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01')
on conflict (id) do nothing;
insert into auth.identities
  (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values
  ('bb04435c-fabb-4ba8-b5b5-e0175d9ca001', 'bb04435c-fabb-4ba8-b5b5-e0175d9ca17d', 'bb04435c-fabb-4ba8-b5b5-e0175d9ca17d', jsonb_build_object('sub', 'bb04435c-fabb-4ba8-b5b5-e0175d9ca17d', 'email', 'atendente.central@staging.invalid'), 'email', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01')
on conflict (id) do nothing;
insert into auth.identities
  (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values
  ('7c3296f4-13c7-42d1-89eb-72aecec90501', '7c3296f4-13c7-42d1-89eb-72aecec905ba', '7c3296f4-13c7-42d1-89eb-72aecec905ba', jsonb_build_object('sub', '7c3296f4-13c7-42d1-89eb-72aecec905ba', 'email', 'gestor.royal@staging.invalid'), 'email', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01')
on conflict (id) do nothing;
insert into auth.identities
  (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values
  ('aa04435c-fabb-4ba8-b5b5-e0175d9ca001', 'aa04435c-fabb-4ba8-b5b5-e0175d9ca17d', 'aa04435c-fabb-4ba8-b5b5-e0175d9ca17d', jsonb_build_object('sub', 'aa04435c-fabb-4ba8-b5b5-e0175d9ca17d', 'email', 'atendente.royal@staging.invalid'), 'email', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01')
on conflict (id) do nothing;

insert into crm.profiles (id, display_name, created_at) values
  ('d036c4d6-0969-4175-b917-ff7e4dd3b376', 'Agency Synthetic', timestamp '2026-01-01'),
  ('4848733f-a369-4c8c-87cd-e62bbaa7b8f5', 'Igor Synthetic', timestamp '2026-01-01'),
  ('bb04435c-fabb-4ba8-b5b5-e0175d9ca17d', 'Atendente Central Synthetic', timestamp '2026-01-01'),
  ('7c3296f4-13c7-42d1-89eb-72aecec905ba', 'Gestor Royal Synthetic', timestamp '2026-01-01'),
  ('aa04435c-fabb-4ba8-b5b5-e0175d9ca17d', 'Atendente Royal Synthetic', timestamp '2026-01-01')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.clients_base
  (id, ghl_location_id, ghl_location_name, client_name, status, timezone,
   enable_meta_tracking, enable_google_tracking, enable_ga4_tracking,
    meta_ad_accounts, google_ads_accounts, client_slug, crm_emits_conversions,
    crm_feeds_dashboard)
   values
   ('fa6fc071-7529-4317-93cb-9b0bfea3bca3', 'synthetic-ghl-royal', 'Synthetic Royal Location', 'Royal', 'active', 'America/Sao_Paulo', false, false, false, '[]', '[]', 'royal', false, false),
   ('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b', 'synthetic-ghl-central', 'Synthetic Central Location', 'Central', 'active', 'America/Sao_Paulo', false, false, false, '[]', '[]', 'central', false, false),
   ('3bc0e6a4-6438-420d-b603-ec91bf296f4e', 'synthetic-ghl-quickclean', 'Synthetic QuickClean Location', 'QuickClean', 'active', 'America/Sao_Paulo', false, false, false, '[]', '[]', 'quickclean', false, false),
   ('3ec294db-a64a-4420-9b4a-0d917f65d399', 'synthetic-ghl-impulshub', 'Synthetic ImpulsHub Location', 'ImpulsHub', 'active', 'America/Sao_Paulo', false, false, false, '[]', '[]', 'impulshub', false, true)
on conflict (id) do update set
  ghl_location_id = excluded.ghl_location_id,
  client_name = excluded.client_name,
  client_slug = excluded.client_slug,
  crm_emits_conversions = excluded.crm_emits_conversions,
  crm_feeds_dashboard = excluded.crm_feeds_dashboard,
  updated_at = excluded.updated_at;

-- Remove apenas eventos sintéticos CRM que uma execução anterior do seed
-- criou nos tenants que continuam no GHL; não toca nos eventos GHL.
delete from public.conversion_outbox co
 where co.normalized_event_id in (
   select en.id from public.events_normalized en
    where en.source_system = 'impuls_crm'
      and en.client_id in (
        'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid,
        '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid,
        '3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid));
delete from public.events_normalized
 where source_system = 'impuls_crm'
   and client_id in (
     'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid,
     '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid,
     '3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid);
delete from public.events_raw
 where source_system = 'impuls_crm'
   and payload->>'tenant_id' in (
     'fa6fc071-7529-4317-93cb-9b0bfea3bca3',
     '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b',
     '3bc0e6a4-6438-420d-b603-ec91bf296f4e');

insert into crm.tenants (id, slug, name, status, created_at) values
  ('fa6fc071-7529-4317-93cb-9b0bfea3bca3', 'royal', 'Royal', 'active', timestamp '2026-01-01'),
  ('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b', 'central', 'Central', 'active', timestamp '2026-01-01'),
  ('3bc0e6a4-6438-420d-b603-ec91bf296f4e', 'quickclean', 'QuickClean', 'active', timestamp '2026-01-01'),
  ('3ec294db-a64a-4420-9b4a-0d917f65d399', 'impulshub', 'ImpulsHub', 'active', timestamp '2026-01-01')
on conflict (id) do update set slug = excluded.slug, name = excluded.name, status = excluded.status;

-- Agência e Igor são membros administrativos nos quatro tenants; os dois
-- usuários de cliente ficam restritos ao tenant/papel indicado.
insert into public.client_users (client_id, user_id, role, is_active, created_at, updated_at)
select v.client_id, v.user_id, v.role, true, timestamp '2026-01-01', timestamp '2026-01-01'
from (values
  ('fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid, 'd036c4d6-0969-4175-b917-ff7e4dd3b376'::uuid, 'agency'),
  ('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid, 'd036c4d6-0969-4175-b917-ff7e4dd3b376'::uuid, 'agency'),
  ('3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid, 'd036c4d6-0969-4175-b917-ff7e4dd3b376'::uuid, 'agency'),
  ('3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid, 'd036c4d6-0969-4175-b917-ff7e4dd3b376'::uuid, 'agency'),
  ('fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid, '4848733f-a369-4c8c-87cd-e62bbaa7b8f5'::uuid, 'agency'),
  ('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid, '4848733f-a369-4c8c-87cd-e62bbaa7b8f5'::uuid, 'agency'),
  ('3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid, '4848733f-a369-4c8c-87cd-e62bbaa7b8f5'::uuid, 'agency'),
  ('3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid, '4848733f-a369-4c8c-87cd-e62bbaa7b8f5'::uuid, 'agency'),
  ('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid, 'bb04435c-fabb-4ba8-b5b5-e0175d9ca17d'::uuid, 'attendant'),
  ('fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid, '7c3296f4-13c7-42d1-89eb-72aecec905ba'::uuid, 'viewer'),
  ('fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid, 'aa04435c-fabb-4ba8-b5b5-e0175d9ca17d'::uuid, 'attendant')
) v(client_id, user_id, role)
on conflict (client_id, user_id) do update set role = excluded.role, is_active = true, updated_at = excluded.updated_at;

insert into crm.tenant_memberships (tenant_id, profile_id, role, status, created_at, is_assignable)
select v.tenant_id, v.profile_id, v.role, 'active', timestamp '2026-01-01', v.is_assignable
from (values
  ('fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid, 'd036c4d6-0969-4175-b917-ff7e4dd3b376'::uuid, 'admin', false),
  ('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid, 'd036c4d6-0969-4175-b917-ff7e4dd3b376'::uuid, 'admin', false),
  ('3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid, 'd036c4d6-0969-4175-b917-ff7e4dd3b376'::uuid, 'admin', false),
  ('3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid, 'd036c4d6-0969-4175-b917-ff7e4dd3b376'::uuid, 'admin', false),
  ('fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid, '4848733f-a369-4c8c-87cd-e62bbaa7b8f5'::uuid, 'admin', false),
  ('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid, '4848733f-a369-4c8c-87cd-e62bbaa7b8f5'::uuid, 'admin', false),
  ('3bc0e6a4-6438-420d-b603-ec91bf296f4e'::uuid, '4848733f-a369-4c8c-87cd-e62bbaa7b8f5'::uuid, 'admin', false),
  ('3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid, '4848733f-a369-4c8c-87cd-e62bbaa7b8f5'::uuid, 'admin', false),
  ('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid, 'bb04435c-fabb-4ba8-b5b5-e0175d9ca17d'::uuid, 'attendant', true),
  ('fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid, '7c3296f4-13c7-42d1-89eb-72aecec905ba'::uuid, 'viewer', false),
  ('fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid, 'aa04435c-fabb-4ba8-b5b5-e0175d9ca17d'::uuid, 'attendant', true)
) v(tenant_id, profile_id, role, is_assignable)
on conflict (tenant_id, profile_id) do update set role = excluded.role, status = 'active', is_assignable = excluded.is_assignable;

-- Catálogo global copiado por SELECT da produção; não é dado de cliente.
insert into crm.global_pipeline_versions (id, version_no, status, published_at, created_at)
values ('00000000-0000-0000-0000-000000000101', 1, 'active', timestamp '2026-09-22', timestamp '2026-09-22')
on conflict (id) do nothing;
insert into crm.global_pipeline_stages (id, pipeline_version_id, code, label, position, is_terminal, created_at)
values
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000101', 'lead', 'Lead', 1, false, timestamp '2026-09-22'),
  ('00000000-0000-0000-0000-000000000202', '00000000-0000-0000-0000-000000000101', 'atendimento', 'Atendimento', 2, false, timestamp '2026-09-22'),
  ('00000000-0000-0000-0000-000000000203', '00000000-0000-0000-0000-000000000101', 'agendado', 'Agendado', 3, false, timestamp '2026-09-22'),
  ('00000000-0000-0000-0000-000000000204', '00000000-0000-0000-0000-000000000101', 'compareceu', 'Compareceu', 4, false, timestamp '2026-09-22'),
  ('00000000-0000-0000-0000-000000000205', '00000000-0000-0000-0000-000000000101', 'ganho', 'Ganho', 5, true, timestamp '2026-09-22'),
  ('00000000-0000-0000-0000-000000000206', '00000000-0000-0000-0000-000000000101', 'perdido', 'Perdido', 6, true, timestamp '2026-09-22')
on conflict (id) do nothing;

insert into crm.event_map
  (event_code, stage_code, version, event_name, funnel_step, is_active, created_at)
values
  ('lead', 'lead', 1, 'Lead', 1, true, timestamp '2026-09-22'),
  ('primeira_conversa', 'atendimento', 1, 'Primeira conversa', 2, true, timestamp '2026-09-22'),
  ('agendado', 'agendado', 1, 'Agendado', 3, true, timestamp '2026-09-22'),
  ('compareceu', 'compareceu', 1, 'Compareceu', 4, true, timestamp '2026-09-22'),
  ('ganho', 'ganho', 1, 'Ganho', 5, true, timestamp '2026-09-22'),
  ('perdido', 'perdido', 1, 'Perdido', 6, true, timestamp '2026-09-22')
on conflict (event_code) do update set
  stage_code = excluded.stage_code,
  version = excluded.version,
  event_name = excluded.event_name,
  funnel_step = excluded.funnel_step,
  is_active = excluded.is_active,
  created_at = excluded.created_at;

insert into crm.contacts (id, tenant_id, full_name, email, phone_normalized, default_owner_profile_id, status, created_at, updated_at)
values
  ('20000000-0000-4000-8000-000000000001', 'fa6fc071-7529-4317-93cb-9b0bfea3bca3', 'Royal Synthetic Contact', 'royal.contact@staging.invalid', '5511999000001', 'd036c4d6-0969-4175-b917-ff7e4dd3b376', 'active', timestamp '2026-01-01', timestamp '2026-01-01'),
  ('20000000-0000-4000-8000-000000000002', '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b', 'Central Synthetic Contact', 'central.contact@staging.invalid', '5511999000002', 'bb04435c-fabb-4ba8-b5b5-e0175d9ca17d', 'active', timestamp '2026-01-01', timestamp '2026-01-01'),
  ('20000000-0000-4000-8000-000000000003', '3bc0e6a4-6438-420d-b603-ec91bf296f4e', 'QuickClean Synthetic Contact', 'quickclean.contact@staging.invalid', '5511999000003', 'd036c4d6-0969-4175-b917-ff7e4dd3b376', 'active', timestamp '2026-01-01', timestamp '2026-01-01'),
  ('20000000-0000-4000-8000-000000000004', '3ec294db-a64a-4420-9b4a-0d917f65d399', 'ImpulsHub Synthetic Contact', 'impulshub.contact@staging.invalid', '5511999000004', 'd036c4d6-0969-4175-b917-ff7e4dd3b376', 'active', timestamp '2026-01-01', timestamp '2026-01-01')
on conflict (id) do nothing;

-- Dois cards abertos por tenant, em etapas consecutivas e não terminais.
insert into crm.opportunities
  (id, tenant_id, contact_id, pipeline_version_id, current_stage_id, stage_version,
   title, status, opened_at, created_at, updated_at, conversion_source,
   crc_owner_profile_id, sales_owner_profile_id)
values
  ('30000000-0000-4000-8000-000000000001', 'fa6fc071-7529-4317-93cb-9b0bfea3bca3', '20000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000201', 0, 'Royal Card Lead', 'open', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01', 'organic', null, null),
  ('30000000-0000-4000-8000-000000000002', 'fa6fc071-7529-4317-93cb-9b0bfea3bca3', '20000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000202', 1, 'Royal Card Atendimento', 'open', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01', 'google_ads', null, null),
  ('30000000-0000-4000-8000-000000000003', '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b', '20000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000201', 0, 'Central Card Lead', 'open', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01', 'organic', null, null),
  ('30000000-0000-4000-8000-000000000004', '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b', '20000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000202', 1, 'Central Card Atendimento', 'open', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01', 'google_ads', null, null),
  ('30000000-0000-4000-8000-000000000005', '3bc0e6a4-6438-420d-b603-ec91bf296f4e', '20000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000201', 0, 'QuickClean Card Lead', 'open', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01', 'organic', null, null),
  ('30000000-0000-4000-8000-000000000006', '3bc0e6a4-6438-420d-b603-ec91bf296f4e', '20000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000202', 1, 'QuickClean Card Atendimento', 'open', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01', 'google_ads', null, null),
  ('30000000-0000-4000-8000-000000000007', '3ec294db-a64a-4420-9b4a-0d917f65d399', '20000000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000201', 0, 'ImpulsHub Card Lead', 'open', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01', 'organic', null, null),
  ('30000000-0000-4000-8000-000000000008', '3ec294db-a64a-4420-9b4a-0d917f65d399', '20000000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000202', 1, 'ImpulsHub Card Atendimento', 'open', timestamp '2026-01-01', timestamp '2026-01-01', timestamp '2026-01-01', 'google_ads', null, null)
on conflict (id) do nothing;

insert into crm.opportunity_stage_history
  (id, tenant_id, opportunity_id, from_stage_id, to_stage_id, transition_type, origin, actor_profile_id, reason, occurred_at, created_at)
select ('40000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, o.tenant_id, o.id, null,
       o.current_stage_id, 'automatic', 'sistema', null, 'synthetic seed', timestamp '2026-01-01', timestamp '2026-01-01'
from crm.opportunities o
cross join lateral (select (right(o.id::text, 8))::bigint as n) x
where o.id::text like '30000000-0000-4000-8000-%'
on conflict (id) do nothing;

-- Um card Royal terminaliza a fixture para o aceite financeiro IMP-213;
-- o segundo continua aberto para o aceite de emissão IMP-216.
update crm.opportunities
   set current_stage_id = '00000000-0000-0000-0000-000000000205',
       stage_version = stage_version + 1,
       status = 'won',
       closed_at = timestamp '2026-01-01',
       updated_at = timestamp '2026-01-01'
 where id = '30000000-0000-4000-8000-000000000001'
   and tenant_id = 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'
   and status = 'open'
   and current_stage_id = '00000000-0000-0000-0000-000000000201';
insert into crm.opportunity_stage_history
  (id, tenant_id, opportunity_id, from_stage_id, to_stage_id, transition_type, origin, actor_profile_id, reason, occurred_at, created_at)
values
  ('40000000-0000-4000-8000-000000000009', 'fa6fc071-7529-4317-93cb-9b0bfea3bca3', '30000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000205', 'automatic', 'sistema', null, 'synthetic won outcome', timestamp '2026-01-01', timestamp '2026-01-01')
on conflict (id) do nothing;
insert into crm.commercial_outcomes
  (id, tenant_id, opportunity_id, outcome, origin, evidence, value, value_status, currency, is_current, occurred_at, created_at)
values
  ('80000000-0000-4000-8000-000000000001', 'fa6fc071-7529-4317-93cb-9b0bfea3bca3', '30000000-0000-4000-8000-000000000001', 'won', 'sistema', 'synthetic won outcome', 1250.00, 'valid', 'BRL', true, timestamp '2026-01-01', timestamp '2026-01-01')
on conflict (id) do nothing;
set constraints all immediate;

insert into crm.activities
  (id, tenant_id, contact_id, opportunity_id, actor_profile_id, kind, direction, body, provider_message_id, created_at)
select ('50000000-0000-4000-8000-' || lpad((row_number() over (order by o.id))::text, 12, '0'))::uuid,
       o.tenant_id, o.contact_id, o.id, null, 'message', 'inbound', 'Synthetic staging activity',
       'synthetic-' || o.id::text, timestamp '2026-01-01'
from crm.opportunities o
where o.id::text like '30000000-0000-4000-8000-%'
on conflict (id) do nothing;

-- Raw sintético obrigatório para a FK de events_normalized.
insert into public.events_raw (id, received_at, source_system, event_type, location_id, payload, processing_status, created_at)
select ('60000000-0000-4000-8000-' || lpad((row_number() over (order by x.event_code))::text, 12, '0'))::uuid,
       timestamp '2026-01-01', 'ghl', x.event_code, 'synthetic-ghl-impulshub', jsonb_build_object('synthetic', true, 'event_code', x.event_code), 'processed', timestamp '2026-01-01'
from (values ('lead'), ('primeira_conversa'), ('agendado'), ('compareceu'), ('ganho'), ('perdido')) x(event_code)
on conflict (id) do nothing;

insert into public.events_normalized
  (id, raw_event_id, client_id, ghl_location_id, ghl_location_name, client_name,
   event_code, event_name, funnel_step, event_datetime, source_system,
   normalization_status, created_at, updated_at)
select ('70000000-0000-4000-8000-' || lpad((row_number() over (order by er.id))::text, 12, '0'))::uuid,
       er.id, '3ec294db-a64a-4420-9b4a-0d917f65d399', 'synthetic-ghl-impulshub',
       'Synthetic ImpulsHub Location', 'ImpulsHub', er.event_type,
       initcap(replace(er.event_type, '_', ' ')), row_number() over (order by er.id)::smallint,
       timestamp '2026-01-01', 'ghl', 'normalized', timestamp '2026-01-01', timestamp '2026-01-01'
from public.events_raw er
where er.id::text like '60000000-0000-4000-8000-%'
on conflict (id) do nothing;

commit;

select json_build_object(
  'clients', (select count(*) from public.clients_base where id in ('fa6fc071-7529-4317-93cb-9b0bfea3bca3','19c9d8c6-1a6d-499b-95fd-cc23d1cd555b','3bc0e6a4-6438-420d-b603-ec91bf296f4e','3ec294db-a64a-4420-9b4a-0d917f65d399')),
  'users', (select count(*) from auth.users where id in ('d036c4d6-0969-4175-b917-ff7e4dd3b376','4848733f-a369-4c8c-87cd-e62bbaa7b8f5','bb04435c-fabb-4ba8-b5b5-e0175d9ca17d','7c3296f4-13c7-42d1-89eb-72aecec905ba')),
  'client_users', (select count(*) from public.client_users where client_id in ('fa6fc071-7529-4317-93cb-9b0bfea3bca3','19c9d8c6-1a6d-499b-95fd-cc23d1cd555b','3bc0e6a4-6438-420d-b603-ec91bf296f4e','3ec294db-a64a-4420-9b4a-0d917f65d399')),
  'tenant_memberships', (select count(*) from crm.tenant_memberships where tenant_id in ('fa6fc071-7529-4317-93cb-9b0bfea3bca3','19c9d8c6-1a6d-499b-95fd-cc23d1cd555b','3bc0e6a4-6438-420d-b603-ec91bf296f4e','3ec294db-a64a-4420-9b4a-0d917f65d399')),
  'cards', (select count(*) from crm.opportunities where tenant_id in ('fa6fc071-7529-4317-93cb-9b0bfea3bca3','19c9d8c6-1a6d-499b-95fd-cc23d1cd555b','3bc0e6a4-6438-420d-b603-ec91bf296f4e','3ec294db-a64a-4420-9b4a-0d917f65d399')),
  'contacts', (select count(*) from crm.contacts where tenant_id in ('fa6fc071-7529-4317-93cb-9b0bfea3bca3','19c9d8c6-1a6d-499b-95fd-cc23d1cd555b','3bc0e6a4-6438-420d-b603-ec91bf296f4e','3ec294db-a64a-4420-9b4a-0d917f65d399')),
  'activities', (select count(*) from crm.activities where tenant_id in ('fa6fc071-7529-4317-93cb-9b0bfea3bca3','19c9d8c6-1a6d-499b-95fd-cc23d1cd555b','3bc0e6a4-6438-420d-b603-ec91bf296f4e','3ec294db-a64a-4420-9b4a-0d917f65d399')),
  'normalized_events', (select count(*) from public.events_normalized where source_system='ghl' and event_code in ('lead','primeira_conversa','agendado','compareceu','ganho','perdido'))
) as seed_counts;