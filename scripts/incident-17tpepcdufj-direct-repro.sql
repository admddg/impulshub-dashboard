begin;
set constraints all deferred;
insert into crm.contacts (id, tenant_id, full_name, phone_normalized)
values
 ('10000000-0000-0000-0000-000000000001','3bc0e6a4-6438-420d-b603-ec91bf296f4e','repro-1','5511999000001'),
 ('10000000-0000-0000-0000-000000000002','3bc0e6a4-6438-420d-b603-ec91bf296f4e','repro-2','5511999000002');
insert into crm.opportunities
 (id,tenant_id,contact_id,pipeline_version_id,current_stage_id,title,status,opened_at)
values
 ('20000000-0000-0000-0000-000000000001','3bc0e6a4-6438-420d-b603-ec91bf296f4e','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','repro-1','open',clock_timestamp()),
 ('20000000-0000-0000-0000-000000000002','3bc0e6a4-6438-420d-b603-ec91bf296f4e','10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','repro-2','open',clock_timestamp());
insert into crm.opportunity_stage_history
 (id,tenant_id,opportunity_id,from_stage_id,to_stage_id,transition_type,origin,occurred_at)
values
 ('30000000-0000-0000-0000-000000000001','3bc0e6a4-6438-420d-b603-ec91bf296f4e','20000000-0000-0000-0000-000000000001',null,'00000000-0000-0000-0000-000000000201','automatic','sistema',clock_timestamp()),
 ('30000000-0000-0000-0000-000000000002','3bc0e6a4-6438-420d-b603-ec91bf296f4e','20000000-0000-0000-0000-000000000002',null,'00000000-0000-0000-0000-000000000201','automatic','sistema',clock_timestamp());
insert into crm.opportunity_stage_history
 (id,tenant_id,opportunity_id,from_stage_id,to_stage_id,transition_type,origin,occurred_at)
values
 ('30000000-0000-0000-0000-000000000011','3bc0e6a4-6438-420d-b603-ec91bf296f4e','20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000202','automatic','sistema',clock_timestamp()),
 ('30000000-0000-0000-0000-000000000012','3bc0e6a4-6438-420d-b603-ec91bf296f4e','20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000202','automatic','sistema',clock_timestamp());
update crm.opportunities set current_stage_id='00000000-0000-0000-0000-000000000202' where id in ('20000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002');
select 'before_immediate' as checkpoint,
       count(*) as opportunities,
       count(*) filter (where current_stage_id='00000000-0000-0000-0000-000000000202') as atendimento
from crm.opportunities where id in ('20000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002');
set constraints all immediate;
select 'after_immediate' as checkpoint;
rollback;
