BEGIN;
SET CONSTRAINTS ALL DEFERRED;
SELECT current_database() AS database_name, current_user AS current_user_name,
       current_setting('server_version') AS server_version,
       (SELECT id FROM crm.tenants WHERE id='3bc0e6a4-6438-420d-b603-ec91bf296f4e') AS expected_tenant,
       (SELECT id FROM crm.global_pipeline_versions WHERE status='active') AS active_pipeline,
       (SELECT id FROM crm.global_pipeline_stages WHERE code='lead' AND pipeline_version_id=(SELECT id FROM crm.global_pipeline_versions WHERE status='active')) AS lead_stage,
       (SELECT id FROM crm.global_pipeline_stages WHERE code='atendimento' AND pipeline_version_id=(SELECT id FROM crm.global_pipeline_versions WHERE status='active')) AS atendimento_stage;

-- Downstream emission flags are disabled only for this transaction and rolled back.
UPDATE public.clients_base
   SET meta_enabled=false, meta_standard_enabled=false, meta_whatsapp_enabled=false,
       google_offline_enabled=false, google_data_manager_enabled=false,
       crm_feeds_dashboard=false, crm_emits_conversions=false
 WHERE id='3bc0e6a4-6438-420d-b603-ec91bf296f4e';

INSERT INTO public.stevo_events_raw
  (id, client_id, received_at, event_type, external_message_id, event_timestamp,
   http_method, headers, query_params, payload, payload_hash, parse_status)
VALUES
 ('a7000000-0000-0000-0000-000000000001','3bc0e6a4-6438-420d-b603-ec91bf296f4e','2026-09-23 12:00:00+00','Message','imp17-inbound-tie','2026-09-23 12:00:00+00','POST','{}','{}',
  '{"data":{"Info":{"Chat":"5511999000012@s.whatsapp.net","IsGroup":false,"IsFromMe":false,"PushName":"imp17-tie","ID":"imp17-inbound-tie"},"text":"oi","Message":{"extendedTextMessage":{"text":"oi","contextInfo":{"conversionSource":"imp17_fixture"}}}}}'::jsonb,
  repeat('1',64),'raw'),
 ('a7000000-0000-0000-0000-000000000002','3bc0e6a4-6438-420d-b603-ec91bf296f4e','2026-09-23 12:00:00+00','Message','imp17-outbound-plus1us','2026-09-23 12:00:00.000001+00','POST','{}','{}',
  '{"data":{"Info":{"Chat":"5511999000012@s.whatsapp.net","IsGroup":false,"IsFromMe":true,"PushName":"fixture-agent","ID":"imp17-outbound-tie"},"text":"resposta","Message":{"conversation":"resposta"}}}'::jsonb,
  repeat('2',64),'raw');

SELECT id, client_id, event_type, external_message_id, event_timestamp, parse_status
  FROM public.stevo_events_raw
 WHERE id IN ('a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-000000000002')
 ORDER BY id;

SELECT 'BEFORE_PARSER' AS snapshot, count(*) AS history_rows,
       (SELECT count(*) FROM crm.opportunities WHERE title='imp17-tie') AS matching_opportunities
  FROM crm.opportunity_stage_history;

SELECT * FROM crm.stevo_parse_messages(2);

SELECT 'AFTER_PARSER_BEFORE_IMMEDIATE' AS snapshot,
       h.id, h.opportunity_id, h.from_stage_id, h.to_stage_id, h.occurred_at, h.created_at
  FROM crm.opportunity_stage_history h
 WHERE h.opportunity_id IN (SELECT id FROM crm.opportunities WHERE title='imp17-tie')
 ORDER BY h.occurred_at DESC, h.created_at DESC, h.id DESC;
SELECT 'OPPORTUNITIES_AFTER_PARSER' AS snapshot,
       id, contact_id, current_stage_id, opened_at, created_at, updated_at
  FROM crm.opportunities WHERE title='imp17-tie';

CREATE TEMP TABLE imp17_error(sqlstate text, message text, detail text, hint text) ON COMMIT DROP;
DO $$
DECLARE s text; m text; d text; h text;
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  INSERT INTO imp17_error VALUES ('00000','no constraint error',NULL,NULL);
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS s=RETURNED_SQLSTATE, m=MESSAGE_TEXT, d=PG_EXCEPTION_DETAIL, h=PG_EXCEPTION_HINT;
  INSERT INTO imp17_error VALUES (s,m,d,h);
END $$;
SELECT 'CONSTRAINT_CHECK' AS snapshot, * FROM imp17_error;
ROLLBACK;
