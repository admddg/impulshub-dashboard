-- ============================================================================
-- Correção da v_crm_funnel_daily
-- Problema: primeira_conversa/agendado/ganho/perdido eram contados a partir da
-- v_crm_opportunities (poucas linhas, com datas de etapa nem sempre
-- preenchidas), enquanto os eventos reais vivem em v_crm_events_enriched.
-- Resultado observado: primeira conversa aparecia zerada mesmo havendo
-- centenas de eventos reais.
-- Correção: contar TODAS as etapas a partir dos eventos (event_code), na
-- mesma fonte que já era usada para os leads. Fica coerente entre si.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_crm_funnel_daily
WITH (security_invoker = true) AS
SELECT
  e.client_id, e.client_name, e.client_slug, e.event_date,
  COALESCE(e.channel_source, 'Não Identificado'::text) AS channel_source,
  count(*) FILTER (WHERE e.event_code = 'lead')              AS crm_leads,
  count(*) FILTER (WHERE e.event_code = 'primeira_conversa') AS crm_primeiras_conversas,
  count(*) FILTER (WHERE e.event_code = 'agendado')          AS crm_agendados,
  count(*) FILTER (WHERE e.event_code = 'ganho'
                        OR e.status = 'won'
                        OR e.pipeline_stage ILIKE '%ganho%') AS crm_ganhos,
  count(*) FILTER (WHERE e.event_code = 'perdido'
                        OR e.status = 'lost'
                        OR e.pipeline_stage ILIKE '%perdido%') AS crm_perdidos,
  COALESCE(sum(e.valor_ganho) FILTER (
    WHERE e.event_code = 'ganho' OR e.status = 'won'
  ), 0::numeric) AS receita
FROM v_crm_events_enriched e
GROUP BY e.client_id, e.client_name, e.client_slug, e.event_date,
         COALESCE(e.channel_source, 'Não Identificado'::text);

GRANT SELECT ON public.v_crm_funnel_daily TO authenticated;
