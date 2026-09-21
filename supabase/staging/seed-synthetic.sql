begin;
set constraints all deferred;

-- IDs fixos, sem PII e sem segredos; todos os valores são exclusivos do staging.
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
 ('10000000-0000-4000-8000-000000000001','authenticated','authenticated','agency.synthetic@staging.invalid','[REDACTED]',timestamp '2026-01-01',timestamp '2026-01-01','{"provider":"email","providers":["email"]}','{"display_name":"Agency Synthetic"}',timestamp '2026-01-01',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000002','authenticated','authenticated','manager.synthetic@staging.invalid','[REDACTED]',timestamp '2026-01-01',timestamp '2026-01-01','{"provider":"email","providers":["email"]}','{"display_name":"Manager Synthetic"}',timestamp '2026-01-01',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000003','authenticated','authenticated','attendant.synthetic@staging.invalid','[REDACTED]',timestamp '2026-01-01',timestamp '2026-01-01','{"provider":"email","providers":["email"]}','{"display_name":"Attendant Synthetic"}',timestamp '2026-01-01',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000004','authenticated','authenticated','viewer.synthetic@staging.invalid','[REDACTED]',timestamp '2026-01-01',timestamp '2026-01-01','{"provider":"email","providers":["email"]}','{"display_name":"Viewer Synthetic"}',timestamp '2026-01-01',timestamp '2026-01-01')
on conflict (id) do nothing;

insert into crm.profiles (id, display_name, created_at) values
 ('10000000-0000-4000-8000-000000000001','Agency Synthetic',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000002','Manager Synthetic',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000003','Attendant Synthetic',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000004','Viewer Synthetic',timestamp '2026-01-01')
on conflict (id) do nothing;

insert into public.clients_base (id, ghl_location_id, client_name, status, timezone, enable_meta_tracking, enable_google_tracking, enable_ga4_tracking, meta_ad_accounts, google_ads_accounts, client_slug, crm_emits_conversions, created_at, updated_at)
values
 ('10000000-0000-4000-8000-000000000101','synthetic-ghl-a','Synthetic Client A','active','America/Sao_Paulo',false,false,false,'[]','[]','synthetic-a',false,timestamp '2026-01-01',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000102','synthetic-ghl-b','Synthetic Client B','active','America/Sao_Paulo',false,false,false,'[]','[]','synthetic-b',false,timestamp '2026-01-01',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000103','synthetic-ghl-impuls','Impuls-teste','active','America/Sao_Paulo',false,false,false,'[]','[]','impuls-teste',false,timestamp '2026-01-01',timestamp '2026-01-01')
on conflict (id) do nothing;

insert into crm.tenants (id, slug, name, status, created_at) values
 ('10000000-0000-4000-8000-000000000101','synthetic-a','Synthetic Client A','active',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000102','synthetic-b','Synthetic Client B','active',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000103','impuls-teste','Impuls-teste','active',timestamp '2026-01-01')
on conflict (id) do nothing;

insert into public.client_users (id, client_id, user_id, role, is_active, created_at, updated_at)
select gen_random_uuid(), c.id, u.id, r.role, true, timestamp '2026-01-01', timestamp '2026-01-01'
from (values
 ('10000000-0000-4000-8000-000000000101'::uuid),('10000000-0000-4000-8000-000000000102'::uuid),('10000000-0000-4000-8000-000000000103'::uuid)
) c(id) cross join (values
 ('10000000-0000-4000-8000-000000000001'::uuid,'agency'),('10000000-0000-4000-8000-000000000002'::uuid,'manager'),('10000000-0000-4000-8000-000000000003'::uuid,'attendant'),('10000000-0000-4000-8000-000000000004'::uuid,'viewer')
) u(id,role) cross join lateral (select u.role) r(role)
on conflict (client_id,user_id) do update set role=excluded.role,is_active=true,updated_at=excluded.updated_at;

insert into crm.tenant_memberships (id, tenant_id, profile_id, role, status, created_at, is_assignable)
select gen_random_uuid(), c.id, u.id, u.role, 'active', timestamp '2026-01-01', (u.role='attendant')
from (values
 ('10000000-0000-4000-8000-000000000101'::uuid),('10000000-0000-4000-8000-000000000102'::uuid),('10000000-0000-4000-8000-000000000103'::uuid)
) c(id) cross join (values
 ('10000000-0000-4000-8000-000000000001'::uuid,'admin'),('10000000-0000-4000-8000-000000000002'::uuid,'manager'),('10000000-0000-4000-8000-000000000003'::uuid,'attendant'),('10000000-0000-4000-8000-000000000004'::uuid,'viewer')
) u(id,role)
on conflict (tenant_id,profile_id) do update set role=excluded.role,status='active',is_assignable=excluded.is_assignable;

insert into crm.global_pipeline_versions (id, version_no, status, published_at, created_at)
values ('10000000-0000-4000-8000-000000000201',1,'published',timestamp '2026-01-01',timestamp '2026-01-01') on conflict (id) do nothing;
insert into crm.global_pipeline_stages (id,pipeline_version_id,code,label,position,is_terminal,created_at)
values
 ('10000000-0000-4000-8000-000000000211','10000000-0000-4000-8000-000000000201','lead','Lead',1,false,timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000212','10000000-0000-4000-8000-000000000201','atendimento','Atendimento',2,false,timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000213','10000000-0000-4000-8000-000000000201','agendado','Agendado',3,false,timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000214','10000000-0000-4000-8000-000000000201','compareceu','Compareceu',4,false,timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000215','10000000-0000-4000-8000-000000000201','ganho','Ganho',5,true,timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000216','10000000-0000-4000-8000-000000000201','perdido','Perdido',6,true,timestamp '2026-01-01')
on conflict (id) do nothing;

insert into crm.contacts (id,tenant_id,full_name,email,phone_normalized,default_owner_profile_id,status,created_at,updated_at)
values
 ('10000000-0000-4000-8000-000000000301','10000000-0000-4000-8000-000000000101','Synthetic Contact A','contact-a@staging.invalid','5511999000001','10000000-0000-4000-8000-000000000003','active',timestamp '2026-01-01',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000302','10000000-0000-4000-8000-000000000102','Synthetic Contact B','contact-b@staging.invalid','5511999000002','10000000-0000-4000-8000-000000000003','active',timestamp '2026-01-01',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000303','10000000-0000-4000-8000-000000000103','Synthetic Contact Impuls','contact-impuls@staging.invalid','5511999000003','10000000-0000-4000-8000-000000000003','active',timestamp '2026-01-01',timestamp '2026-01-01')
on conflict (id) do nothing;

insert into crm.opportunities (id,tenant_id,contact_id,pipeline_version_id,current_stage_id,stage_version,title,status,opened_at,created_at,updated_at,conversion_source,crc_owner_profile_id,sales_owner_profile_id)
values
 ('10000000-0000-4000-8000-000000000401','10000000-0000-4000-8000-000000000101','10000000-0000-4000-8000-000000000301','10000000-0000-4000-8000-000000000201','10000000-0000-4000-8000-000000000211',0,'Synthetic Opportunity A','open',timestamp '2026-01-01',timestamp '2026-01-01',timestamp '2026-01-01','organic','10000000-0000-4000-8000-000000000003',null),
 ('10000000-0000-4000-8000-000000000402','10000000-0000-4000-8000-000000000102','10000000-0000-4000-8000-000000000302','10000000-0000-4000-8000-000000000201','10000000-0000-4000-8000-000000000211',0,'Synthetic Opportunity B','open',timestamp '2026-01-01',timestamp '2026-01-01',timestamp '2026-01-01','google_ads',null,'10000000-0000-4000-8000-000000000003'),
 ('10000000-0000-4000-8000-000000000403','10000000-0000-4000-8000-000000000103','10000000-0000-4000-8000-000000000303','10000000-0000-4000-8000-000000000201','10000000-0000-4000-8000-000000000211',0,'Synthetic Opportunity Impuls','open',timestamp '2026-01-01',timestamp '2026-01-01',timestamp '2026-01-01','organic',null,null)
on conflict (id) do nothing;

insert into crm.opportunity_stage_history (id,tenant_id,opportunity_id,from_stage_id,to_stage_id,transition_type,origin,actor_profile_id,reason,occurred_at,created_at)
values
 ('10000000-0000-4000-8000-000000000501','10000000-0000-4000-8000-000000000101','10000000-0000-4000-8000-000000000401',null,'10000000-0000-4000-8000-000000000211','initial','system',null,'synthetic seed',timestamp '2026-01-01',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000502','10000000-0000-4000-8000-000000000102','10000000-0000-4000-8000-000000000402',null,'10000000-0000-4000-8000-000000000211','initial','system',null,'synthetic seed',timestamp '2026-01-01',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000503','10000000-0000-4000-8000-000000000103','10000000-0000-4000-8000-000000000403',null,'10000000-0000-4000-8000-000000000211','initial','system',null,'synthetic seed',timestamp '2026-01-01',timestamp '2026-01-01')
on conflict (id) do nothing;

insert into crm.activities (id,tenant_id,contact_id,opportunity_id,actor_profile_id,kind,direction,body,provider_message_id,created_at)
values
 ('10000000-0000-4000-8000-000000000601','10000000-0000-4000-8000-000000000101','10000000-0000-4000-8000-000000000301','10000000-0000-4000-8000-000000000401','10000000-0000-4000-8000-000000000003','message','inbound','Synthetic message A','synthetic-msg-a',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000602','10000000-0000-4000-8000-000000000102','10000000-0000-4000-8000-000000000302','10000000-0000-4000-8000-000000000402','10000000-0000-4000-8000-000000000003','message','inbound','Synthetic message B','synthetic-msg-b',timestamp '2026-01-01'),
 ('10000000-0000-4000-8000-000000000603','10000000-0000-4000-8000-000000000103','10000000-0000-4000-8000-000000000303','10000000-0000-4000-8000-000000000403','10000000-0000-4000-8000-000000000003','message','inbound','Synthetic message Impuls','synthetic-msg-impuls',timestamp '2026-01-01')
on conflict (id) do nothing;

commit;

select json_build_object('clients', (select count(*) from public.clients_base where id in ('10000000-0000-4000-8000-000000000101','10000000-0000-4000-8000-000000000102','10000000-0000-4000-8000-000000000103')), 'users', (select count(*) from auth.users where id between '10000000-0000-4000-8000-000000000001' and '10000000-0000-4000-8000-000000000004'), 'memberships', (select count(*) from crm.tenant_memberships where tenant_id in ('10000000-0000-4000-8000-000000000101','10000000-0000-4000-8000-000000000102','10000000-0000-4000-8000-000000000103')), 'cards', (select count(*) from crm.opportunities where id between '10000000-0000-4000-8000-000000000401' and '10000000-0000-4000-8000-000000000403'), 'contacts', (select count(*) from crm.contacts where id between '10000000-0000-4000-8000-000000000301' and '10000000-0000-4000-8000-000000000303'), 'activities', (select count(*) from crm.activities where id between '10000000-0000-4000-8000-000000000601' and '10000000-0000-4000-8000-000000000603')) as seed_counts;
