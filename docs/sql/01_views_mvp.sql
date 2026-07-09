-- ============================================================================
-- ImpulsHub — Script de preparação do banco para o MVP do dashboard
-- Todas as views usam security_invoker = true (respeitam a RLS por client_id).
-- No fim há os GRANTs necessários para o app (usuário authenticated) enxergar.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1) META ADS — CAMPANHAS COM DATA E CONTA
--    Versão diária (com 'date' e 'account_id/name') da performance de campanha,
--    cruzando gasto de mídia (meta_ads_daily) com resultado do CRM por dia.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_meta_campaign_daily
WITH (security_invoker = true) AS
WITH midia AS (
  SELECT
    m.client_id, m.date, m.account_id, m.account_name,
    m.campaign_id, m.campaign_name,
    SUM(m.spend) AS spend, SUM(m.impressions) AS impressions, SUM(m.clicks) AS clicks
  FROM meta_ads_daily m
  GROUP BY m.client_id, m.date, m.account_id, m.account_name, m.campaign_id, m.campaign_name
),
ad_para_campanha AS (
  -- mapa ad_id -> campaign_id (cada anúncio pertence a uma campanha)
  SELECT DISTINCT m.client_id, m.ad_id, m.campaign_id
  FROM meta_ads_daily m
),
crm AS (
  -- leads do CRM atribuídos a um ad_id Meta, resolvidos para campanha e dia
  SELECT
    e.client_id, e.event_date AS date, a.campaign_id,
    COUNT(*) AS crm_leads
  FROM v_crm_events_enriched e
  JOIN ad_para_campanha a ON a.client_id = e.client_id AND a.ad_id = e.meta_ad_id
  WHERE e.meta_ad_id IS NOT NULL AND e.event_code = 'lead'
  GROUP BY e.client_id, e.event_date, a.campaign_id
)
SELECT
  mid.client_id, mid.date, mid.account_id, mid.account_name,
  mid.campaign_id, mid.campaign_name, mid.spend, mid.impressions, mid.clicks,
  COALESCE(c.crm_leads, 0) AS crm_leads
FROM midia mid
LEFT JOIN crm c ON c.client_id = mid.client_id AND c.campaign_id = mid.campaign_id AND c.date = mid.date;


-- ----------------------------------------------------------------------------
-- 2) META ADS — RESUMO POR CONTA DE ANÚNCIO
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_meta_account_daily
WITH (security_invoker = true) AS
SELECT
  m.client_id, m.date, m.account_id, m.account_name,
  SUM(m.spend) AS spend, SUM(m.impressions) AS impressions, SUM(m.clicks) AS clicks
FROM meta_ads_daily m
GROUP BY m.client_id, m.date, m.account_id, m.account_name;


-- ----------------------------------------------------------------------------
-- 3) GOOGLE ADS — CAMPANHAS COM DATA
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_google_campaign_daily
WITH (security_invoker = true) AS
WITH midia AS (
  SELECT
    g.client_id, g.date, g.customer_id, g.customer_name,
    g.campaign_id, g.campaign_name,
    SUM(g.cost) AS spend, SUM(g.impressions) AS impressions, SUM(g.clicks) AS clicks
  FROM google_ads_daily g
  GROUP BY g.client_id, g.date, g.customer_id, g.customer_name, g.campaign_id, g.campaign_name
),
crm AS (
  SELECT
    e.client_id, e.event_date AS date, e.google_campaign_id,
    COUNT(*) FILTER (WHERE e.event_code = 'lead') AS crm_leads
  FROM v_crm_events_enriched e
  WHERE e.google_campaign_id IS NOT NULL
  GROUP BY e.client_id, e.event_date, e.google_campaign_id
)
SELECT
  mid.client_id, mid.date, mid.customer_id, mid.customer_name,
  mid.campaign_id, mid.campaign_name, mid.spend, mid.impressions, mid.clicks,
  COALESCE(c.crm_leads, 0) AS crm_leads
FROM midia mid
LEFT JOIN crm c ON c.client_id = mid.client_id AND c.google_campaign_id = mid.campaign_id AND c.date = mid.date;


-- ----------------------------------------------------------------------------
-- 4) LEADS POR ETAPA (dado pessoal — apenas nome, telefone, origem, etapa)
--    Conta a jornada por CONTATO (contact_id), a partir dos eventos —
--    inclui leads que nunca viraram oportunidade formal.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_client_leads_by_stage
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
  data_entrada,
  CASE
    WHEN teve_ganho THEN 'Ganho' WHEN teve_perdido THEN 'Perdido'
    WHEN teve_agendado THEN 'Agendado' WHEN teve_primeira_conversa THEN 'Primeira conversa'
    ELSE 'Lead' END AS etapa,
  CASE
    WHEN teve_ganho THEN 5 WHEN teve_perdido THEN 0
    WHEN teve_agendado THEN 3 WHEN teve_primeira_conversa THEN 2
    ELSE 1 END AS etapa_ordem
FROM jornada;


-- ----------------------------------------------------------------------------
-- 5) ÚLTIMOS EVENTOS (histórico recente)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_client_recent_events
WITH (security_invoker = true) AS
SELECT
  en.client_id, en.id AS event_id, en.event_datetime, en.event_code,
  en.full_name, en.phone,
  COALESCE(
    normalize_channel_source(en.lead_origem, en.lead_entrada, en.source_id,
                             en.google_campaign_id, en.gclid, en.gbraid, en.wbraid),
    'Não Identificado'
  ) AS channel_source,
  en.pipeline_stage, en.opportunity_id
FROM events_normalized en
WHERE en.event_datetime IS NOT NULL;


-- ============================================================================
-- 6) GRANTS
-- ============================================================================
GRANT SELECT ON public.v_meta_campaign_daily    TO authenticated;
GRANT SELECT ON public.v_meta_account_daily     TO authenticated;
GRANT SELECT ON public.v_google_campaign_daily  TO authenticated;
GRANT SELECT ON public.v_client_leads_by_stage  TO authenticated;
GRANT SELECT ON public.v_client_recent_events   TO authenticated;
