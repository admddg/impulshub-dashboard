-- ============================================================================
-- Adiciona lead_entrada às views de Leads por etapa e Eventos recentes
-- ============================================================================

-- 1) LEADS POR ETAPA — recria incluindo lead_entrada
DROP VIEW IF EXISTS public.v_client_leads_by_stage;

CREATE VIEW public.v_client_leads_by_stage
WITH (security_invoker = true) AS
WITH jornada AS (
  SELECT
    en.client_id, en.contact_id,
    (array_agg(en.full_name ORDER BY en.event_datetime DESC) FILTER (WHERE en.full_name IS NOT NULL))[1] AS full_name,
    (array_agg(en.phone     ORDER BY en.event_datetime DESC) FILTER (WHERE en.phone IS NOT NULL))[1]     AS phone,
    (array_agg(en.email     ORDER BY en.event_datetime DESC) FILTER (WHERE en.email IS NOT NULL))[1]     AS email,
    (array_agg(
       normalize_channel_source(en.lead_origem, en.lead_entrada, en.source_id,
                                en.google_campaign_id, en.gclid, en.gbraid, en.wbraid)
       ORDER BY en.event_datetime ASC
     ) FILTER (WHERE en.lead_origem IS NOT NULL OR en.lead_entrada IS NOT NULL))[1] AS channel_source,
    (array_agg(en.lead_entrada ORDER BY en.event_datetime ASC) FILTER (WHERE en.lead_entrada IS NOT NULL))[1] AS lead_entrada,
    min(en.event_datetime) AS data_entrada,
    bool_or(en.event_code = 'primeira_conversa') AS teve_primeira_conversa,
    bool_or(en.event_code = 'agendado')          AS teve_agendado,
    bool_or(en.event_code = 'ganho' OR en.status = 'won')  AS teve_ganho,
    bool_or(en.event_code = 'perdido' OR en.status = 'lost') AS teve_perdido
  FROM events_normalized en
  WHERE en.contact_id IS NOT NULL
  GROUP BY en.client_id, en.contact_id
)
SELECT
  client_id, contact_id, full_name, phone, email,
  COALESCE(channel_source, 'Não Identificado') AS channel_source,
  lead_entrada, data_entrada,
  CASE
    WHEN teve_ganho THEN 'Ganho' WHEN teve_perdido THEN 'Perdido'
    WHEN teve_agendado THEN 'Agendado' WHEN teve_primeira_conversa THEN 'Primeira conversa'
    ELSE 'Lead' END AS etapa,
  CASE
    WHEN teve_ganho THEN 5 WHEN teve_perdido THEN 0
    WHEN teve_agendado THEN 3 WHEN teve_primeira_conversa THEN 2
    ELSE 1 END AS etapa_ordem
FROM jornada;

-- 2) EVENTOS RECENTES — recria incluindo lead_entrada
DROP VIEW IF EXISTS public.v_client_recent_events;

CREATE VIEW public.v_client_recent_events
WITH (security_invoker = true) AS
SELECT
  en.client_id, en.id AS event_id, en.event_datetime, en.event_code,
  en.full_name, en.phone, en.lead_entrada,
  COALESCE(
    normalize_channel_source(en.lead_origem, en.lead_entrada, en.source_id,
                             en.google_campaign_id, en.gclid, en.gbraid, en.wbraid),
    'Não Identificado'
  ) AS channel_source,
  en.pipeline_stage, en.opportunity_id
FROM events_normalized en
WHERE en.event_datetime IS NOT NULL;

-- grants
GRANT SELECT ON public.v_client_leads_by_stage TO authenticated;
GRANT SELECT ON public.v_client_recent_events  TO authenticated;
