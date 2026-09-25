begin;
set local statement_timeout = '8s';
set constraints all deferred;
create temp table incident_17_matrix_results (
  case_name text,
  outcome text,
  detail text
) on commit drop;

do $$
declare
  err text;
  detail_text text;
begin
  -- M1: uma mensagem/evento: uma oportunidade e uma única linha de histórico.
  begin
    insert into crm.contacts (id, tenant_id, full_name, phone_normalized)
    values ('41000000-0000-0000-0000-000000000001','3bc0e6a4-6438-420d-b603-ec91bf296f4e','m1','5511999000101');
    insert into crm.opportunities
      (id,tenant_id,contact_id,pipeline_version_id,current_stage_id,title,status,opened_at)
    values ('42000000-0000-0000-0000-000000000001','3bc0e6a4-6438-420d-b603-ec91bf296f4e','41000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','m1','open','2026-09-23 12:00:00+00');
    insert into crm.opportunity_stage_history
      (id,tenant_id,opportunity_id,from_stage_id,to_stage_id,transition_type,origin,occurred_at)
    values ('43000000-0000-0000-0000-000000000001','3bc0e6a4-6438-420d-b603-ec91bf296f4e','42000000-0000-0000-0000-000000000001',null,'00000000-0000-0000-0000-000000000201','automatic','sistema','2026-09-23 12:00:00+00');
    insert into incident_17_matrix_results values ('M1 one message / one history','PASS','set constraints all immediate');
  exception when others then
    get stacked diagnostics err = message_text, detail_text = pg_exception_detail;
    insert into incident_17_matrix_results values ('M1 one message / one history','FAIL',coalesce(err,'')||' '||coalesce(detail_text,''));
  end;
  set constraints all deferred;

  -- M2: duas linhas do mesmo evento, empate e UUID da linha inicial maior.
  begin
    insert into crm.contacts (id, tenant_id, full_name, phone_normalized)
    values ('41000000-0000-0000-0000-000000000002','3bc0e6a4-6438-420d-b603-ec91bf296f4e','m2','5511999000102');
    insert into crm.opportunities
      (id,tenant_id,contact_id,pipeline_version_id,current_stage_id,title,status,opened_at)
    values ('42000000-0000-0000-0000-000000000002','3bc0e6a4-6438-420d-b603-ec91bf296f4e','41000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','m2','open','2026-09-23 12:00:00+00');
    insert into crm.opportunity_stage_history
      (id,tenant_id,opportunity_id,from_stage_id,to_stage_id,transition_type,origin,occurred_at)
    values
      ('43000000-0000-0000-0000-000000000022','3bc0e6a4-6438-420d-b603-ec91bf296f4e','42000000-0000-0000-0000-000000000002',null,'00000000-0000-0000-0000-000000000201','automatic','sistema','2026-09-23 12:00:00+00'),
      ('43000000-0000-0000-0000-000000000021','3bc0e6a4-6438-420d-b603-ec91bf296f4e','42000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000202','automatic','sistema','2026-09-23 12:00:00+00');
    update crm.opportunities set current_stage_id='00000000-0000-0000-0000-000000000202' where id='42000000-0000-0000-0000-000000000002';
    set constraints all immediate;
    insert into incident_17_matrix_results values ('M2 two messages / tied timestamp / initial id greater','PASS','unexpected');
  exception when others then
    get stacked diagnostics err = message_text, detail_text = pg_exception_detail;
    insert into incident_17_matrix_results values ('M2 two messages / tied timestamp / initial id greater','FAIL',coalesce(err,'')||' '||coalesce(detail_text,''));
  end;
  set constraints all deferred;

  -- M3: mesma ordem lógica, mas UUID da transição maior: o empate passa por acidente.
  begin
    insert into crm.contacts (id, tenant_id, full_name, phone_normalized)
    values ('41000000-0000-0000-0000-000000000003','3bc0e6a4-6438-420d-b603-ec91bf296f4e','m3','5511999000103');
    insert into crm.opportunities
      (id,tenant_id,contact_id,pipeline_version_id,current_stage_id,title,status,opened_at)
    values ('42000000-0000-0000-0000-000000000003','3bc0e6a4-6438-420d-b603-ec91bf296f4e','41000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','m3','open','2026-09-23 12:00:00+00');
    insert into crm.opportunity_stage_history
      (id,tenant_id,opportunity_id,from_stage_id,to_stage_id,transition_type,origin,occurred_at)
    values
      ('43000000-0000-0000-0000-000000000031','3bc0e6a4-6438-420d-b603-ec91bf296f4e','42000000-0000-0000-0000-000000000003',null,'00000000-0000-0000-0000-000000000201','automatic','sistema','2026-09-23 12:00:00+00'),
      ('43000000-0000-0000-0000-000000000032','3bc0e6a4-6438-420d-b603-ec91bf296f4e','42000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000202','automatic','sistema','2026-09-23 12:00:00+00');
    update crm.opportunities set current_stage_id='00000000-0000-0000-0000-000000000202' where id='42000000-0000-0000-0000-000000000003';
    set constraints all immediate;
    insert into incident_17_matrix_results values ('M3 two messages / tied timestamp / transition id greater','PASS','UUID tie-break masks defect');
  exception when others then
    get stacked diagnostics err = message_text, detail_text = pg_exception_detail;
    insert into incident_17_matrix_results values ('M3 two messages / tied timestamp / transition id greater','FAIL',coalesce(err,'')||' '||coalesce(detail_text,''));
  end;
  set constraints all deferred;

  -- M4: duas linhas, ordem temporal estrita; passa independentemente do UUID.
  begin
    insert into crm.contacts (id, tenant_id, full_name, phone_normalized)
    values ('41000000-0000-0000-0000-000000000004','3bc0e6a4-6438-420d-b603-ec91bf296f4e','m4','5511999000104');
    insert into crm.opportunities
      (id,tenant_id,contact_id,pipeline_version_id,current_stage_id,title,status,opened_at)
    values ('42000000-0000-0000-0000-000000000004','3bc0e6a4-6438-420d-b603-ec91bf296f4e','41000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000201','m4','open','2026-09-23 12:00:00+00');
    insert into crm.opportunity_stage_history
      (id,tenant_id,opportunity_id,from_stage_id,to_stage_id,transition_type,origin,occurred_at)
    values
      ('43000000-0000-0000-0000-000000000042','3bc0e6a4-6438-420d-b603-ec91bf296f4e','42000000-0000-0000-0000-000000000004',null,'00000000-0000-0000-0000-000000000201','automatic','sistema','2026-09-23 12:00:00+00'),
      ('43000000-0000-0000-0000-000000000041','3bc0e6a4-6438-420d-b603-ec91bf296f4e','42000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000202','automatic','sistema','2026-09-23 12:00:00.000001+00');
    update crm.opportunities set current_stage_id='00000000-0000-0000-0000-000000000202' where id='42000000-0000-0000-0000-000000000004';
    set constraints all immediate;
    insert into incident_17_matrix_results values ('M4 two messages / +1 microsecond / deferred then immediate','PASS','strict occurred_at order');
  exception when others then
    get stacked diagnostics err = message_text, detail_text = pg_exception_detail;
    insert into incident_17_matrix_results values ('M4 two messages / +1 microsecond / deferred then immediate','FAIL',coalesce(err,'')||' '||coalesce(detail_text,''));
  end;
  set constraints all deferred;
end $$;
select case_name, outcome, detail from incident_17_matrix_results order by case_name;
rollback;
