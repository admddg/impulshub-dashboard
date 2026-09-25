-- IMP-17TPEPCDUFJ acceptance: staging only, never production.
-- The caller must wrap this file in the staging transaction runner; this file
-- creates raw Stevo fixtures, invokes the real parser, asserts the full result,
-- and rolls the transaction back.
BEGIN;
SET LOCAL statement_timeout = '10s';
SET CONSTRAINTS ALL DEFERRED;

DO $$
DECLARE
  v_target_tenant uuid := '3bc0e6a4-6438-420d-b603-ec91bf296f4e';
  v_other_tenant uuid := '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b';
  v_atendimento uuid;
  v_result record;
  v_ocorrido timestamptz := '2026-09-23 12:00:00+00';
  v_target_inbound uuid := '32000000-0000-0000-0000-000000000001';
  v_target_outbound uuid := '32000000-0000-0000-0000-000000000002';
  v_other_inbound uuid := '32000000-0000-0000-0000-000000000003';
  v_other_outbound uuid := '32000000-0000-0000-0000-000000000004';
  v_target_inbound_payload jsonb;
  v_target_outbound_payload jsonb;
  v_other_inbound_payload jsonb;
  v_other_outbound_payload jsonb;
  v_definition text;
  v_count bigint;
BEGIN
  SELECT s.id INTO v_atendimento
    FROM crm.global_pipeline_stages s
   WHERE s.code = 'atendimento'
   ORDER BY s.id
   LIMIT 1;

  IF v_atendimento IS NULL
     OR NOT EXISTS (SELECT 1 FROM crm.tenants WHERE id IN (v_target_tenant, v_other_tenant)) THEN
    RAISE EXCEPTION 'acceptance fixtures require both staging tenants and atendimento stage';
  END IF;

  SELECT pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)
    INTO v_definition;
  IF v_definition NOT LIKE '%v_ocorrido + interval ''1 microsecond''%' THEN
    RAISE EXCEPTION 'parser tie fix is not installed';
  END IF;

  v_target_inbound_payload := jsonb_build_object(
    'data', jsonb_build_object(
      'Info', jsonb_build_object('Chat', '5511999000012@s.whatsapp.net', 'IsGroup', false,
                                 'IsFromMe', false, 'PushName', 'tie-target'),
      'Message', jsonb_build_object(
        'extendedTextMessage', jsonb_build_object(
          'contextInfo', jsonb_build_object('conversionSource', 'FACEBOOK_AD'))),
      'text', 'synthetic inbound target'));
  v_target_outbound_payload := jsonb_build_object(
    'data', jsonb_build_object(
      'Info', jsonb_build_object('Chat', '5511999000012@s.whatsapp.net', 'IsGroup', false,
                                 'IsFromMe', true, 'PushName', 'agent'),
      'Message', jsonb_build_object('conversation', 'synthetic outbound target'),
      'text', 'synthetic outbound target'));
  v_other_inbound_payload := jsonb_build_object(
    'data', jsonb_build_object(
      'Info', jsonb_build_object('Chat', '5511999000013@s.whatsapp.net', 'IsGroup', false,
                                 'IsFromMe', false, 'PushName', 'tie-other'),
      'Message', jsonb_build_object(
        'extendedTextMessage', jsonb_build_object(
          'contextInfo', jsonb_build_object('conversionSource', 'FACEBOOK_AD'))),
      'text', 'synthetic inbound other'));
  v_other_outbound_payload := jsonb_build_object(
    'data', jsonb_build_object(
      'Info', jsonb_build_object('Chat', '5511999000013@s.whatsapp.net', 'IsGroup', false,
                                 'IsFromMe', true, 'PushName', 'agent'),
      'Message', jsonb_build_object('conversation', 'synthetic outbound other'),
      'text', 'synthetic outbound other'));

  INSERT INTO public.stevo_events_raw
    (id, client_id, event_type, external_message_id, event_timestamp, received_at,
     payload, payload_hash, parse_status)
  VALUES
    (v_target_inbound, v_target_tenant, 'Message', 'imp17-target-inbound', v_ocorrido,
     v_ocorrido, v_target_inbound_payload, md5(v_target_inbound_payload::text), 'raw'),
    (v_target_outbound, v_target_tenant, 'Message', 'imp17-target-outbound', v_ocorrido,
     v_ocorrido + interval '1 microsecond', v_target_outbound_payload,
     md5(v_target_outbound_payload::text), 'raw'),
    (v_other_inbound, v_other_tenant, 'Message', 'imp17-other-inbound', v_ocorrido,
     v_ocorrido, v_other_inbound_payload, md5(v_other_inbound_payload::text), 'raw'),
    (v_other_outbound, v_other_tenant, 'Message', 'imp17-other-outbound', v_ocorrido,
     v_ocorrido + interval '1 microsecond', v_other_outbound_payload,
     md5(v_other_outbound_payload::text), 'raw');

  SELECT * INTO v_result FROM crm.stevo_parse_messages(4);

  IF v_result.lidos <> 4 OR v_result.oportunidades_criadas <> 2 OR v_result.atendimentos <> 2 THEN
    RAISE EXCEPTION 'parser result mismatch: lidos=% opportunities=% atendimentos=%',
      v_result.lidos, v_result.oportunidades_criadas, v_result.atendimentos;
  END IF;

  IF (SELECT count(*) FROM crm.opportunities o
      JOIN crm.contacts c ON c.id = o.contact_id
      WHERE o.tenant_id = v_target_tenant AND c.phone_normalized = '5511999000012'
        AND o.current_stage_id = v_atendimento) <> 1
     OR (SELECT count(*) FROM crm.opportunities o
         JOIN crm.contacts c ON c.id = o.contact_id
         WHERE o.tenant_id = v_other_tenant AND c.phone_normalized = '5511999000013'
           AND o.current_stage_id = v_atendimento) <> 1 THEN
    RAISE EXCEPTION 'opportunity stage or tenant isolation assertion failed';
  END IF;

  SELECT count(*) INTO v_count FROM crm.activities
   WHERE raw_event_id IN (v_target_inbound, v_target_outbound, v_other_inbound, v_other_outbound);
  IF v_count <> 4 THEN RAISE EXCEPTION 'activity count=%', v_count; END IF;

  SELECT count(*) INTO v_count FROM crm.opportunity_stage_history h
   JOIN crm.opportunities o ON o.id = h.opportunity_id
   JOIN crm.contacts c ON c.id = o.contact_id
   WHERE c.phone_normalized IN ('5511999000012', '5511999000013');
  IF v_count <> 4 THEN RAISE EXCEPTION 'stage history count=%', v_count; END IF;

  IF EXISTS (SELECT 1 FROM crm.activities
             WHERE raw_event_id IN (v_target_inbound, v_target_outbound)
               AND tenant_id <> v_target_tenant)
     OR EXISTS (SELECT 1 FROM crm.activities
                WHERE raw_event_id IN (v_other_inbound, v_other_outbound)
                  AND tenant_id <> v_other_tenant) THEN
    RAISE EXCEPTION 'activity tenant crossed';
  END IF;

  IF EXISTS (SELECT 1 FROM public.stevo_events_raw
             WHERE id IN (v_target_inbound, v_target_outbound, v_other_inbound, v_other_outbound)
               AND parse_status <> 'processed') THEN
    RAISE EXCEPTION 'raw fixture was not processed';
  END IF;

  -- The deferred consistency trigger is part of the evidence, not bypassed.
  SET CONSTRAINTS ALL IMMEDIATE;
  RAISE NOTICE 'parser_tie_fix_acceptance_passed lidos=% opportunities=% activities=% history=%',
    v_result.lidos, v_result.oportunidades_criadas, 4, 4;
END
$$;

SELECT 'parser_tie_fix_acceptance_passed' AS result;
ROLLBACK;
