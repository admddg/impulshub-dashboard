-- ============================================================================
-- ImpulsHub — Recriação das views Meta/Google para o mix Plataforma + CRM
-- Adiciona: meta_platform_conversions (Conversões Meta), google_conversions,
-- e crm_agendados às views de conta/campanha, para o mix:
-- Investido | Conversões (plataforma) | Leads | CPL | Agendamentos | CPag
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1) META ADS — CONTAS
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_meta_account_daily;

CREATE VIEW public.v_meta_account_daily
WITH (security_invoker = true) AS
WITH midia AS (
  SELECT
    m.client_id, m.date, m.account_id, m.account_name,
    SUM(m.spend) AS spend, SUM(m.impressions) AS impressions, SUM(m.clicks) AS clicks,
    SUM(COALESCE(m.meta_platform_conversions, 0)) AS meta_conversions
  FROM meta_ads_daily m
  GROUP BY m.client_id, m.date, m.account_id, m.account_name
),
ad_para_conta AS (
  SELECT DISTINCT m.client_id, m.ad_id, m.account_id FROM meta_ads_daily m
),
crm AS (
  SELECT
    e.client_id, e.event_date AS date, a.account_id,
    COUNT(*) FILTER (WHERE e.event_code = 'lead')     AS crm_leads,
    COUNT(*) FILTER (WHERE e.event_code = 'agendado') AS crm_agendados
  FROM v_crm_events_enriched e
  JOIN ad_para_conta a ON a.client_id = e.client_id AND a.ad_id = e.meta_ad_id
  WHERE e.meta_ad_id IS NOT NULL
  GROUP BY e.client_id, e.event_date, a.account_id
)
SELECT
  mid.client_id, mid.date, mid.account_id, mid.account_name,
  mid.spend, mid.impressions, mid.clicks, mid.meta_conversions,
  COALESCE(c.crm_leads, 0) AS crm_leads,
  COALESCE(c.crm_agendados, 0) AS crm_agendados
FROM midia mid
LEFT JOIN crm c ON c.client_id = mid.client_id AND c.account_id = mid.account_id AND c.date = mid.date;


-- ----------------------------------------------------------------------------
-- 2) META ADS — CAMPANHAS
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_meta_campaign_daily;

CREATE VIEW public.v_meta_campaign_daily
WITH (security_invoker = true) AS
WITH midia AS (
  SELECT
    m.client_id, m.date, m.account_id, m.account_name, m.campaign_id, m.campaign_name,
    SUM(m.spend) AS spend, SUM(m.impressions) AS impressions, SUM(m.clicks) AS clicks,
    SUM(COALESCE(m.meta_platform_conversions, 0)) AS meta_conversions
  FROM meta_ads_daily m
  GROUP BY m.client_id, m.date, m.account_id, m.account_name, m.campaign_id, m.campaign_name
),
ad_para_campanha AS (
  SELECT DISTINCT m.client_id, m.ad_id, m.campaign_id FROM meta_ads_daily m
),
crm AS (
  SELECT
    e.client_id, e.event_date AS date, a.campaign_id,
    COUNT(*) FILTER (WHERE e.event_code = 'lead')     AS crm_leads,
    COUNT(*) FILTER (WHERE e.event_code = 'agendado') AS crm_agendados
  FROM v_crm_events_enriched e
  JOIN ad_para_campanha a ON a.client_id = e.client_id AND a.ad_id = e.meta_ad_id
  WHERE e.meta_ad_id IS NOT NULL
  GROUP BY e.client_id, e.event_date, a.campaign_id
)
SELECT
  mid.client_id, mid.date, mid.account_id, mid.account_name,
  mid.campaign_id, mid.campaign_name, mid.spend, mid.impressions, mid.clicks, mid.meta_conversions,
  COALESCE(c.crm_leads, 0) AS crm_leads,
  COALESCE(c.crm_agendados, 0) AS crm_agendados
FROM midia mid
LEFT JOIN crm c ON c.client_id = mid.client_id AND c.campaign_id = mid.campaign_id AND c.date = mid.date;


-- ----------------------------------------------------------------------------
-- 3) GOOGLE ADS — CAMPANHAS (adiciona conversões da plataforma)
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_google_campaign_daily;

CREATE VIEW public.v_google_campaign_daily
WITH (security_invoker = true) AS
WITH midia AS (
  SELECT
    g.client_id, g.date, g.customer_id, g.customer_name, g.campaign_id, g.campaign_name,
    SUM(g.cost) AS spend, SUM(g.impressions) AS impressions, SUM(g.clicks) AS clicks,
    SUM(COALESCE(g.conversions, 0)) AS google_conversions
  FROM google_ads_daily g
  GROUP BY g.client_id, g.date, g.customer_id, g.customer_name, g.campaign_id, g.campaign_name
),
crm AS (
  SELECT
    e.client_id, e.event_date AS date, e.google_campaign_id,
    COUNT(*) FILTER (WHERE e.event_code = 'lead')     AS crm_leads,
    COUNT(*) FILTER (WHERE e.event_code = 'agendado') AS crm_agendados
  FROM v_crm_events_enriched e
  WHERE e.google_campaign_id IS NOT NULL
  GROUP BY e.client_id, e.event_date, e.google_campaign_id
)
SELECT
  mid.client_id, mid.date, mid.customer_id, mid.customer_name,
  mid.campaign_id, mid.campaign_name, mid.spend, mid.impressions, mid.clicks, mid.google_conversions,
  COALESCE(c.crm_leads, 0) AS crm_leads,
  COALESCE(c.crm_agendados, 0) AS crm_agendados
FROM midia mid
LEFT JOIN crm c ON c.client_id = mid.client_id AND c.google_campaign_id = mid.campaign_id AND c.date = mid.date;


-- ============================================================================
-- 4) GRANTS (DROP remove permissões — reaplica)
-- ============================================================================
GRANT SELECT ON public.v_meta_account_daily    TO authenticated;
GRANT SELECT ON public.v_meta_campaign_daily   TO authenticated;
GRANT SELECT ON public.v_google_campaign_daily TO authenticated;
