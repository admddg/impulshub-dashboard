-- IMP-17TPEPCDUFJ acceptance for staging only.
-- Run after the forward migration, then rollback the fixture transaction.
BEGIN;
SET CONSTRAINTS ALL DEFERRED;

DO $$
DECLARE
  definition text;
BEGIN
  SELECT pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)
    INTO definition;
  IF definition NOT LIKE '%v_ocorrido + interval ''1 microsecond''%' THEN
    RAISE EXCEPTION 'parser tie fix is not installed';
  END IF;
END
$$;

INSERT INTO crm.contacts (id, tenant_id, full_name, phone_normalized)
VALUES ('12000000-0000-0000-0000-000000000001', '3bc0e6a4-6438-420d-b603-ec91bf296f4e', 'tie-fixed-acceptance', '5511999000012');
INSERT INTO crm.opportunities
  (id, tenant_id, contact_id, pipeline_version_id, current_stage_id, title, status, opened_at)
VALUES
  ('22000000-0000-0000-0000-000000000001', '3bc0e6a4-6438-420d-b603-ec91bf296f4e',
   '12000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000101',
   '00000000-0000-0000-0000-000000000201', 'tie-fixed-acceptance', 'open',
   '2026-09-23 12:00:00+00');
INSERT INTO crm.opportunity_stage_history
  (id, tenant_id, opportunity_id, from_stage_id, to_stage_id, transition_type, origin, occurred_at)
VALUES
  ('33000000-0000-0000-0000-000000000002', '3bc0e6a4-6438-420d-b603-ec91bf296f4e',
   '22000000-0000-0000-0000-000000000001', NULL,
   '00000000-0000-0000-0000-000000000201', 'automatic', 'sistema',
   '2026-09-23 12:00:00+00'),
  ('33000000-0000-0000-0000-000000000001', '3bc0e6a4-6438-420d-b603-ec91bf296f4e',
   '22000000-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-000000000201',
   '00000000-0000-0000-0000-000000000202', 'automatic', 'sistema',
   '2026-09-23 12:00:00.000001+00');
UPDATE crm.opportunities
   SET current_stage_id = '00000000-0000-0000-0000-000000000202'
 WHERE id = '22000000-0000-0000-0000-000000000001';

SET CONSTRAINTS ALL IMMEDIATE;
SELECT 'parser_tie_fix_acceptance_passed' AS result;
ROLLBACK;
