begin;
set constraints all deferred;
insert into crm.contacts (id, tenant_id, full_name, phone_normalized)
values ('11000000-0000-0000-0000-000000000001','3bc0e6a4-6438-420d-b603-ec91bf296f4e','tie-repro','5511999000011');
insert into crm.opportunities
 (id,tenant_id,contact_id,pipeline_version_id,current_stage_id,title,status,opened_at)
values ('21000000-0000-0000-0000-000000000001','3bc0e6a4-6438-420d-b603-ec91bf296f4e','11000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','tie-repro','open','2026-09-23 12:00:00+00');
insert into crm.opportunity_stage_history
 (id,tenant_id,opportunity_id,from_stage_id,to_stage_id,transition_type,origin,occurred_at)
values
 ('32000000-0000-0000-0000-000000000002','3bc0e6a4-6438-420d-b603-ec91bf296f4e','21000000-0000-0000-0000-000000000001',null,'00000000-0000-0000-0000-000000000201','automatic','sistema','2026-09-23 12:00:00+00'),
 ('32000000-0000-0000-0000-000000000001','3bc0e6a4-6438-420d-b603-ec91bf296f4e','21000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000202','automatic','sistema','2026-09-23 12:00:00+00');
update crm.opportunities set current_stage_id='00000000-0000-0000-0000-000000000202' where id='21000000-0000-0000-0000-000000000001';
set constraints all immediate;
rollback;
