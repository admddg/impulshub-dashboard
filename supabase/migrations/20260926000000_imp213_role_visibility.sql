-- IMP-213: papéis e visibilidade de dados financeiros.
--
-- public.client_users.role é a autoridade de acesso ao produto.
-- crm.tenant_memberships.role descreve o papel operacional no CRM.
-- Usuários atuais com role=viewer permanecem viewer como alias legado de gestão.
-- Atendentes mantêm Funil e Canais, mas não leem dinheiro nem por RPC nem
-- por qualquer tabela, view ou RPC financeira exposta no PostgREST.
--
-- As definições de views e funções foram extraídas do schema real de Clients_Base em
-- 20/09/2026. CREATE OR REPLACE preserva OIDs e dependências existentes.

begin;
set local lock_timeout = '5s';

alter table public.client_users drop constraint if exists client_users_role_check;
alter table public.client_users add constraint client_users_role_check
  check (role = any (array['owner','admin','manager','viewer','agency','attendant']));

create or replace function private.financial_client_ids()
returns table (client_id uuid)
language sql
stable
security definer
set search_path = ''
as $fn$
  select cb.id
    from public.clients_base cb
   where auth.role() = 'service_role'
      or exists (
        select 1
          from public.client_users cu
         where cu.user_id = auth.uid()
           and cu.is_active
           and (
             cu.role = 'agency'
             or (
               cu.client_id = cb.id
               and cu.role = any (array['agency', 'owner', 'admin', 'manager', 'viewer'])
             )
           )
      );
$fn$;

revoke all on function private.financial_client_ids() from public, anon;
grant execute on function private.financial_client_ids() to authenticated, service_role;

create or replace function private.can_view_client_financials(p_client_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(
    auth.role() = 'service_role'
    or exists (
      select 1
        from public.client_users cu
       where cu.user_id = auth.uid()
         and cu.is_active
         and (
           cu.role = 'agency'
           or (
             cu.client_id = p_client_id
             and cu.role = any (array['agency', 'owner', 'admin', 'manager', 'viewer'])
           )
         )
    ),
    false
  );
$fn$;

revoke all on function private.can_view_client_financials(uuid) from public, anon;
grant execute on function private.can_view_client_financials(uuid) to authenticated, service_role;

-- Fronteira de mídia: as políticas existentes passam a exigir papel financeiro.
ALTER POLICY meta_ads_daily_select_by_client_user
  ON public.meta_ads_daily
  USING (private.can_view_client_financials(client_id));
ALTER POLICY google_ads_daily_select_by_client_user
  ON public.google_ads_daily
  USING (private.can_view_client_financials(client_id));
ALTER POLICY google_ads_campaign_daily_select_by_client
  ON public.google_ads_campaign_daily
  USING (private.can_view_client_financials(client_id));
ALTER POLICY google_ads_keywords_daily_select_by_client_user
  ON public.google_ads_keywords_daily
  USING (private.can_view_client_financials(client_id));

-- Fontes brutas não são contratos de leitura do navegador.
REVOKE ALL ON TABLE public.external_meta_ads_raw FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.external_ga4_raw FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.external_hotmart_raw FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.stevo_events_raw FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.external_meta_ads_raw TO service_role;
GRANT SELECT ON TABLE public.external_ga4_raw TO service_role;
GRANT SELECT ON TABLE public.external_hotmart_raw TO service_role;
GRANT SELECT ON TABLE public.stevo_events_raw TO service_role;

-- events_normalized mistura operação e dinheiro. O papel authenticated recebe
-- apenas as colunas operacionais necessárias a CRM, Funil e Canais.
REVOKE SELECT ON TABLE public.events_normalized FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.events_normalized FROM authenticated;
REVOKE SELECT (
  budget_status, budget_value, closed_value, payment_method,
  normalized_payload, valor_ganho, forma_ganho, payload
) ON TABLE public.events_normalized FROM anon, authenticated;
GRANT SELECT (
  id,
  raw_event_id,
  client_id,
  ghl_location_id,
  ghl_location_name,
  client_name,
  event_code,
  event_name,
  funnel_step,
  event_datetime,
  source_system,
  source_event_type,
  source_workflow_id,
  source_workflow_name,
  contact_id,
  first_name,
  last_name,
  full_name,
  phone,
  email,
  contact_type,
  tags,
  lead_origem,
  lead_entrada,
  lead_agencias,
  conversion_source,
  entry_point_conversion_source,
  entry_point_conversion_app,
  source_type,
  source_id,
  source_url,
  source_ads,
  ad_title,
  ctwa_clid,
  ctwa_payload,
  fbp,
  fbc,
  fbclid,
  gclid,
  gbraid,
  wbraid,
  ga_client_id,
  ga_session_id,
  procedure_interest,
  procedure_closed,
  loss_reason_category,
  loss_reason_detail,
  normalization_status,
  normalization_error,
  created_at,
  updated_at,
  received_at,
  location_id,
  location_name,
  opportunity_id,
  pipeline_id,
  pipeline_name,
  pipeline_stage,
  status,
  phone_raw,
  utm_source,
  utm_medium,
  utm_campaign,
  utm_content,
  utm_term,
  procedimento_ganho,
  motivo_perda_categoria,
  motivo_perda_detalhe,
  google_campaign_id,
  google_adgroup_id,
  google_ad_id,
  google_keyword,
  google_network,
  google_device,
  produto_servico,
  categoria_produto_servico
) ON TABLE public.events_normalized TO authenticated;
GRANT SELECT ON TABLE public.events_normalized TO service_role;

CREATE OR REPLACE VIEW "public"."v_ads_spend_daily"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "md"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "md"."date",
    'meta_ads'::"text" AS "platform",
    "md"."account_id",
    "md"."account_name",
    "md"."campaign_id",
    "md"."campaign_name",
    "md"."adset_id" AS "ad_group_id",
    "md"."adset_name" AS "ad_group_name",
    "md"."ad_id",
    "md"."ad_name",
    COALESCE("md"."spend", (0)::numeric) AS "spend",
    (COALESCE("md"."impressions", 0))::bigint AS "impressions",
    (COALESCE("md"."clicks", 0))::bigint AS "clicks",
    "md"."updated_at"
   FROM ("public"."meta_ads_daily" "md"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "md"."client_id")))
UNION ALL
 SELECT "gd"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "gd"."date",
    'google_ads'::"text" AS "platform",
    "gd"."customer_id" AS "account_id",
    "gd"."customer_name" AS "account_name",
    "gd"."campaign_id",
    "gd"."campaign_name",
    "gd"."ad_group_id",
    "gd"."ad_group_name",
    "gd"."ad_id",
    "gd"."ad_name",
    COALESCE("gd"."cost", (0)::numeric) AS "spend",
    (COALESCE("gd"."impressions", 0))::bigint AS "impressions",
    (COALESCE("gd"."clicks", 0))::bigint AS "clicks",
    "gd"."updated_at"
   FROM ("public"."google_ads_daily" "gd"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "gd"."client_id")))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_ads_spend_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_ads_spend_daily TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_channel_performance_daily"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "ads_channel" AS (
         SELECT "v_ads_spend_daily"."client_id",
            "v_ads_spend_daily"."client_name",
            "v_ads_spend_daily"."client_slug",
            "v_ads_spend_daily"."date" AS "event_date",
                CASE
                    WHEN ("v_ads_spend_daily"."platform" = 'meta_ads'::"text") THEN 'Meta Ads'::"text"
                    WHEN ("v_ads_spend_daily"."platform" = 'google_ads'::"text") THEN 'Google Ads'::"text"
                    ELSE "v_ads_spend_daily"."platform"
                END AS "channel_source",
            "sum"("v_ads_spend_daily"."spend") AS "spend",
            "sum"("v_ads_spend_daily"."impressions") AS "impressions",
            "sum"("v_ads_spend_daily"."clicks") AS "clicks"
           FROM "public"."v_ads_spend_daily"
          GROUP BY "v_ads_spend_daily"."client_id", "v_ads_spend_daily"."client_name", "v_ads_spend_daily"."client_slug", "v_ads_spend_daily"."date",
                CASE
                    WHEN ("v_ads_spend_daily"."platform" = 'meta_ads'::"text") THEN 'Meta Ads'::"text"
                    WHEN ("v_ads_spend_daily"."platform" = 'google_ads'::"text") THEN 'Google Ads'::"text"
                    ELSE "v_ads_spend_daily"."platform"
                END
        ), "crm_channel" AS (
         SELECT "v_crm_funnel_daily"."client_id",
            "v_crm_funnel_daily"."client_name",
            "v_crm_funnel_daily"."client_slug",
            "v_crm_funnel_daily"."event_date",
            "v_crm_funnel_daily"."channel_source",
            "sum"("v_crm_funnel_daily"."crm_leads") AS "crm_leads",
            "sum"("v_crm_funnel_daily"."crm_primeiras_conversas") AS "crm_primeiras_conversas",
            "sum"("v_crm_funnel_daily"."crm_agendados") AS "crm_agendados",
            "sum"("v_crm_funnel_daily"."crm_ganhos") AS "crm_ganhos",
            "sum"("v_crm_funnel_daily"."crm_perdidos") AS "crm_perdidos",
            "sum"("v_crm_funnel_daily"."receita") AS "receita"
           FROM "public"."v_crm_funnel_daily"
          GROUP BY "v_crm_funnel_daily"."client_id", "v_crm_funnel_daily"."client_name", "v_crm_funnel_daily"."client_slug", "v_crm_funnel_daily"."event_date", "v_crm_funnel_daily"."channel_source"
        )
 SELECT COALESCE("a"."client_id", "c"."client_id") AS "client_id",
    COALESCE("a"."client_name", "c"."client_name") AS "client_name",
    COALESCE("a"."client_slug", "c"."client_slug") AS "client_slug",
    COALESCE("a"."event_date", "c"."event_date") AS "date",
    COALESCE("a"."channel_source", "c"."channel_source") AS "channel_source",
    COALESCE("a"."spend", (0)::numeric) AS "spend",
    COALESCE("a"."impressions", (0)::numeric) AS "impressions",
    COALESCE("a"."clicks", (0)::numeric) AS "clicks",
    COALESCE("c"."crm_leads", (0)::numeric) AS "crm_leads",
    COALESCE("c"."crm_primeiras_conversas", (0)::numeric) AS "crm_primeiras_conversas",
    COALESCE("c"."crm_agendados", (0)::numeric) AS "crm_agendados",
    COALESCE("c"."crm_ganhos", (0)::numeric) AS "crm_ganhos",
    COALESCE("c"."crm_perdidos", (0)::numeric) AS "crm_perdidos",
    COALESCE("c"."receita", (0)::numeric) AS "receita",
        CASE
            WHEN (COALESCE("c"."crm_leads", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_leads")
            ELSE NULL::numeric
        END AS "cpl_real",
        CASE
            WHEN (COALESCE("c"."crm_agendados", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_agendados")
            ELSE NULL::numeric
        END AS "custo_por_agendado",
        CASE
            WHEN (COALESCE("c"."crm_ganhos", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_ganhos")
            ELSE NULL::numeric
        END AS "cac",
        CASE
            WHEN (COALESCE("a"."spend", (0)::numeric) > (0)::numeric) THEN (COALESCE("c"."receita", (0)::numeric) / "a"."spend")
            ELSE NULL::numeric
        END AS "roas_real"
   FROM ("ads_channel" "a"
     FULL JOIN "crm_channel" "c" ON ((("c"."client_id" = "a"."client_id") AND ("c"."event_date" = "a"."event_date") AND ("c"."channel_source" = "a"."channel_source"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_channel_performance_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_channel_performance_daily TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_client_daily_pulse"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "client_id",
    "event_date" AS "date",
    "count"(*) FILTER (WHERE ("event_code" = 'lead'::"text")) AS "leads",
    "count"(*) FILTER (WHERE ("event_code" = 'primeira_conversa'::"text")) AS "conversas",
    "count"(*) FILTER (WHERE ("event_code" = 'agendado'::"text")) AS "agendados",
    "count"(*) FILTER (WHERE (("event_code" = 'ganho'::"text") OR ("status" = 'won'::"text"))) AS "ganhos",
    "count"(*) FILTER (WHERE (("event_code" = 'perdido'::"text") OR ("status" = 'lost'::"text"))) AS "perdidos",
    COALESCE("sum"("valor_ganho") FILTER (WHERE (("event_code" = 'ganho'::"text") OR ("status" = 'won'::"text"))), (0)::numeric) AS "receita"
   FROM "public"."v_crm_events_enriched"
  GROUP BY "client_id", "event_date"
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_client_daily_pulse FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_client_daily_pulse TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_client_performance_daily"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "ads" AS (
         SELECT "v_ads_spend_daily"."client_id",
            "v_ads_spend_daily"."client_name",
            "v_ads_spend_daily"."client_slug",
            "v_ads_spend_daily"."date" AS "event_date",
            "sum"("v_ads_spend_daily"."spend") AS "spend",
            "sum"("v_ads_spend_daily"."impressions") AS "impressions",
            "sum"("v_ads_spend_daily"."clicks") AS "clicks"
           FROM "public"."v_ads_spend_daily"
          GROUP BY "v_ads_spend_daily"."client_id", "v_ads_spend_daily"."client_name", "v_ads_spend_daily"."client_slug", "v_ads_spend_daily"."date"
        ), "crm" AS (
         SELECT "v_crm_funnel_daily"."client_id",
            "v_crm_funnel_daily"."client_name",
            "v_crm_funnel_daily"."client_slug",
            "v_crm_funnel_daily"."event_date",
            "sum"("v_crm_funnel_daily"."crm_leads") AS "crm_leads",
            "sum"("v_crm_funnel_daily"."crm_primeiras_conversas") AS "crm_primeiras_conversas",
            "sum"("v_crm_funnel_daily"."crm_agendados") AS "crm_agendados",
            "sum"("v_crm_funnel_daily"."crm_ganhos") AS "crm_ganhos",
            "sum"("v_crm_funnel_daily"."crm_perdidos") AS "crm_perdidos",
            "sum"("v_crm_funnel_daily"."receita") AS "receita"
           FROM "public"."v_crm_funnel_daily"
          GROUP BY "v_crm_funnel_daily"."client_id", "v_crm_funnel_daily"."client_name", "v_crm_funnel_daily"."client_slug", "v_crm_funnel_daily"."event_date"
        )
 SELECT COALESCE("a"."client_id", "c"."client_id") AS "client_id",
    COALESCE("a"."client_name", "c"."client_name") AS "client_name",
    COALESCE("a"."client_slug", "c"."client_slug") AS "client_slug",
    COALESCE("a"."event_date", "c"."event_date") AS "date",
    COALESCE("a"."spend", (0)::numeric) AS "spend",
    COALESCE("a"."impressions", (0)::numeric) AS "impressions",
    COALESCE("a"."clicks", (0)::numeric) AS "clicks",
    COALESCE("c"."crm_leads", (0)::numeric) AS "crm_leads",
    COALESCE("c"."crm_primeiras_conversas", (0)::numeric) AS "crm_primeiras_conversas",
    COALESCE("c"."crm_agendados", (0)::numeric) AS "crm_agendados",
    COALESCE("c"."crm_ganhos", (0)::numeric) AS "crm_ganhos",
    COALESCE("c"."crm_perdidos", (0)::numeric) AS "crm_perdidos",
    COALESCE("c"."receita", (0)::numeric) AS "receita",
        CASE
            WHEN (COALESCE("c"."crm_leads", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_leads")
            ELSE NULL::numeric
        END AS "cpl_real",
        CASE
            WHEN (COALESCE("c"."crm_agendados", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_agendados")
            ELSE NULL::numeric
        END AS "custo_por_agendado",
        CASE
            WHEN (COALESCE("c"."crm_ganhos", (0)::numeric) > (0)::numeric) THEN (COALESCE("a"."spend", (0)::numeric) / "c"."crm_ganhos")
            ELSE NULL::numeric
        END AS "cac",
        CASE
            WHEN (COALESCE("a"."spend", (0)::numeric) > (0)::numeric) THEN (COALESCE("c"."receita", (0)::numeric) / "a"."spend")
            ELSE NULL::numeric
        END AS "roas_real",
        CASE
            WHEN (COALESCE("c"."crm_ganhos", (0)::numeric) > (0)::numeric) THEN (COALESCE("c"."receita", (0)::numeric) / "c"."crm_ganhos")
            ELSE NULL::numeric
        END AS "ticket_medio"
   FROM ("ads" "a"
     FULL JOIN "crm" "c" ON ((("c"."client_id" = "a"."client_id") AND ("c"."event_date" = "a"."event_date"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_client_performance_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_client_performance_daily TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_client_performance_daily_v2"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "platform_daily" AS (
         SELECT "m_1"."client_id",
            "m_1"."date",
            'meta_ads'::"text" AS "platform",
            "count"(*) AS "source_rows",
            "sum"("m_1"."spend") FILTER (WHERE ("m_1"."spend" IS NOT NULL)) AS "reported_spend",
            "bool_and"(("m_1"."spend" IS NOT NULL)) AS "spend_is_complete",
            "sum"("m_1"."impressions") FILTER (WHERE ("m_1"."impressions" IS NOT NULL)) AS "reported_impressions",
            "bool_and"(("m_1"."impressions" IS NOT NULL)) AS "impressions_are_complete",
            "sum"("m_1"."clicks") FILTER (WHERE ("m_1"."clicks" IS NOT NULL)) AS "reported_clicks",
            "bool_and"(("m_1"."clicks" IS NOT NULL)) AS "clicks_are_complete",
            "max"("m_1"."updated_at") AS "latest_source_update_at"
           FROM "public"."v_meta_ads_v2" "m_1"
          GROUP BY "m_1"."client_id", "m_1"."date"
        UNION ALL
         SELECT "g"."client_id",
            "g"."date",
            'google_ads'::"text" AS "platform",
            "count"(*) AS "source_rows",
            "sum"("g"."cost") FILTER (WHERE ("g"."cost" IS NOT NULL)) AS "reported_spend",
            "bool_and"(("g"."cost" IS NOT NULL)) AS "spend_is_complete",
            "sum"("g"."impressions") FILTER (WHERE ("g"."impressions" IS NOT NULL)) AS "reported_impressions",
            "bool_and"(("g"."impressions" IS NOT NULL)) AS "impressions_are_complete",
            "sum"("g"."clicks") FILTER (WHERE ("g"."clicks" IS NOT NULL)) AS "reported_clicks",
            "bool_and"(("g"."clicks" IS NOT NULL)) AS "clicks_are_complete",
            "max"("g"."updated_at") AS "latest_source_update_at"
           FROM "public"."v_google_ads_v2" "g"
          GROUP BY "g"."client_id", "g"."date"
        ), "media" AS (
         SELECT "p"."client_id",
            "p"."date",
            "count"(*) AS "platform_rows",
            "array_agg"("p"."platform" ORDER BY "p"."platform") AS "platforms_with_delivery",
            "sum"("p"."source_rows") AS "source_rows",
            "sum"("p"."reported_spend") FILTER (WHERE ("p"."reported_spend" IS NOT NULL)) AS "reported_spend",
            "bool_and"("p"."spend_is_complete") AS "spend_is_complete",
            "sum"("p"."reported_impressions") FILTER (WHERE ("p"."reported_impressions" IS NOT NULL)) AS "reported_impressions",
            "bool_and"("p"."impressions_are_complete") AS "impressions_are_complete",
            "sum"("p"."reported_clicks") FILTER (WHERE ("p"."reported_clicks" IS NOT NULL)) AS "reported_clicks",
            "bool_and"("p"."clicks_are_complete") AS "clicks_are_complete",
            "max"("p"."latest_source_update_at") AS "latest_source_update_at"
           FROM "platform_daily" "p"
          GROUP BY "p"."client_id", "p"."date"
        ), "lead_cohort" AS (
         SELECT "l"."client_id",
            "l"."lead_date" AS "date",
            "count"(*) AS "cohort_leads",
            "count"(*) FILTER (WHERE "l"."has_primeira_conversa") AS "cohort_primeiras_conversas",
            "count"(*) FILTER (WHERE "l"."has_agendado") AS "cohort_agendados",
            "count"(*) FILTER (WHERE ("l"."attribution_platform" = 'Meta Ads'::"text")) AS "cohort_meta_ads_leads",
            "count"(*) FILTER (WHERE ("l"."attribution_platform" = 'Google Ads'::"text")) AS "cohort_google_ads_leads",
            "count"(*) FILTER (WHERE ("l"."attribution_platform" = 'Não atribuído'::"text")) AS "cohort_unattributed_leads",
            "count"(*) FILTER (WHERE ("l"."attribution_platform" = 'Conflito de atribuição'::"text")) AS "cohort_attribution_conflicts"
           FROM "public"."v_client_leads_by_stage_v2" "l"
          GROUP BY "l"."client_id", "l"."lead_date"
        ), "acquisition_outcomes" AS (
         SELECT "o"."client_id",
            "o"."contact_lead_date" AS "date",
            "count"(*) FILTER (WHERE ("o"."opportunity_status" = 'aberta'::"text")) AS "acquisition_open_opportunities",
            "count"(DISTINCT "o"."contact_id") FILTER (WHERE (("o"."opportunity_status" = 'aberta'::"text") AND ("o"."contact_id" IS NOT NULL))) AS "acquisition_open_contacts",
            "count"(*) FILTER (WHERE ("o"."opportunity_status" = 'ganha'::"text")) AS "acquisition_won_opportunities",
            "count"(DISTINCT "o"."contact_id") FILTER (WHERE (("o"."opportunity_status" = 'ganha'::"text") AND ("o"."contact_id" IS NOT NULL))) AS "acquisition_won_contacts",
            "count"(*) FILTER (WHERE ("o"."opportunity_status" = 'perdida'::"text")) AS "acquisition_lost_opportunities",
            "count"(DISTINCT "o"."contact_id") FILTER (WHERE (("o"."opportunity_status" = 'perdida'::"text") AND ("o"."contact_id" IS NOT NULL))) AS "acquisition_lost_contacts",
            "count"(*) FILTER (WHERE ("o"."opportunity_status" = 'conflito'::"text")) AS "acquisition_status_conflicts"
           FROM "public"."v_crm_opportunities_v2" "o"
          WHERE (("o"."lead_event_at" IS NOT NULL) AND ("o"."contact_lead_date" IS NOT NULL))
          GROUP BY "o"."client_id", "o"."contact_lead_date"
        ), "cohort_sales" AS (
         SELECT "s"."client_id",
            "s"."contact_lead_date" AS "date",
            "count"(*) AS "cohort_total_sales",
            "count"(DISTINCT "s"."contact_id") FILTER (WHERE ("s"."contact_id" IS NOT NULL)) AS "cohort_buying_contacts",
            "count"(*) FILTER (WHERE "s"."is_acquisition_sale") AS "cohort_acquisition_sales",
            "count"(DISTINCT "s"."contact_id") FILTER (WHERE ("s"."is_acquisition_sale" AND ("s"."contact_id" IS NOT NULL))) AS "cohort_acquisition_buying_contacts",
            "count"(*) FILTER (WHERE (NOT "s"."is_acquisition_sale")) AS "cohort_sales_without_own_lead",
            "count"(*) FILTER (WHERE "s"."has_valid_value") AS "cohort_sales_with_valid_value",
            "count"(*) FILTER (WHERE (NOT "s"."has_valid_value")) AS "cohort_sales_without_valid_value",
            "sum"("s"."valor_ganho") FILTER (WHERE "s"."has_valid_value") AS "cohort_confirmed_revenue",
            "sum"("s"."valor_ganho") FILTER (WHERE ("s"."has_valid_value" AND "s"."is_acquisition_sale")) AS "cohort_confirmed_acquisition_revenue",
            "sum"("s"."valor_ganho") FILTER (WHERE ("s"."has_valid_value" AND (NOT "s"."is_acquisition_sale"))) AS "cohort_confirmed_revenue_without_own_lead",
            "bool_and"("s"."has_valid_value") AS "cohort_revenue_is_complete",
            "bool_and"("s"."has_valid_value") FILTER (WHERE "s"."is_acquisition_sale") AS "cohort_acquisition_revenue_is_complete"
           FROM "public"."v_crm_sales_v2" "s"
          WHERE ("s"."is_cohort_linkable" AND ("s"."contact_lead_date" IS NOT NULL))
          GROUP BY "s"."client_id", "s"."contact_lead_date"
        ), "sales_activity" AS (
         SELECT "s"."client_id",
            "s"."date",
            "s"."sales" AS "closed_sales",
            "s"."buying_contacts" AS "closed_buying_contacts",
            "s"."acquisition_sales" AS "closed_acquisition_sales",
            "s"."sales_without_own_lead_but_known_contact" AS "closed_sales_without_own_lead",
            "s"."sales_without_lead_journey" AS "closed_sales_without_lead_journey",
            "s"."sales_with_valid_value" AS "closed_sales_with_valid_value",
            "s"."sales_without_valid_value" AS "closed_sales_without_valid_value",
            "s"."confirmed_revenue" AS "closed_confirmed_revenue",
            "s"."revenue_is_complete" AS "closed_revenue_is_complete",
            "s"."average_ticket_with_valid_value" AS "closed_average_ticket_with_valid_value"
           FROM "public"."v_crm_sales_daily_v2" "s"
        ), "date_spine" AS (
         SELECT "media"."client_id",
            "media"."date"
           FROM "media"
        UNION
         SELECT "lead_cohort"."client_id",
            "lead_cohort"."date"
           FROM "lead_cohort"
        UNION
         SELECT "acquisition_outcomes"."client_id",
            "acquisition_outcomes"."date"
           FROM "acquisition_outcomes"
        UNION
         SELECT "cohort_sales"."client_id",
            "cohort_sales"."date"
           FROM "cohort_sales"
        UNION
         SELECT "sales_activity"."client_id",
            "sales_activity"."date"
           FROM "sales_activity"
        )
 SELECT "ds"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "ds"."date",
    "m"."platform_rows",
    "m"."platforms_with_delivery",
    "m"."source_rows" AS "media_source_rows",
    "m"."reported_spend",
    "m"."spend_is_complete",
    "m"."reported_impressions",
    "m"."impressions_are_complete",
    "m"."reported_clicks",
    "m"."clicks_are_complete",
    "m"."latest_source_update_at",
    COALESCE("lc"."cohort_leads", (0)::bigint) AS "cohort_leads",
    COALESCE("lc"."cohort_primeiras_conversas", (0)::bigint) AS "cohort_primeiras_conversas",
    COALESCE("lc"."cohort_agendados", (0)::bigint) AS "cohort_agendados",
    COALESCE("lc"."cohort_meta_ads_leads", (0)::bigint) AS "cohort_meta_ads_leads",
    COALESCE("lc"."cohort_google_ads_leads", (0)::bigint) AS "cohort_google_ads_leads",
    (COALESCE("lc"."cohort_meta_ads_leads", (0)::bigint) + COALESCE("lc"."cohort_google_ads_leads", (0)::bigint)) AS "cohort_paid_attributed_leads",
    COALESCE("lc"."cohort_unattributed_leads", (0)::bigint) AS "cohort_unattributed_leads",
    COALESCE("lc"."cohort_attribution_conflicts", (0)::bigint) AS "cohort_attribution_conflicts",
    COALESCE("ao"."acquisition_open_opportunities", (0)::bigint) AS "acquisition_open_opportunities",
    COALESCE("ao"."acquisition_open_contacts", (0)::bigint) AS "acquisition_open_contacts",
    COALESCE("ao"."acquisition_won_opportunities", (0)::bigint) AS "acquisition_won_opportunities",
    COALESCE("ao"."acquisition_won_contacts", (0)::bigint) AS "acquisition_won_contacts",
    COALESCE("ao"."acquisition_lost_opportunities", (0)::bigint) AS "acquisition_lost_opportunities",
    COALESCE("ao"."acquisition_lost_contacts", (0)::bigint) AS "acquisition_lost_contacts",
    COALESCE("ao"."acquisition_status_conflicts", (0)::bigint) AS "acquisition_status_conflicts",
    COALESCE("cs"."cohort_total_sales", (0)::bigint) AS "cohort_total_sales",
    COALESCE("cs"."cohort_buying_contacts", (0)::bigint) AS "cohort_buying_contacts",
    COALESCE("cs"."cohort_acquisition_sales", (0)::bigint) AS "cohort_acquisition_sales",
    COALESCE("cs"."cohort_acquisition_buying_contacts", (0)::bigint) AS "cohort_acquisition_buying_contacts",
    COALESCE("cs"."cohort_sales_without_own_lead", (0)::bigint) AS "cohort_sales_without_own_lead",
    COALESCE("cs"."cohort_sales_with_valid_value", (0)::bigint) AS "cohort_sales_with_valid_value",
    COALESCE("cs"."cohort_sales_without_valid_value", (0)::bigint) AS "cohort_sales_without_valid_value",
    "cs"."cohort_confirmed_revenue",
    "cs"."cohort_confirmed_acquisition_revenue",
    "cs"."cohort_confirmed_revenue_without_own_lead",
    "cs"."cohort_revenue_is_complete",
    "cs"."cohort_acquisition_revenue_is_complete",
    COALESCE("sa"."closed_sales", (0)::bigint) AS "closed_sales",
    COALESCE("sa"."closed_buying_contacts", (0)::bigint) AS "closed_buying_contacts",
    COALESCE("sa"."closed_acquisition_sales", (0)::bigint) AS "closed_acquisition_sales",
    COALESCE("sa"."closed_sales_without_own_lead", (0)::bigint) AS "closed_sales_without_own_lead",
    COALESCE("sa"."closed_sales_without_lead_journey", (0)::bigint) AS "closed_sales_without_lead_journey",
    COALESCE("sa"."closed_sales_with_valid_value", (0)::bigint) AS "closed_sales_with_valid_value",
    COALESCE("sa"."closed_sales_without_valid_value", (0)::bigint) AS "closed_sales_without_valid_value",
    "sa"."closed_confirmed_revenue",
    "sa"."closed_revenue_is_complete",
    "sa"."closed_average_ticket_with_valid_value"
   FROM (((((("date_spine" "ds"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "ds"."client_id")))
     LEFT JOIN "media" "m" ON ((("m"."client_id" = "ds"."client_id") AND ("m"."date" = "ds"."date"))))
     LEFT JOIN "lead_cohort" "lc" ON ((("lc"."client_id" = "ds"."client_id") AND ("lc"."date" = "ds"."date"))))
     LEFT JOIN "acquisition_outcomes" "ao" ON ((("ao"."client_id" = "ds"."client_id") AND ("ao"."date" = "ds"."date"))))
     LEFT JOIN "cohort_sales" "cs" ON ((("cs"."client_id" = "ds"."client_id") AND ("cs"."date" = "ds"."date"))))
     LEFT JOIN "sales_activity" "sa" ON ((("sa"."client_id" = "ds"."client_id") AND ("sa"."date" = "ds"."date"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_client_performance_daily_v2 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_client_performance_daily_v2 TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_crm_card_history_v1"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "h"."tenant_id" AS "client_id",
    "h"."opportunity_id",
    "h"."occurred_at",
    'stage'::"text" AS "event_kind",
    "h"."transition_type",
    "h"."origin",
    "fs"."code" AS "from_stage_code",
    "fs"."label" AS "from_stage_label",
    "ts"."code" AS "to_stage_code",
    "ts"."label" AS "to_stage_label",
    NULL::"text" AS "milestone_kind",
    NULL::"text" AS "outcome",
    NULL::"text" AS "loss_reason_code",
    NULL::"text" AS "loss_reason_label",
    NULL::numeric AS "value",
    NULL::"text" AS "value_status",
    NULL::"text" AS "currency",
    NULL::"text" AS "evidence",
    "h"."reason",
    "h"."actor_profile_id",
    "ap"."display_name" AS "actor_name"
   FROM ((("crm"."opportunity_stage_history" "h"
     LEFT JOIN "crm"."global_pipeline_stages" "fs" ON (("fs"."id" = "h"."from_stage_id")))
     JOIN "crm"."global_pipeline_stages" "ts" ON (("ts"."id" = "h"."to_stage_id")))
     LEFT JOIN "crm"."profiles" "ap" ON (("ap"."id" = "h"."actor_profile_id")))
UNION ALL
 SELECT "m"."tenant_id" AS "client_id",
    "m"."opportunity_id",
    "m"."occurred_at",
    'milestone'::"text" AS "event_kind",
    NULL::"text" AS "transition_type",
    "m"."origin",
    NULL::"text" AS "from_stage_code",
    NULL::"text" AS "from_stage_label",
    NULL::"text" AS "to_stage_code",
    NULL::"text" AS "to_stage_label",
    "m"."kind" AS "milestone_kind",
    NULL::"text" AS "outcome",
    NULL::"text" AS "loss_reason_code",
    NULL::"text" AS "loss_reason_label",
    NULL::numeric AS "value",
    NULL::"text" AS "value_status",
    NULL::"text" AS "currency",
    CASE WHEN "m"."kind" = 'revenue'::"text"
              AND NOT ("m"."tenant_id" IN (SELECT "client_id" FROM private.financial_client_ids()))
         THEN NULL::"text" ELSE "m"."evidence" END AS "evidence",
    NULL::"text" AS "reason",
    "m"."actor_profile_id",
    "ap"."display_name" AS "actor_name"
   FROM ("crm"."opportunity_milestones" "m"
     LEFT JOIN "crm"."profiles" "ap" ON (("ap"."id" = "m"."actor_profile_id")))
UNION ALL
 SELECT "co"."tenant_id" AS "client_id",
    "co"."opportunity_id",
    "co"."occurred_at",
    'outcome'::"text" AS "event_kind",
    NULL::"text" AS "transition_type",
    "co"."origin",
    NULL::"text" AS "from_stage_code",
    NULL::"text" AS "from_stage_label",
    NULL::"text" AS "to_stage_code",
    NULL::"text" AS "to_stage_label",
    NULL::"text" AS "milestone_kind",
    "co"."outcome",
    "lr"."code" AS "loss_reason_code",
    "lr"."label" AS "loss_reason_label",
    CASE WHEN "co"."tenant_id" IN (SELECT "client_id" FROM private.financial_client_ids()) THEN "co"."value" ELSE NULL::numeric END AS "value",
    CASE WHEN "co"."tenant_id" IN (SELECT "client_id" FROM private.financial_client_ids()) THEN "co"."value_status" ELSE NULL::"text" END AS "value_status",
    CASE WHEN "co"."tenant_id" IN (SELECT "client_id" FROM private.financial_client_ids()) THEN "co"."currency" ELSE NULL::"text" END AS "currency",
    "co"."evidence",
    NULL::"text" AS "reason",
    "co"."actor_profile_id",
    "ap"."display_name" AS "actor_name"
   FROM (("crm"."commercial_outcomes" "co"
     LEFT JOIN "crm"."canonical_loss_reasons" "lr" ON (("lr"."id" = "co"."loss_reason_id")))
     LEFT JOIN "crm"."profiles" "ap" ON (("ap"."id" = "co"."actor_profile_id")))
        ) AS "gated"
  WHERE crm.is_member("gated"."client_id");

REVOKE ALL ON TABLE public.v_crm_card_history_v1 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_crm_card_history_v1 TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_crm_events_daily_v2"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "client_id",
    "client_name",
    "client_slug",
    "event_date" AS "date",
    "event_code",
    "event_name",
    "source_event_type",
    "count"(*) AS "event_count",
    "count"(DISTINCT "contact_id") FILTER (WHERE ("contact_id" IS NOT NULL)) AS "distinct_contacts",
    "count"(DISTINCT "opportunity_id") FILTER (WHERE (("opportunity_id" IS NOT NULL) AND (TRIM(BOTH FROM "opportunity_id") <> ''::"text"))) AS "distinct_opportunities",
    "count"(*) FILTER (WHERE "has_opportunity_id") AS "events_with_opportunity",
    "count"(*) FILTER (WHERE (NOT "has_opportunity_id")) AS "events_without_opportunity",
    "count"(*) FILTER (WHERE ("event_code" = 'ganho'::"text")) AS "gain_event_count",
    "count"(*) FILTER (WHERE "gain_has_informed_value") AS "gain_events_with_value",
    "count"(*) FILTER (WHERE "gain_has_missing_value") AS "gain_events_without_value",
    "min"("event_datetime") AS "first_event_at",
    "max"("event_datetime") AS "last_event_at",
    "max"("received_at") AS "latest_received_at"
   FROM "public"."v_crm_events_feed_v2" "e"
  GROUP BY "client_id", "client_name", "client_slug", "event_date", "event_code", "event_name", "source_event_type"
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_crm_events_daily_v2 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_crm_events_daily_v2 TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_crm_events_enriched"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "en"."id",
    "en"."raw_event_id",
    "en"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "en"."received_at",
    ((COALESCE("en"."event_datetime", "en"."received_at") AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "event_date",
    "en"."event_code",
    "en"."contact_id",
    "en"."opportunity_id",
    "en"."lead_origem",
    "en"."lead_entrada",
    "en"."source_id" AS "meta_ad_id",
    "en"."source_type",
    "en"."source_url",
    "en"."google_campaign_id",
    "en"."google_adgroup_id",
    "en"."google_ad_id",
    "en"."google_keyword",
    "en"."gclid",
    "en"."gbraid",
    "en"."wbraid",
    "public"."normalize_channel_source"("en"."lead_origem", "en"."lead_entrada", "en"."source_id", "en"."google_campaign_id", "en"."gclid", "en"."gbraid", "en"."wbraid") AS "channel_source",
    COALESCE("en"."valor_ganho", (0)::numeric) AS "valor_ganho",
    "en"."forma_ganho",
    "en"."procedimento_ganho",
    "en"."motivo_perda_categoria",
    "en"."motivo_perda_detalhe",
    NULL::"jsonb" AS "payload",
    "en"."status",
    "en"."pipeline_stage"
   FROM ("public"."events_normalized" "en"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "en"."client_id")))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_crm_events_enriched FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_crm_events_enriched TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_crm_events_feed_v2"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "en"."id" AS "event_id",
    "en"."raw_event_id",
    "en"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "en"."event_datetime",
    ("en"."event_datetime" AT TIME ZONE COALESCE(NULLIF("cb"."timezone", ''::"text"), 'America/Sao_Paulo'::"text")) AS "event_datetime_local",
    (("en"."event_datetime" AT TIME ZONE COALESCE(NULLIF("cb"."timezone", ''::"text"), 'America/Sao_Paulo'::"text")))::"date" AS "event_date",
    "en"."received_at",
    "en"."event_code",
    "en"."event_name",
    "en"."funnel_step",
    "en"."contact_id",
    "en"."opportunity_id",
    "en"."full_name",
    "en"."first_name",
    "en"."last_name",
    "en"."phone",
    "en"."email",
    "en"."pipeline_id",
    "en"."pipeline_name",
    "en"."pipeline_stage",
    "en"."status",
    "en"."lead_origem",
    "en"."lead_entrada",
    "en"."source_type",
    "en"."source_id",
    "en"."source_url",
    "en"."source_ads",
    "en"."ad_title",
    "en"."utm_source",
    "en"."utm_medium",
    "en"."utm_campaign",
    "en"."utm_content",
    "en"."utm_term",
    "en"."ctwa_clid",
    "en"."fbclid",
    "en"."gclid",
    "en"."gbraid",
    "en"."wbraid",
    "en"."google_campaign_id",
    "en"."google_adgroup_id",
    "en"."google_ad_id",
    "en"."google_keyword",
    "en"."google_network",
    "en"."google_device",
    "en"."valor_ganho",
    "en"."forma_ganho",
    "en"."produto_servico",
    "en"."categoria_produto_servico",
    "en"."procedimento_ganho",
    "en"."procedure_closed",
    "en"."motivo_perda_categoria",
    "en"."motivo_perda_detalhe",
    "en"."source_system",
    "en"."source_event_type",
    "en"."source_workflow_id",
    "en"."source_workflow_name",
    "en"."normalization_status",
    "en"."normalization_error",
    (NULLIF(TRIM(BOTH FROM "en"."opportunity_id"), ''::"text") IS NOT NULL) AS "has_opportunity_id",
    (("en"."event_code" = 'ganho'::"text") AND ("en"."valor_ganho" IS NOT NULL)) AS "gain_has_informed_value",
    (("en"."event_code" = 'ganho'::"text") AND ("en"."valor_ganho" IS NULL)) AS "gain_has_missing_value"
   FROM ("public"."events_normalized" "en"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "en"."client_id")))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_crm_events_feed_v2 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_crm_events_feed_v2 TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_crm_funnel_daily"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "leads" AS (
         SELECT "v_crm_events_enriched"."contact_id",
            "v_crm_events_enriched"."client_id",
            "v_crm_events_enriched"."client_name",
            "v_crm_events_enriched"."client_slug",
            "v_crm_events_enriched"."event_date",
            COALESCE("v_crm_events_enriched"."channel_source", 'Não Identificado'::"text") AS "channel_source"
           FROM "public"."v_crm_events_enriched"
          WHERE ("v_crm_events_enriched"."event_code" = 'lead'::"text")
        )
 SELECT "l"."client_id",
    "l"."client_name",
    "l"."client_slug",
    "l"."event_date",
    "l"."channel_source",
    "count"(*) AS "crm_leads",
    "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
           FROM "public"."v_crm_events_enriched" "e"
          WHERE (("e"."contact_id" = "l"."contact_id") AND ("e"."event_code" = 'primeira_conversa'::"text"))))) AS "crm_primeiras_conversas",
    "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
           FROM "public"."v_crm_events_enriched" "e"
          WHERE (("e"."contact_id" = "l"."contact_id") AND ("e"."event_code" = 'agendado'::"text"))))) AS "crm_agendados",
    "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
           FROM "public"."v_crm_events_enriched" "e"
          WHERE (("e"."contact_id" = "l"."contact_id") AND (("e"."event_code" = 'ganho'::"text") OR ("e"."status" = 'won'::"text") OR ("e"."pipeline_stage" ~~* '%ganho%'::"text")))))) AS "crm_ganhos",
    "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
           FROM "public"."v_crm_events_enriched" "e"
          WHERE (("e"."contact_id" = "l"."contact_id") AND (("e"."event_code" = 'perdido'::"text") OR ("e"."status" = 'lost'::"text") OR ("e"."pipeline_stage" ~~* '%perdido%'::"text")))))) AS "crm_perdidos",
    COALESCE("sum"("dedup"."valor_ganho"), (0)::numeric) AS "receita"
   FROM ("leads" "l"
     LEFT JOIN LATERAL ( SELECT DISTINCT ON ("e"."contact_id") "e"."valor_ganho"
           FROM "public"."v_crm_events_enriched" "e"
          WHERE (("e"."contact_id" = "l"."contact_id") AND (("e"."event_code" = 'ganho'::"text") OR ("e"."status" = 'won'::"text")))
          ORDER BY "e"."contact_id", "e"."received_at" DESC) "dedup" ON (true))
  GROUP BY "l"."client_id", "l"."client_name", "l"."client_slug", "l"."event_date", "l"."channel_source"
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_crm_funnel_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_crm_funnel_daily TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_crm_opportunities"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "base" AS (
         SELECT "en"."id",
            "en"."client_id",
            "cb"."client_name" AS "cb_client_name",
            "cb"."client_slug" AS "cb_client_slug",
            "en"."opportunity_id",
            COALESCE("en"."event_datetime", "en"."received_at") AS "received_at",
            ((COALESCE("en"."event_datetime", "en"."received_at") AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "event_date",
            "en"."event_code",
            "en"."status",
            "en"."pipeline_stage",
            "en"."lead_origem",
            "en"."lead_entrada",
            "en"."source_id",
            "en"."source_type",
            "en"."source_url",
            "en"."google_campaign_id",
            "en"."google_adgroup_id",
            "en"."google_ad_id",
            "en"."google_keyword",
            "en"."gclid",
            "en"."gbraid",
            "en"."wbraid",
            "en"."valor_ganho",
            "en"."forma_ganho",
            "en"."procedimento_ganho"
           FROM ("public"."events_normalized" "en"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "en"."client_id")))
          WHERE ("en"."opportunity_id" IS NOT NULL)
        ), "latest_event" AS (
         SELECT DISTINCT ON ("b"."client_id", "b"."opportunity_id") "b"."client_id",
            "b"."opportunity_id",
            "b"."event_code" AS "latest_event_code",
            "b"."status" AS "latest_status",
            "b"."pipeline_stage" AS "latest_pipeline_stage",
            "b"."received_at" AS "latest_event_at"
           FROM "base" "b"
          ORDER BY "b"."client_id", "b"."opportunity_id", "b"."received_at" DESC, "b"."id" DESC
        ), "first_source" AS (
         SELECT DISTINCT ON ("b"."client_id", "b"."opportunity_id") "b"."client_id",
            "b"."opportunity_id",
            "b"."lead_origem",
            "b"."lead_entrada",
            "b"."source_id" AS "meta_ad_id",
            "b"."source_type",
            "b"."source_url",
            "b"."google_campaign_id",
            "b"."google_adgroup_id",
            "b"."google_ad_id",
            "b"."google_keyword",
            "b"."gclid",
            "b"."gbraid",
            "b"."wbraid",
            "b"."received_at" AS "source_event_at"
           FROM "base" "b"
          WHERE ((NULLIF("b"."lead_origem", ''::"text") IS NOT NULL) OR (NULLIF("b"."lead_entrada", ''::"text") IS NOT NULL) OR ("b"."source_id" IS NOT NULL) OR ("b"."google_campaign_id" IS NOT NULL) OR ("b"."gclid" IS NOT NULL) OR ("b"."gbraid" IS NOT NULL) OR ("b"."wbraid" IS NOT NULL))
          ORDER BY "b"."client_id", "b"."opportunity_id", "b"."received_at", "b"."id"
        ), "revenue_event" AS (
         SELECT DISTINCT ON ("b"."client_id", "b"."opportunity_id") "b"."client_id",
            "b"."opportunity_id",
            "b"."valor_ganho" AS "valor_ganho_final",
            "b"."forma_ganho",
            "b"."procedimento_ganho",
            "b"."received_at" AS "revenue_event_at"
           FROM "base" "b"
          WHERE (COALESCE("b"."valor_ganho", (0)::numeric) > (0)::numeric)
          ORDER BY "b"."client_id", "b"."opportunity_id",
                CASE
                    WHEN (("b"."event_code" = 'ganho'::"text") OR ("b"."status" = 'won'::"text") OR ("b"."pipeline_stage" ~~* '%ganho%'::"text")) THEN 0
                    ELSE 1
                END, "b"."received_at" DESC, "b"."id" DESC
        ), "agg" AS (
         SELECT "b"."client_id",
            "b"."cb_client_name" AS "client_name",
            "b"."cb_client_slug" AS "client_slug",
            "b"."opportunity_id",
            "min"("b"."received_at") AS "first_event_at",
            "max"("b"."received_at") AS "last_event_at",
            "min"("b"."received_at") FILTER (WHERE ("b"."event_code" = 'primeira_conversa'::"text")) AS "primeira_conversa_at",
            "min"("b"."received_at") FILTER (WHERE ("b"."event_code" = 'agendado'::"text")) AS "agendado_at",
            "min"("b"."received_at") FILTER (WHERE (("b"."event_code" = 'ganho'::"text") OR ("b"."status" = 'won'::"text") OR ("b"."pipeline_stage" ~~* '%ganho%'::"text"))) AS "ganho_at",
            "min"("b"."received_at") FILTER (WHERE (("b"."event_code" = 'perdido'::"text") OR ("b"."status" = 'lost'::"text") OR ("b"."pipeline_stage" ~~* '%perdido%'::"text"))) AS "perdido_at",
            "bool_or"((("b"."event_code" = 'ganho'::"text") OR ("b"."status" = 'won'::"text") OR ("b"."pipeline_stage" ~~* '%ganho%'::"text"))) AS "is_won",
            "bool_or"((("b"."event_code" = 'perdido'::"text") OR ("b"."status" = 'lost'::"text") OR ("b"."pipeline_stage" ~~* '%perdido%'::"text"))) AS "is_lost",
            "count"(*) AS "eventos_total",
            "count"(*) FILTER (WHERE ("b"."event_code" = 'primeira_conversa'::"text")) AS "eventos_primeira_conversa",
            "count"(*) FILTER (WHERE ("b"."event_code" = 'agendado'::"text")) AS "eventos_agendado",
            "count"(*) FILTER (WHERE ("b"."event_code" = 'ganho'::"text")) AS "eventos_ganho",
            "count"(*) FILTER (WHERE ("b"."event_code" = 'perdido'::"text")) AS "eventos_perdido",
            "count"(*) FILTER (WHERE (COALESCE("b"."valor_ganho", (0)::numeric) > (0)::numeric)) AS "eventos_com_valor"
           FROM "base" "b"
          GROUP BY "b"."client_id", "b"."cb_client_name", "b"."cb_client_slug", "b"."opportunity_id"
        )
 SELECT "a"."client_id",
    "a"."client_name",
    "a"."client_slug",
    "a"."opportunity_id",
    "a"."first_event_at",
    (("a"."first_event_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "first_event_date",
    "a"."last_event_at",
    (("a"."last_event_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "last_event_date",
    "a"."primeira_conversa_at",
    (("a"."primeira_conversa_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "primeira_conversa_date",
    "a"."agendado_at",
    (("a"."agendado_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "agendado_date",
    "a"."ganho_at",
    (("a"."ganho_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "ganho_date",
    "a"."perdido_at",
    (("a"."perdido_at" AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date" AS "perdido_date",
    "a"."is_won",
    "a"."is_lost",
        CASE
            WHEN "a"."is_won" THEN 'won'::"text"
            WHEN "a"."is_lost" THEN 'lost'::"text"
            ELSE COALESCE("le"."latest_status", 'open'::"text")
        END AS "opportunity_status",
    "le"."latest_pipeline_stage" AS "pipeline_stage_final",
    "le"."latest_event_code",
    "fs"."lead_origem" AS "channel_source_raw",
    "fs"."lead_entrada",
    "public"."normalize_channel_source"("fs"."lead_origem", "fs"."lead_entrada", "fs"."meta_ad_id", "fs"."google_campaign_id", "fs"."gclid", "fs"."gbraid", "fs"."wbraid") AS "channel_source",
    "fs"."meta_ad_id",
    "fs"."source_type",
    "fs"."source_url",
    "fs"."google_campaign_id",
    "fs"."google_adgroup_id",
    "fs"."google_ad_id",
    "fs"."google_keyword",
    "fs"."gclid",
    "fs"."gbraid",
    "fs"."wbraid",
    COALESCE("re"."valor_ganho_final", (0)::numeric) AS "valor_ganho_final",
    "re"."forma_ganho",
    "re"."procedimento_ganho",
    "re"."revenue_event_at",
    "a"."eventos_total",
    "a"."eventos_primeira_conversa",
    "a"."eventos_agendado",
    "a"."eventos_ganho",
    "a"."eventos_perdido",
    "a"."eventos_com_valor",
        CASE
            WHEN (("a"."eventos_ganho" > 1) OR ("a"."eventos_com_valor" > 1)) THEN true
            ELSE false
        END AS "has_revenue_duplication_risk"
   FROM ((("agg" "a"
     LEFT JOIN "latest_event" "le" ON ((("le"."client_id" = "a"."client_id") AND ("le"."opportunity_id" = "a"."opportunity_id"))))
     LEFT JOIN "first_source" "fs" ON ((("fs"."client_id" = "a"."client_id") AND ("fs"."opportunity_id" = "a"."opportunity_id"))))
     LEFT JOIN "revenue_event" "re" ON ((("re"."client_id" = "a"."client_id") AND ("re"."opportunity_id" = "a"."opportunity_id"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_crm_opportunities FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_crm_opportunities TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_crm_opportunities_v2"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "opportunity_rollup" AS (
         SELECT "en"."client_id",
            TRIM(BOTH FROM "en"."opportunity_id") AS "opportunity_id",
            "count"(*) AS "total_events",
            "count"(DISTINCT "en"."contact_id") FILTER (WHERE ("en"."contact_id" IS NOT NULL)) AS "distinct_contacts",
            ("array_agg"("en"."contact_id" ORDER BY "en"."event_datetime", "en"."received_at") FILTER (WHERE ("en"."contact_id" IS NOT NULL)))[1] AS "contact_id_candidate",
            ("array_agg"("en"."full_name" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."full_name" IS NOT NULL)))[1] AS "full_name",
            ("array_agg"("en"."phone" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."phone" IS NOT NULL)))[1] AS "phone",
            ("array_agg"("en"."email" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."email" IS NOT NULL)))[1] AS "email",
            "min"("en"."event_datetime") AS "first_event_at",
            "max"("en"."event_datetime") AS "last_event_at",
            "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'lead'::"text")) AS "lead_event_at",
            "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'primeira_conversa'::"text")) AS "primeira_conversa_at",
            "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'agendado'::"text")) AS "agendado_at",
            "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'ganho'::"text")) AS "ganho_at",
            "min"("en"."event_datetime") FILTER (WHERE ("en"."event_code" = 'perdido'::"text")) AS "perdido_at",
            "count"(*) FILTER (WHERE ("en"."event_code" = 'lead'::"text")) AS "lead_event_count",
            "count"(*) FILTER (WHERE ("en"."event_code" = 'primeira_conversa'::"text")) AS "primeira_conversa_event_count",
            "count"(*) FILTER (WHERE ("en"."event_code" = 'agendado'::"text")) AS "agendado_event_count",
            "count"(*) FILTER (WHERE ("en"."event_code" = 'ganho'::"text")) AS "ganho_event_count",
            "count"(*) FILTER (WHERE ("en"."event_code" = 'perdido'::"text")) AS "perdido_event_count",
            "max"("en"."valor_ganho") FILTER (WHERE ("en"."event_code" = 'ganho'::"text")) AS "valor_ganho_candidate",
            ("array_agg"("en"."forma_ganho" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_code" = 'ganho'::"text") AND ("en"."forma_ganho" IS NOT NULL))))[1] AS "forma_ganho_candidate",
            ("array_agg"("en"."produto_servico" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_code" = 'ganho'::"text") AND ("en"."produto_servico" IS NOT NULL))))[1] AS "produto_servico_candidate",
            ("array_agg"("en"."categoria_produto_servico" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_code" = 'ganho'::"text") AND ("en"."categoria_produto_servico" IS NOT NULL))))[1] AS "categoria_produto_servico_candidate",
            ("array_agg"("en"."procedimento_ganho" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_code" = 'ganho'::"text") AND ("en"."procedimento_ganho" IS NOT NULL))))[1] AS "procedimento_ganho_candidate",
            ("array_agg"("en"."procedure_closed" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE (("en"."event_code" = 'ganho'::"text") AND ("en"."procedure_closed" IS NOT NULL))))[1] AS "procedure_closed_candidate",
            ("array_agg"("en"."event_code" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC))[1] AS "latest_event_code",
            ("array_agg"("en"."pipeline_stage" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."pipeline_stage" IS NOT NULL)))[1] AS "latest_pipeline_stage_raw",
            ("array_agg"("en"."status" ORDER BY "en"."event_datetime" DESC, "en"."received_at" DESC) FILTER (WHERE ("en"."status" IS NOT NULL)))[1] AS "latest_status_raw",
            "array_agg"(DISTINCT "en"."source_event_type" ORDER BY "en"."source_event_type") FILTER (WHERE ("en"."source_event_type" IS NOT NULL)) AS "source_event_types"
           FROM "public"."events_normalized" "en"
          WHERE (NULLIF(TRIM(BOTH FROM "en"."opportunity_id"), ''::"text") IS NOT NULL)
          GROUP BY "en"."client_id", (TRIM(BOTH FROM "en"."opportunity_id"))
        ), "prepared" AS (
         SELECT "o"."client_id",
            "o"."opportunity_id",
            "o"."total_events",
            "o"."distinct_contacts",
            "o"."contact_id_candidate",
            "o"."full_name",
            "o"."phone",
            "o"."email",
            "o"."first_event_at",
            "o"."last_event_at",
            "o"."lead_event_at",
            "o"."primeira_conversa_at",
            "o"."agendado_at",
            "o"."ganho_at",
            "o"."perdido_at",
            "o"."lead_event_count",
            "o"."primeira_conversa_event_count",
            "o"."agendado_event_count",
            "o"."ganho_event_count",
            "o"."perdido_event_count",
            "o"."valor_ganho_candidate",
            "o"."forma_ganho_candidate",
            "o"."produto_servico_candidate",
            "o"."categoria_produto_servico_candidate",
            "o"."procedimento_ganho_candidate",
            "o"."procedure_closed_candidate",
            "o"."latest_event_code",
            "o"."latest_pipeline_stage_raw",
            "o"."latest_status_raw",
            "o"."source_event_types",
                CASE
                    WHEN ("o"."distinct_contacts" = 1) THEN "o"."contact_id_candidate"
                    ELSE NULL::"text"
                END AS "contact_id",
                CASE
                    WHEN ("o"."ganho_event_count" = 1) THEN "o"."valor_ganho_candidate"
                    ELSE NULL::numeric
                END AS "valor_ganho",
                CASE
                    WHEN ("o"."ganho_event_count" = 1) THEN "o"."forma_ganho_candidate"
                    ELSE NULL::"text"
                END AS "forma_ganho",
                CASE
                    WHEN ("o"."ganho_event_count" = 1) THEN "o"."produto_servico_candidate"
                    ELSE NULL::"text"
                END AS "produto_servico",
                CASE
                    WHEN ("o"."ganho_event_count" = 1) THEN "o"."categoria_produto_servico_candidate"
                    ELSE NULL::"text"
                END AS "categoria_produto_servico",
                CASE
                    WHEN ("o"."ganho_event_count" = 1) THEN "o"."procedimento_ganho_candidate"
                    ELSE NULL::"text"
                END AS "procedimento_ganho",
                CASE
                    WHEN ("o"."ganho_event_count" = 1) THEN "o"."procedure_closed_candidate"
                    ELSE NULL::"text"
                END AS "procedure_closed"
           FROM "opportunity_rollup" "o"
        )
 SELECT "p"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "p"."opportunity_id",
    "p"."contact_id",
    "p"."full_name",
    "p"."phone",
    "p"."email",
    "p"."first_event_at",
    (("p"."first_event_at" AT TIME ZONE COALESCE(NULLIF("cb"."timezone", ''::"text"), 'America/Sao_Paulo'::"text")))::"date" AS "first_event_date",
    "p"."last_event_at",
    "p"."lead_event_at",
    "p"."primeira_conversa_at",
    "p"."agendado_at",
    "p"."ganho_at",
    "p"."perdido_at",
        CASE
            WHEN (("p"."ganho_event_count" > 0) AND ("p"."perdido_event_count" > 0)) THEN 'conflito'::"text"
            WHEN ("p"."ganho_event_count" > 0) THEN 'ganha'::"text"
            WHEN ("p"."perdido_event_count" > 0) THEN 'perdida'::"text"
            ELSE 'aberta'::"text"
        END AS "opportunity_status",
    ("p"."ganho_event_count" > 0) AS "is_won",
    ("p"."perdido_event_count" > 0) AS "is_lost",
    "p"."valor_ganho",
    "p"."forma_ganho",
    "p"."produto_servico",
    "p"."categoria_produto_servico",
    "p"."procedimento_ganho",
    "p"."procedure_closed",
    "p"."latest_event_code",
    "p"."latest_pipeline_stage_raw",
    "p"."latest_status_raw",
    "p"."total_events",
    "p"."distinct_contacts",
    "p"."lead_event_count",
    "p"."primeira_conversa_event_count",
    "p"."agendado_event_count",
    "p"."ganho_event_count",
    "p"."perdido_event_count",
    "p"."source_event_types",
    "j"."lead_at" AS "contact_lead_at",
    "j"."lead_date" AS "contact_lead_date",
    ("j"."contact_id" IS NOT NULL) AS "has_contact_lead_journey",
    "j"."attribution_platform",
    "j"."lead_origem",
    "j"."lead_entrada",
    "j"."meta_ad_id",
    "j"."google_campaign_id",
    "j"."google_adgroup_id",
    "j"."google_ad_id",
    "j"."gclid",
    "j"."gbraid",
    "j"."wbraid"
   FROM (("prepared" "p"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "p"."client_id")))
     LEFT JOIN "public"."v_client_leads_by_stage_v2" "j" ON ((("j"."client_id" = "p"."client_id") AND ("j"."contact_id" = "p"."contact_id"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_crm_opportunities_v2 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_crm_opportunities_v2 TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_crm_sales_daily_v2"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "client_id",
    "client_name",
    "client_slug",
    "ganho_date" AS "date",
    "count"(*) AS "sales",
    "count"(DISTINCT "contact_id") FILTER (WHERE ("contact_id" IS NOT NULL)) AS "buying_contacts",
    "count"(*) FILTER (WHERE "is_acquisition_sale") AS "acquisition_sales",
    "count"(*) FILTER (WHERE ((NOT "is_acquisition_sale") AND "is_cohort_linkable")) AS "sales_without_own_lead_but_known_contact",
    "count"(*) FILTER (WHERE (NOT "is_cohort_linkable")) AS "sales_without_lead_journey",
    "count"(*) FILTER (WHERE "has_valid_value") AS "sales_with_valid_value",
    "count"(*) FILTER (WHERE (NOT "has_valid_value")) AS "sales_without_valid_value",
    "sum"("valor_ganho") FILTER (WHERE "has_valid_value") AS "confirmed_revenue",
    "bool_and"("has_valid_value") AS "revenue_is_complete",
    "avg"("valor_ganho") FILTER (WHERE "has_valid_value") AS "average_ticket_with_valid_value"
   FROM "public"."v_crm_sales_v2" "s"
  GROUP BY "client_id", "client_name", "client_slug", "ganho_date"
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_crm_sales_daily_v2 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_crm_sales_daily_v2 TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_crm_sales_v2"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "o"."client_id",
    "o"."client_name",
    "o"."client_slug",
    "o"."opportunity_id",
    "o"."contact_id",
    "o"."full_name",
    "o"."phone",
    "o"."email",
    "o"."ganho_at",
    (("o"."ganho_at" AT TIME ZONE COALESCE(NULLIF("cb"."timezone", ''::"text"), 'America/Sao_Paulo'::"text")))::"date" AS "ganho_date",
    "o"."valor_ganho",
    "o"."forma_ganho",
    "o"."produto_servico",
    "o"."categoria_produto_servico",
    "o"."procedimento_ganho",
    "o"."procedure_closed",
        CASE
            WHEN ("o"."lead_event_at" IS NOT NULL) THEN 'lead_na_mesma_oportunidade'::"text"
            WHEN "o"."has_contact_lead_journey" THEN 'sem_lead_proprio_com_jornada_do_contato'::"text"
            ELSE 'sem_jornada_de_lead'::"text"
        END AS "opportunity_link_type",
    "o"."lead_event_at",
    "o"."contact_lead_at",
    "o"."contact_lead_date",
    "o"."has_contact_lead_journey",
    ("o"."lead_event_at" IS NOT NULL) AS "is_acquisition_sale",
    "o"."has_contact_lead_journey" AS "is_cohort_linkable",
    ("o"."valor_ganho" IS NOT NULL) AS "has_informed_value",
    (("o"."valor_ganho" IS NOT NULL) AND ("o"."valor_ganho" > (0)::numeric)) AS "has_valid_value",
        CASE
            WHEN ("o"."valor_ganho" IS NULL) THEN 'valor_ausente'::"text"
            WHEN ("o"."valor_ganho" <= (0)::numeric) THEN 'valor_nao_positivo'::"text"
            ELSE 'valor_valido'::"text"
        END AS "revenue_quality",
    "o"."attribution_platform",
    "o"."lead_origem",
    "o"."lead_entrada",
    "o"."meta_ad_id",
    "o"."google_campaign_id",
    "o"."google_adgroup_id",
    "o"."google_ad_id",
    "o"."gclid",
    "o"."gbraid",
    "o"."wbraid",
    "o"."latest_pipeline_stage_raw",
    "o"."latest_status_raw",
    "o"."source_event_types"
   FROM ("public"."v_crm_opportunities_v2" "o"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "o"."client_id")))
  WHERE "o"."is_won"
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_crm_sales_v2 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_crm_sales_v2 TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_google_ads_keywords_daily"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "g"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "g"."google_ads_customer_id",
    "g"."date",
    "g"."campaign_id",
    "g"."campaign_name",
    "g"."ad_group_id",
    "g"."ad_group_name",
    "g"."keyword_id",
    "g"."keyword_text",
    "g"."keyword_match_type",
    "g"."keyword_status",
    "g"."impressions",
    "g"."clicks",
    "g"."cost",
    "g"."cost_micros",
    "g"."conversions",
    "g"."conversions_value",
        CASE
            WHEN ("g"."impressions" > 0) THEN "round"(((("g"."clicks")::numeric / ("g"."impressions")::numeric) * (100)::numeric), 2)
            ELSE (0)::numeric
        END AS "ctr_percent",
        CASE
            WHEN ("g"."clicks" > 0) THEN "round"(("g"."cost" / ("g"."clicks")::numeric), 2)
            ELSE (0)::numeric
        END AS "cpc",
        CASE
            WHEN ("g"."conversions" > (0)::numeric) THEN "round"(("g"."cost" / "g"."conversions"), 2)
            ELSE (0)::numeric
        END AS "cost_per_conversion",
    "g"."synced_at",
    "g"."updated_at"
   FROM ("public"."google_ads_keywords_daily" "g"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "g"."client_id")))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_google_ads_keywords_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_google_ads_keywords_daily TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_google_ads_v2"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "g"."id",
    "g"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "g"."date",
    "g"."customer_id",
    "g"."customer_name",
    "g"."campaign_id",
    "g"."campaign_name",
    "g"."campaign_status",
    NULL::"text" AS "ad_group_id",
    NULL::"text" AS "ad_group_name",
    NULL::"text" AS "ad_group_status",
    NULL::"text" AS "ad_id",
    NULL::"text" AS "ad_name",
    NULL::"text" AS "ad_type",
    NULL::"text" AS "ad_status",
    ("g"."impressions")::integer AS "impressions",
    ("g"."clicks")::integer AS "clicks",
    "g"."cost_micros",
    "g"."cost",
    "g"."ctr",
    "g"."average_cpc_micros",
    "g"."average_cpc",
    "g"."conversions",
    "g"."conversions_value",
    "g"."all_conversions",
    "g"."all_conversions_value",
    "g"."created_at",
    "g"."updated_at"
   FROM ("public"."google_ads_campaign_daily" "g"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "g"."client_id")))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_google_ads_v2 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_google_ads_v2 TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_google_campaign_daily"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "midia" AS (
         SELECT "g"."client_id",
            "g"."date",
            "g"."customer_id",
            "g"."customer_name",
            "g"."campaign_id",
            "g"."campaign_name",
            "sum"("g"."cost") AS "spend",
            "sum"("g"."impressions") AS "impressions",
            "sum"("g"."clicks") AS "clicks",
            "sum"(COALESCE("g"."conversions", (0)::numeric)) AS "google_conversions"
           FROM "public"."google_ads_daily" "g"
          GROUP BY "g"."client_id", "g"."date", "g"."customer_id", "g"."customer_name", "g"."campaign_id", "g"."campaign_name"
        ), "leads" AS (
         SELECT "e"."client_id",
            "e"."event_date" AS "date",
            "e"."google_campaign_id",
            "e"."contact_id"
           FROM "public"."v_crm_events_enriched" "e"
          WHERE (("e"."google_campaign_id" IS NOT NULL) AND ("e"."event_code" = 'lead'::"text"))
        ), "crm" AS (
         SELECT "l"."client_id",
            "l"."date",
            "l"."google_campaign_id",
            "count"(*) AS "crm_leads",
            "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
                   FROM "public"."v_crm_events_enriched" "e2"
                  WHERE (("e2"."contact_id" = "l"."contact_id") AND ("e2"."client_id" = "l"."client_id") AND ("e2"."event_code" = 'agendado'::"text"))))) AS "crm_agendados"
           FROM "leads" "l"
          GROUP BY "l"."client_id", "l"."date", "l"."google_campaign_id"
        )
 SELECT "mid"."client_id",
    "mid"."date",
    "mid"."customer_id",
    "mid"."customer_name",
    "mid"."campaign_id",
    "mid"."campaign_name",
    "mid"."spend",
    "mid"."impressions",
    "mid"."clicks",
    "mid"."google_conversions",
    COALESCE("c"."crm_leads", (0)::bigint) AS "crm_leads",
    COALESCE("c"."crm_agendados", (0)::bigint) AS "crm_agendados"
   FROM ("midia" "mid"
     LEFT JOIN "crm" "c" ON ((("c"."client_id" = "mid"."client_id") AND ("c"."google_campaign_id" = "mid"."campaign_id") AND ("c"."date" = "mid"."date"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_google_campaign_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_google_campaign_daily TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_google_campaign_performance"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "ads" AS (
         SELECT "gd"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "gd"."customer_id" AS "account_id",
            "gd"."customer_name" AS "account_name",
            "gd"."campaign_id",
            "gd"."campaign_name",
            "sum"(COALESCE("gd"."cost", (0)::numeric)) AS "spend",
            "sum"(COALESCE("gd"."impressions", 0)) AS "impressions",
            "sum"(COALESCE("gd"."clicks", 0)) AS "clicks"
           FROM ("public"."google_ads_daily" "gd"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "gd"."client_id")))
          GROUP BY "gd"."client_id", "cb"."client_name", "cb"."client_slug", "gd"."customer_id", "gd"."customer_name", "gd"."campaign_id", "gd"."campaign_name"
        ), "crm_leads" AS (
         SELECT "v_crm_events_enriched"."client_id",
            "v_crm_events_enriched"."google_campaign_id",
            "count"(*) AS "crm_leads"
           FROM "public"."v_crm_events_enriched"
          WHERE (("v_crm_events_enriched"."event_code" = 'lead'::"text") AND ("v_crm_events_enriched"."google_campaign_id" IS NOT NULL))
          GROUP BY "v_crm_events_enriched"."client_id", "v_crm_events_enriched"."google_campaign_id"
        ), "crm_opps" AS (
         SELECT "v_crm_opportunities"."client_id",
            "v_crm_opportunities"."google_campaign_id",
            "count"(*) FILTER (WHERE ("v_crm_opportunities"."primeira_conversa_date" IS NOT NULL)) AS "crm_primeiras_conversas",
            "count"(*) FILTER (WHERE ("v_crm_opportunities"."agendado_date" IS NOT NULL)) AS "crm_agendados",
            "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_won" = true) AND ("v_crm_opportunities"."ganho_date" IS NOT NULL))) AS "crm_ganhos",
            "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_lost" = true) AND ("v_crm_opportunities"."is_won" = false) AND ("v_crm_opportunities"."perdido_date" IS NOT NULL))) AS "crm_perdidos",
            COALESCE("sum"("v_crm_opportunities"."valor_ganho_final") FILTER (WHERE ("v_crm_opportunities"."is_won" = true)), (0)::numeric) AS "receita"
           FROM "public"."v_crm_opportunities"
          WHERE ("v_crm_opportunities"."google_campaign_id" IS NOT NULL)
          GROUP BY "v_crm_opportunities"."client_id", "v_crm_opportunities"."google_campaign_id"
        )
 SELECT "a"."client_id",
    "a"."client_name",
    "a"."client_slug",
    "a"."account_id",
    "a"."account_name",
    "a"."campaign_id",
    "a"."campaign_name",
    "a"."spend",
    "a"."impressions",
    "a"."clicks",
    COALESCE("l"."crm_leads", (0)::bigint) AS "crm_leads",
    COALESCE("o"."crm_primeiras_conversas", (0)::bigint) AS "crm_primeiras_conversas",
    COALESCE("o"."crm_agendados", (0)::bigint) AS "crm_agendados",
    COALESCE("o"."crm_ganhos", (0)::bigint) AS "crm_ganhos",
    COALESCE("o"."crm_perdidos", (0)::bigint) AS "crm_perdidos",
    COALESCE("o"."receita", (0)::numeric) AS "receita",
        CASE
            WHEN (COALESCE("l"."crm_leads", (0)::bigint) > 0) THEN ("a"."spend" / ("l"."crm_leads")::numeric)
            ELSE NULL::numeric
        END AS "cpl_real",
        CASE
            WHEN (COALESCE("o"."crm_agendados", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_agendados")::numeric)
            ELSE NULL::numeric
        END AS "custo_por_agendado",
        CASE
            WHEN (COALESCE("o"."crm_ganhos", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_ganhos")::numeric)
            ELSE NULL::numeric
        END AS "cac",
        CASE
            WHEN ("a"."spend" > (0)::numeric) THEN (COALESCE("o"."receita", (0)::numeric) / "a"."spend")
            ELSE NULL::numeric
        END AS "roas_real"
   FROM (("ads" "a"
     LEFT JOIN "crm_leads" "l" ON ((("l"."client_id" = "a"."client_id") AND ("l"."google_campaign_id" = "a"."campaign_id"))))
     LEFT JOIN "crm_opps" "o" ON ((("o"."client_id" = "a"."client_id") AND ("o"."google_campaign_id" = "a"."campaign_id"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_google_campaign_performance FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_google_campaign_performance TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_google_keywords_v2"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "gk"."id",
    "gk"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "gk"."google_ads_customer_id",
    "gk"."date",
    "gk"."campaign_id",
    "gk"."campaign_name",
    "gk"."ad_group_id",
    "gk"."ad_group_name",
    "gk"."keyword_id",
    "gk"."keyword_text",
    "gk"."keyword_match_type",
    "gk"."keyword_status",
    "gk"."impressions",
    "gk"."clicks",
    "gk"."cost_micros",
    "gk"."cost",
    "gk"."ctr",
    "gk"."average_cpc_micros",
    "gk"."average_cpc",
    "gk"."conversions",
    "gk"."conversions_value",
    "gk"."synced_at",
    "gk"."created_at",
    "gk"."updated_at"
   FROM ("public"."google_ads_keywords_daily" "gk"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "gk"."client_id")))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_google_keywords_v2 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_google_keywords_v2 TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_meta_account_daily"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "midia" AS (
         SELECT "m"."client_id",
            "m"."date",
            "m"."account_id",
            "m"."account_name",
            "sum"("m"."spend") AS "spend",
            "sum"("m"."impressions") AS "impressions",
            "sum"("m"."clicks") AS "clicks",
            "sum"(COALESCE("m"."meta_platform_conversions", (0)::numeric)) AS "meta_conversions"
           FROM "public"."meta_ads_daily" "m"
          GROUP BY "m"."client_id", "m"."date", "m"."account_id", "m"."account_name"
        ), "ad_para_conta" AS (
         SELECT DISTINCT "m"."client_id",
            "m"."ad_id",
            "m"."account_id"
           FROM "public"."meta_ads_daily" "m"
        ), "leads" AS (
         SELECT "e"."client_id",
            "e"."event_date" AS "date",
            "a"."account_id",
            "e"."contact_id"
           FROM ("public"."v_crm_events_enriched" "e"
             JOIN "ad_para_conta" "a" ON ((("a"."client_id" = "e"."client_id") AND ("a"."ad_id" = "e"."meta_ad_id"))))
          WHERE (("e"."meta_ad_id" IS NOT NULL) AND ("e"."event_code" = 'lead'::"text"))
        ), "crm" AS (
         SELECT "l"."client_id",
            "l"."date",
            "l"."account_id",
            "count"(*) AS "crm_leads",
            "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
                   FROM "public"."v_crm_events_enriched" "e2"
                  WHERE (("e2"."contact_id" = "l"."contact_id") AND ("e2"."client_id" = "l"."client_id") AND ("e2"."event_code" = 'agendado'::"text"))))) AS "crm_agendados"
           FROM "leads" "l"
          GROUP BY "l"."client_id", "l"."date", "l"."account_id"
        )
 SELECT "mid"."client_id",
    "mid"."date",
    "mid"."account_id",
    "mid"."account_name",
    "mid"."spend",
    "mid"."impressions",
    "mid"."clicks",
    "mid"."meta_conversions",
    COALESCE("c"."crm_leads", (0)::bigint) AS "crm_leads",
    COALESCE("c"."crm_agendados", (0)::bigint) AS "crm_agendados"
   FROM ("midia" "mid"
     LEFT JOIN "crm" "c" ON ((("c"."client_id" = "mid"."client_id") AND ("c"."account_id" = "mid"."account_id") AND ("c"."date" = "mid"."date"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_meta_account_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_meta_account_daily TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_meta_ads_v2"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 SELECT "md"."id",
    "md"."client_id",
    "cb"."client_name",
    "cb"."client_slug",
    "md"."date",
    "md"."account_id",
    "md"."account_name",
    "md"."campaign_id",
    "md"."campaign_name",
    "md"."adset_id",
    "md"."adset_name",
    "md"."ad_id",
    "md"."ad_name",
    "md"."ad_status",
    "md"."ad_effective_status",
    "md"."creative_id",
    "md"."creative_name",
    "md"."effective_object_story_id",
    "md"."thumbnail_url",
    "md"."image_url",
    "md"."creative_url",
    "md"."destination_url",
    "md"."primary_text",
    "md"."headline",
    "md"."image_hash",
    "md"."impressions",
    "md"."reach",
    "md"."frequency",
    "md"."clicks",
    "md"."inline_link_clicks",
    "md"."unique_clicks",
    "md"."spend",
    "md"."cpc",
    "md"."cpm",
    "md"."ctr",
    "md"."leads",
    "md"."purchases",
    "md"."purchase_value",
    "md"."conversions_count",
    "md"."conversions_value",
    "md"."created_at",
    "md"."updated_at"
   FROM ("public"."meta_ads_daily" "md"
     JOIN "public"."clients_base" "cb" ON (("cb"."id" = "md"."client_id")))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_meta_ads_v2 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_meta_ads_v2 TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_meta_campaign_daily"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "midia" AS (
         SELECT "m"."client_id",
            "m"."date",
            "m"."account_id",
            "m"."account_name",
            "m"."campaign_id",
            "m"."campaign_name",
            "sum"("m"."spend") AS "spend",
            "sum"("m"."impressions") AS "impressions",
            "sum"("m"."clicks") AS "clicks",
            "sum"(COALESCE("m"."meta_platform_conversions", (0)::numeric)) AS "meta_conversions"
           FROM "public"."meta_ads_daily" "m"
          GROUP BY "m"."client_id", "m"."date", "m"."account_id", "m"."account_name", "m"."campaign_id", "m"."campaign_name"
        ), "ad_para_campanha" AS (
         SELECT DISTINCT "m"."client_id",
            "m"."ad_id",
            "m"."campaign_id"
           FROM "public"."meta_ads_daily" "m"
        ), "leads" AS (
         SELECT "e"."client_id",
            "e"."event_date" AS "date",
            "a"."campaign_id",
            "e"."contact_id"
           FROM ("public"."v_crm_events_enriched" "e"
             JOIN "ad_para_campanha" "a" ON ((("a"."client_id" = "e"."client_id") AND ("a"."ad_id" = "e"."meta_ad_id"))))
          WHERE (("e"."meta_ad_id" IS NOT NULL) AND ("e"."event_code" = 'lead'::"text"))
        ), "crm" AS (
         SELECT "l"."client_id",
            "l"."date",
            "l"."campaign_id",
            "count"(*) AS "crm_leads",
            "count"(*) FILTER (WHERE (EXISTS ( SELECT 1
                   FROM "public"."v_crm_events_enriched" "e2"
                  WHERE (("e2"."contact_id" = "l"."contact_id") AND ("e2"."client_id" = "l"."client_id") AND ("e2"."event_code" = 'agendado'::"text"))))) AS "crm_agendados"
           FROM "leads" "l"
          GROUP BY "l"."client_id", "l"."date", "l"."campaign_id"
        )
 SELECT "mid"."client_id",
    "mid"."date",
    "mid"."account_id",
    "mid"."account_name",
    "mid"."campaign_id",
    "mid"."campaign_name",
    "mid"."spend",
    "mid"."impressions",
    "mid"."clicks",
    "mid"."meta_conversions",
    COALESCE("c"."crm_leads", (0)::bigint) AS "crm_leads",
    COALESCE("c"."crm_agendados", (0)::bigint) AS "crm_agendados"
   FROM ("midia" "mid"
     LEFT JOIN "crm" "c" ON ((("c"."client_id" = "mid"."client_id") AND ("c"."campaign_id" = "mid"."campaign_id") AND ("c"."date" = "mid"."date"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_meta_campaign_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_meta_campaign_daily TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_meta_campaign_performance"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "ads" AS (
         SELECT "v_ads_spend_daily"."client_id",
            "v_ads_spend_daily"."client_name",
            "v_ads_spend_daily"."client_slug",
            "v_ads_spend_daily"."account_id",
            "v_ads_spend_daily"."campaign_id",
            "v_ads_spend_daily"."campaign_name",
            "v_ads_spend_daily"."ad_group_id" AS "adset_id",
            "v_ads_spend_daily"."ad_group_name" AS "adset_name",
            "v_ads_spend_daily"."ad_id",
            "v_ads_spend_daily"."ad_name",
            "sum"("v_ads_spend_daily"."spend") AS "spend",
            "sum"("v_ads_spend_daily"."impressions") AS "impressions",
            "sum"("v_ads_spend_daily"."clicks") AS "clicks"
           FROM "public"."v_ads_spend_daily"
          WHERE ("v_ads_spend_daily"."platform" = 'meta_ads'::"text")
          GROUP BY "v_ads_spend_daily"."client_id", "v_ads_spend_daily"."client_name", "v_ads_spend_daily"."client_slug", "v_ads_spend_daily"."account_id", "v_ads_spend_daily"."campaign_id", "v_ads_spend_daily"."campaign_name", "v_ads_spend_daily"."ad_group_id", "v_ads_spend_daily"."ad_group_name", "v_ads_spend_daily"."ad_id", "v_ads_spend_daily"."ad_name"
        ), "crm_leads" AS (
         SELECT "v_crm_events_enriched"."client_id",
            "v_crm_events_enriched"."meta_ad_id" AS "ad_id",
            "count"(*) AS "crm_leads"
           FROM "public"."v_crm_events_enriched"
          WHERE (("v_crm_events_enriched"."event_code" = 'lead'::"text") AND ("v_crm_events_enriched"."meta_ad_id" IS NOT NULL))
          GROUP BY "v_crm_events_enriched"."client_id", "v_crm_events_enriched"."meta_ad_id"
        ), "crm_opps" AS (
         SELECT "v_crm_opportunities"."client_id",
            "v_crm_opportunities"."meta_ad_id" AS "ad_id",
            "count"(*) FILTER (WHERE ("v_crm_opportunities"."primeira_conversa_date" IS NOT NULL)) AS "crm_primeiras_conversas",
            "count"(*) FILTER (WHERE ("v_crm_opportunities"."agendado_date" IS NOT NULL)) AS "crm_agendados",
            "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_won" = true) AND ("v_crm_opportunities"."ganho_date" IS NOT NULL))) AS "crm_ganhos",
            "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_lost" = true) AND ("v_crm_opportunities"."is_won" = false) AND ("v_crm_opportunities"."perdido_date" IS NOT NULL))) AS "crm_perdidos",
            COALESCE("sum"("v_crm_opportunities"."valor_ganho_final") FILTER (WHERE ("v_crm_opportunities"."is_won" = true)), (0)::numeric) AS "receita"
           FROM "public"."v_crm_opportunities"
          WHERE ("v_crm_opportunities"."meta_ad_id" IS NOT NULL)
          GROUP BY "v_crm_opportunities"."client_id", "v_crm_opportunities"."meta_ad_id"
        )
 SELECT "a"."client_id",
    "a"."client_name",
    "a"."client_slug",
    "a"."account_id",
    "a"."campaign_id",
    "a"."campaign_name",
    "a"."adset_id",
    "a"."adset_name",
    "a"."ad_id",
    "a"."ad_name",
    "a"."spend",
    "a"."impressions",
    "a"."clicks",
    COALESCE("l"."crm_leads", (0)::bigint) AS "crm_leads",
    COALESCE("o"."crm_primeiras_conversas", (0)::bigint) AS "crm_primeiras_conversas",
    COALESCE("o"."crm_agendados", (0)::bigint) AS "crm_agendados",
    COALESCE("o"."crm_ganhos", (0)::bigint) AS "crm_ganhos",
    COALESCE("o"."crm_perdidos", (0)::bigint) AS "crm_perdidos",
    COALESCE("o"."receita", (0)::numeric) AS "receita",
        CASE
            WHEN (COALESCE("l"."crm_leads", (0)::bigint) > 0) THEN ("a"."spend" / ("l"."crm_leads")::numeric)
            ELSE NULL::numeric
        END AS "cpl_real",
        CASE
            WHEN (COALESCE("o"."crm_agendados", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_agendados")::numeric)
            ELSE NULL::numeric
        END AS "custo_por_agendado",
        CASE
            WHEN (COALESCE("o"."crm_ganhos", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_ganhos")::numeric)
            ELSE NULL::numeric
        END AS "cac",
        CASE
            WHEN ("a"."spend" > (0)::numeric) THEN (COALESCE("o"."receita", (0)::numeric) / "a"."spend")
            ELSE NULL::numeric
        END AS "roas_real"
   FROM (("ads" "a"
     LEFT JOIN "crm_leads" "l" ON ((("l"."client_id" = "a"."client_id") AND ("l"."ad_id" = "a"."ad_id"))))
     LEFT JOIN "crm_opps" "o" ON ((("o"."client_id" = "a"."client_id") AND ("o"."ad_id" = "a"."ad_id"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_meta_campaign_performance FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_meta_campaign_performance TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_meta_creative_daily"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "midia" AS (
         SELECT "m"."client_id",
            "m"."date",
            "m"."account_id",
            "m"."campaign_id",
            "m"."campaign_name",
            "m"."adset_id",
            "m"."adset_name",
            "m"."ad_id",
            "m"."ad_name",
            "m"."creative_id",
            "m"."creative_name",
            "m"."thumbnail_url",
            "m"."image_url",
            "m"."creative_url",
            "m"."video_id",
            "m"."headline",
            "m"."primary_text",
            "m"."spend",
            "m"."impressions",
            "m"."clicks",
            COALESCE("m"."meta_platform_conversions", (0)::numeric) AS "meta_conversions"
           FROM "public"."meta_ads_daily" "m"
        ), "crm" AS (
         SELECT "e"."client_id",
            "e"."event_date" AS "date",
            "e"."meta_ad_id" AS "ad_id",
            "count"(*) FILTER (WHERE ("e"."event_code" = 'lead'::"text")) AS "crm_leads",
            "count"(*) FILTER (WHERE ("e"."event_code" = 'agendado'::"text")) AS "crm_agendados",
            "count"(*) FILTER (WHERE (("e"."event_code" = 'ganho'::"text") OR ("e"."status" = 'won'::"text"))) AS "crm_ganhos",
            COALESCE("sum"("e"."valor_ganho") FILTER (WHERE (("e"."event_code" = 'ganho'::"text") OR ("e"."status" = 'won'::"text"))), (0)::numeric) AS "receita"
           FROM "public"."v_crm_events_enriched" "e"
          WHERE ("e"."meta_ad_id" IS NOT NULL)
          GROUP BY "e"."client_id", "e"."event_date", "e"."meta_ad_id"
        )
 SELECT "mid"."client_id",
    "mid"."date",
    "mid"."account_id",
    "mid"."campaign_id",
    "mid"."campaign_name",
    "mid"."adset_id",
    "mid"."adset_name",
    "mid"."ad_id",
    "mid"."ad_name",
    "mid"."creative_id",
    "mid"."creative_name",
    "mid"."thumbnail_url",
    "mid"."image_url",
    "mid"."creative_url",
    "mid"."video_id",
    "mid"."headline",
    "mid"."primary_text",
    "mid"."spend",
    "mid"."impressions",
    "mid"."clicks",
    "mid"."meta_conversions",
    COALESCE("c"."crm_leads", (0)::bigint) AS "crm_leads",
    COALESCE("c"."crm_agendados", (0)::bigint) AS "crm_agendados",
    COALESCE("c"."crm_ganhos", (0)::bigint) AS "crm_ganhos",
    COALESCE("c"."receita", (0)::numeric) AS "receita"
   FROM ("midia" "mid"
     LEFT JOIN "crm" "c" ON ((("c"."client_id" = "mid"."client_id") AND ("c"."ad_id" = "mid"."ad_id") AND ("c"."date" = "mid"."date"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_meta_creative_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_meta_creative_daily TO authenticated, service_role;

CREATE OR REPLACE VIEW "public"."v_meta_creative_performance"
WITH ("security_barrier"='true', "security_invoker"='false') AS
 SELECT "gated".*
   FROM (
 WITH "ads" AS (
         SELECT "md"."client_id",
            "cb"."client_name",
            "cb"."client_slug",
            "md"."account_id",
            "md"."campaign_id",
            "md"."campaign_name",
            "md"."adset_id",
            "md"."adset_name",
            "md"."ad_id",
            "md"."ad_name",
            "md"."creative_id",
            "max"("md"."creative_name") AS "creative_name",
            "max"("md"."thumbnail_url") AS "thumbnail_url",
            "max"("md"."image_url") AS "image_url",
            "max"("md"."creative_url") AS "creative_url",
            "max"("md"."destination_url") AS "destination_url",
            "max"("md"."primary_text") AS "primary_text",
            "max"("md"."headline") AS "headline",
            "max"("md"."video_id") AS "video_id",
            "sum"(COALESCE("md"."spend", (0)::numeric)) AS "spend",
            "sum"(COALESCE("md"."impressions", 0)) AS "impressions",
            "sum"(COALESCE("md"."clicks", 0)) AS "clicks",
            "sum"(COALESCE("md"."inline_link_clicks", 0)) AS "inline_link_clicks"
           FROM ("public"."meta_ads_daily" "md"
             JOIN "public"."clients_base" "cb" ON (("cb"."id" = "md"."client_id")))
          GROUP BY "md"."client_id", "cb"."client_name", "cb"."client_slug", "md"."account_id", "md"."campaign_id", "md"."campaign_name", "md"."adset_id", "md"."adset_name", "md"."ad_id", "md"."ad_name", "md"."creative_id"
        ), "crm_leads" AS (
         SELECT "v_crm_events_enriched"."client_id",
            "v_crm_events_enriched"."meta_ad_id" AS "ad_id",
            "count"(*) AS "crm_leads"
           FROM "public"."v_crm_events_enriched"
          WHERE (("v_crm_events_enriched"."event_code" = 'lead'::"text") AND ("v_crm_events_enriched"."meta_ad_id" IS NOT NULL))
          GROUP BY "v_crm_events_enriched"."client_id", "v_crm_events_enriched"."meta_ad_id"
        ), "crm_opps" AS (
         SELECT "v_crm_opportunities"."client_id",
            "v_crm_opportunities"."meta_ad_id" AS "ad_id",
            "count"(*) FILTER (WHERE ("v_crm_opportunities"."primeira_conversa_date" IS NOT NULL)) AS "crm_primeiras_conversas",
            "count"(*) FILTER (WHERE ("v_crm_opportunities"."agendado_date" IS NOT NULL)) AS "crm_agendados",
            "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_won" = true) AND ("v_crm_opportunities"."ganho_date" IS NOT NULL))) AS "crm_ganhos",
            "count"(*) FILTER (WHERE (("v_crm_opportunities"."is_lost" = true) AND ("v_crm_opportunities"."is_won" = false) AND ("v_crm_opportunities"."perdido_date" IS NOT NULL))) AS "crm_perdidos",
            COALESCE("sum"("v_crm_opportunities"."valor_ganho_final") FILTER (WHERE ("v_crm_opportunities"."is_won" = true)), (0)::numeric) AS "receita"
           FROM "public"."v_crm_opportunities"
          WHERE ("v_crm_opportunities"."meta_ad_id" IS NOT NULL)
          GROUP BY "v_crm_opportunities"."client_id", "v_crm_opportunities"."meta_ad_id"
        )
 SELECT "a"."client_id",
    "a"."client_name",
    "a"."client_slug",
    "a"."account_id",
    "a"."campaign_id",
    "a"."campaign_name",
    "a"."adset_id",
    "a"."adset_name",
    "a"."ad_id",
    "a"."ad_name",
    "a"."creative_id",
    "a"."creative_name",
    "a"."thumbnail_url",
    "a"."image_url",
    "a"."creative_url",
    "a"."destination_url",
    "a"."primary_text",
    "a"."headline",
    "a"."video_id",
    "a"."spend",
    "a"."impressions",
    "a"."clicks",
    "a"."inline_link_clicks",
    COALESCE("l"."crm_leads", (0)::bigint) AS "crm_leads",
    COALESCE("o"."crm_primeiras_conversas", (0)::bigint) AS "crm_primeiras_conversas",
    COALESCE("o"."crm_agendados", (0)::bigint) AS "crm_agendados",
    COALESCE("o"."crm_ganhos", (0)::bigint) AS "crm_ganhos",
    COALESCE("o"."crm_perdidos", (0)::bigint) AS "crm_perdidos",
    COALESCE("o"."receita", (0)::numeric) AS "receita",
        CASE
            WHEN (COALESCE("l"."crm_leads", (0)::bigint) > 0) THEN ("a"."spend" / ("l"."crm_leads")::numeric)
            ELSE NULL::numeric
        END AS "cpl_real",
        CASE
            WHEN (COALESCE("o"."crm_agendados", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_agendados")::numeric)
            ELSE NULL::numeric
        END AS "custo_por_agendado",
        CASE
            WHEN (COALESCE("o"."crm_ganhos", (0)::bigint) > 0) THEN ("a"."spend" / ("o"."crm_ganhos")::numeric)
            ELSE NULL::numeric
        END AS "cac",
        CASE
            WHEN ("a"."spend" > (0)::numeric) THEN (COALESCE("o"."receita", (0)::numeric) / "a"."spend")
            ELSE NULL::numeric
        END AS "roas_real"
   FROM (("ads" "a"
     LEFT JOIN "crm_leads" "l" ON ((("l"."client_id" = "a"."client_id") AND ("l"."ad_id" = "a"."ad_id"))))
     LEFT JOIN "crm_opps" "o" ON ((("o"."client_id" = "a"."client_id") AND ("o"."ad_id" = "a"."ad_id"))))
        ) AS "gated"
  WHERE "gated"."client_id" IN (SELECT "client_id" FROM private.financial_client_ids());

REVOKE ALL ON TABLE public.v_meta_creative_performance FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.v_meta_creative_performance TO authenticated, service_role;

CREATE OR REPLACE FUNCTION "public"."get_client_overview_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date") RETURNS TABLE("client_id" "uuid", "client_name" "text", "client_slug" "text", "period_start" "date", "period_end" "date", "media_days" bigint, "investment" numeric, "investment_is_complete" boolean, "leads" bigint, "paid_attributed_leads" bigint, "meta_ads_leads" bigint, "google_ads_leads" bigint, "unattributed_leads" bigint, "attribution_conflicts" bigint, "primeiras_conversas" bigint, "agendados" bigint, "crm_ganhos" bigint, "acquisition_buying_contacts" bigint, "acquisition_sales" bigint, "cohort_total_sales" bigint, "cohort_sales_without_own_lead" bigint, "acquisition_revenue" numeric, "total_cohort_revenue" numeric, "acquisition_revenue_is_complete" boolean, "cohort_revenue_is_complete" boolean, "closed_sales" bigint, "closed_buying_contacts" bigint, "closed_revenue" numeric, "closed_revenue_is_complete" boolean, "cpl_paid" numeric, "cac_acquisition" numeric, "roas_acquisition" numeric, "roas_total_cohort" numeric)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$

with period_data as (

  select *
  from public.v_client_performance_daily_v2 p

  where p.client_id = p_client_id
    and p.date between p_start_date and p_end_date
),

aggregated as (

  select

    count(*) filter (
      where platform_rows is not null
    )::bigint as media_days,

    sum(reported_spend)
      as investment,

    case
      when count(*) filter (
        where platform_rows is not null
      ) = 0
        then null

      else bool_and(spend_is_complete) filter (
        where platform_rows is not null
      )
    end as investment_is_complete,

    coalesce(
      sum(cohort_leads),
      0
    )::bigint as leads,

    coalesce(
      sum(cohort_paid_attributed_leads),
      0
    )::bigint as paid_attributed_leads,

    coalesce(
      sum(cohort_meta_ads_leads),
      0
    )::bigint as meta_ads_leads,

    coalesce(
      sum(cohort_google_ads_leads),
      0
    )::bigint as google_ads_leads,

    coalesce(
      sum(cohort_unattributed_leads),
      0
    )::bigint as unattributed_leads,

    coalesce(
      sum(cohort_attribution_conflicts),
      0
    )::bigint as attribution_conflicts,

    coalesce(
      sum(cohort_primeiras_conversas),
      0
    )::bigint as primeiras_conversas,

    coalesce(
      sum(cohort_agendados),
      0
    )::bigint as agendados,

    coalesce(
      sum(acquisition_won_contacts),
      0
    )::bigint as acquisition_buying_contacts,

    coalesce(
      sum(acquisition_won_opportunities),
      0
    )::bigint as acquisition_sales,

    coalesce(
      sum(cohort_total_sales),
      0
    )::bigint as cohort_total_sales,

    coalesce(
      sum(cohort_sales_without_own_lead),
      0
    )::bigint as cohort_sales_without_own_lead,

    sum(cohort_confirmed_acquisition_revenue)
      as acquisition_revenue,

    sum(cohort_confirmed_revenue)
      as total_cohort_revenue,

    case
      when coalesce(
        sum(cohort_acquisition_sales),
        0
      ) = 0
        then null

      else bool_and(
        cohort_acquisition_revenue_is_complete
      ) filter (
        where cohort_acquisition_sales > 0
      )
    end as acquisition_revenue_is_complete,

    case
      when coalesce(
        sum(cohort_total_sales),
        0
      ) = 0
        then null

      else bool_and(
        cohort_revenue_is_complete
      ) filter (
        where cohort_total_sales > 0
      )
    end as cohort_revenue_is_complete,

    coalesce(
      sum(closed_sales),
      0
    )::bigint as closed_sales,

    coalesce(
      sum(closed_buying_contacts),
      0
    )::bigint as closed_buying_contacts,

    sum(closed_confirmed_revenue)
      as closed_revenue,

    case
      when coalesce(
        sum(closed_sales),
        0
      ) = 0
        then null

      else bool_and(
        closed_revenue_is_complete
      ) filter (
        where closed_sales > 0
      )
    end as closed_revenue_is_complete

  from period_data
),

journey as (

  select
    count(*) filter (
      where l.has_ganho is true
    )::bigint as crm_ganhos

  from public.v_client_leads_by_stage_v2 l

  where l.client_id = p_client_id
    and l.lead_date between p_start_date and p_end_date
),

metrics as (

  select
    a.*,

    case
      when a.investment_is_complete is true
       and a.investment is not null
       and a.paid_attributed_leads > 0
        then a.investment
             / a.paid_attributed_leads
    end as cpl_paid,

    case
      when a.investment_is_complete is true
       and a.investment is not null
       and a.acquisition_buying_contacts > 0
        then a.investment
             / a.acquisition_buying_contacts
    end as cac_acquisition,

    case
      when a.investment_is_complete is true
       and a.acquisition_revenue_is_complete is true
       and a.investment > 0
        then a.acquisition_revenue
             / a.investment
    end as roas_acquisition,

    case
      when a.investment_is_complete is true
       and a.cohort_revenue_is_complete is true
       and a.investment > 0
        then a.total_cohort_revenue
             / a.investment
    end as roas_total_cohort

  from aggregated a
)

select
  cb.id as client_id,
  cb.client_name,
  cb.client_slug,

  p_start_date as period_start,
  p_end_date as period_end,

  m.media_days,
  m.investment,
  m.investment_is_complete,

  m.leads,
  m.paid_attributed_leads,
  m.meta_ads_leads,
  m.google_ads_leads,
  m.unattributed_leads,
  m.attribution_conflicts,

  m.primeiras_conversas,
  m.agendados,
  j.crm_ganhos,

  m.acquisition_buying_contacts,
  m.acquisition_sales,

  m.cohort_total_sales,
  m.cohort_sales_without_own_lead,

  m.acquisition_revenue,
  m.total_cohort_revenue,

  m.acquisition_revenue_is_complete,
  m.cohort_revenue_is_complete,

  m.closed_sales,
  m.closed_buying_contacts,
  m.closed_revenue,
  m.closed_revenue_is_complete,

  m.cpl_paid,
  m.cac_acquisition,
  m.roas_acquisition,
  m.roas_total_cohort

from public.clients_base cb
cross join metrics m
cross join journey j

where cb.id = p_client_id
  and private.can_view_client_financials(p_client_id);

$$;

CREATE OR REPLACE FUNCTION "public"."get_meta_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text" DEFAULT 'account'::"text") RETURNS TABLE("dimension" "text", "group_id" "text", "group_name" "text", "account_id" "text", "account_name" "text", "campaign_id" "text", "campaign_name" "text", "adset_id" "text", "adset_name" "text", "ad_id" "text", "ad_name" "text", "creative_id" "text", "creative_name" "text", "thumbnail_url" "text", "image_url" "text", "creative_url" "text", "headline" "text", "primary_text" "text", "spend" numeric, "impressions" bigint, "clicks" bigint, "ctr" numeric, "cpc" numeric, "crm_leads" bigint, "crm_primeiras_conversas" bigint, "crm_agendados" bigint, "crm_ganhos" bigint, "acquisition_buying_contacts" bigint, "acquisition_sales" bigint, "acquisition_revenue" numeric, "acquisition_sales_with_valid_value" bigint, "acquisition_sales_without_valid_value" bigint, "acquisition_revenue_is_complete" boolean, "cohort_buying_contacts" bigint, "cohort_total_sales" bigint, "cohort_sales_without_own_lead" bigint, "total_cohort_revenue" numeric, "cohort_sales_with_valid_value" bigint, "cohort_sales_without_valid_value" bigint, "cohort_revenue_is_complete" boolean, "cpl" numeric, "cost_per_agendado" numeric, "cost_per_gain" numeric, "cac_acquisition" numeric, "roas_acquisition" numeric, "roas_total_cohort" numeric)
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public', 'pg_temp'
    SET "work_mem" TO '16MB'
    AS $$
#variable_conflict use_column
begin
  if not private.can_view_client_financials(p_client_id) then
    raise exception 'Acesso financeiro não autorizado.' using errcode = '42501';
  end if;

  if p_client_id is null then
    raise exception using
      errcode = '22004',
      message = 'p_client_id não pode ser NULL';
  end if;

  if p_start_date is null or p_end_date is null then
    raise exception using
      errcode = '22004',
      message = 'p_start_date e p_end_date não podem ser NULL';
  end if;

  if p_start_date > p_end_date then
    raise exception using
      errcode = '22007',
      message = 'p_start_date não pode ser posterior a p_end_date';
  end if;

  if p_dimension is null
     or p_dimension not in ('account', 'campaign', 'adset', 'ad', 'creative') then
    raise exception using
      errcode = '22023',
      message = format(
        'p_dimension inválida: %s. Valores aceitos: account, campaign, adset, ad, creative',
        coalesce(p_dimension, 'NULL')
      );
  end if;

  return query
  with
  -- --------------------------------------------------------------------------
  -- Mapa histórico e determinístico do anúncio.
  -- Para creative, aplica a decisão oficial: vale o último criativo conhecido.
  -- --------------------------------------------------------------------------
  ad_hierarchy_latest as (
    select distinct on (m.ad_id)
      m.ad_id,
      m.ad_name,
      m.account_id,
      m.account_name,
      m.campaign_id,
      m.campaign_name,
      m.adset_id,
      m.adset_name,
      m.creative_id,
      m.creative_name,
      m.thumbnail_url,
      m.image_url,
      m.creative_url,
      m.headline,
      m.primary_text,
      m.date,
      m.updated_at,
      m.created_at,
      m.id
    from public.v_meta_ads_v2 m
    where m.client_id = p_client_id
      and m.ad_id is not null
    order by
      m.ad_id,
      m.date desc nulls last,
      m.updated_at desc nulls last,
      m.created_at desc nulls last,
      m.id desc
  ),

  -- --------------------------------------------------------------------------
  -- Mídia real do período. No nível creative, usa o creative_id real da linha.
  -- --------------------------------------------------------------------------
  media_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(m.account_id, '__meta_unmapped_account__')
        when 'campaign' then
          case
            when m.campaign_id is null then '__meta_unmapped_campaign__'
            else concat_ws('|', coalesce(m.account_id, '__no_account__'), m.campaign_id)
          end
        when 'adset' then
          case
            when m.adset_id is null then '__meta_unmapped_adset__'
            else concat_ws(
              '|',
              coalesce(m.account_id, '__no_account__'),
              coalesce(m.campaign_id, '__no_campaign__'),
              m.adset_id
            )
          end
        when 'ad' then
          coalesce(m.ad_id, '__meta_unmapped_ad__')
        when 'creative' then
          coalesce(m.creative_id, '__meta_unmapped_creative__')
      end as group_id,

      case p_dimension
        when 'account' then coalesce(m.account_name, m.account_id, 'Conta não identificada')
        when 'campaign' then coalesce(m.campaign_name, m.campaign_id, 'Campanha não identificada')
        when 'adset' then coalesce(m.adset_name, m.adset_id, 'Conjunto não identificado')
        when 'ad' then coalesce(m.ad_name, m.ad_id, 'Anúncio não identificado')
        when 'creative' then coalesce(
          m.headline,
          m.creative_name,
          m.creative_id,
          'Sem criativo identificado'
        )
      end as group_name,

      m.account_id,
      m.account_name,

      case when p_dimension in ('campaign', 'adset', 'ad') then m.campaign_id end as campaign_id,
      case when p_dimension in ('campaign', 'adset', 'ad') then m.campaign_name end as campaign_name,

      case when p_dimension in ('adset', 'ad') then m.adset_id end as adset_id,
      case when p_dimension in ('adset', 'ad') then m.adset_name end as adset_name,

      case when p_dimension in ('ad', 'creative') then m.ad_id end as ad_id,
      case when p_dimension in ('ad', 'creative') then m.ad_name end as ad_name,

      case when p_dimension = 'creative' then m.creative_id end as creative_id,
      case when p_dimension = 'creative' then m.creative_name end as creative_name,

      case when p_dimension = 'creative' then m.thumbnail_url end as thumbnail_url,
      case when p_dimension = 'creative' then m.image_url end as image_url,
      case when p_dimension = 'creative' then m.creative_url end as creative_url,
      case when p_dimension = 'creative' then m.headline end as headline,
      case when p_dimension = 'creative' then m.primary_text end as primary_text,

      m.date::timestamp without time zone as sort_at,
      1::integer as source_priority,

      coalesce(m.spend, 0::numeric) as spend,
      coalesce(m.impressions, 0)::bigint as impressions,
      coalesce(m.clicks, 0)::bigint as clicks

    from public.v_meta_ads_v2 m
    where m.client_id = p_client_id
      and m.date between p_start_date and p_end_date
  ),

  -- --------------------------------------------------------------------------
  -- Leads da coorte e respectivos marcos cumulativos.
  -- --------------------------------------------------------------------------
  lead_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(h.account_id, '__meta_unmapped_account__')
        when 'campaign' then
          case
            when h.campaign_id is null then '__meta_unmapped_campaign__'
            else concat_ws('|', coalesce(h.account_id, '__no_account__'), h.campaign_id)
          end
        when 'adset' then
          case
            when h.adset_id is null then '__meta_unmapped_adset__'
            else concat_ws(
              '|',
              coalesce(h.account_id, '__no_account__'),
              coalesce(h.campaign_id, '__no_campaign__'),
              h.adset_id
            )
          end
        when 'ad' then
          coalesce(l.meta_ad_id, '__meta_unmapped_ad__')
        when 'creative' then
          coalesce(h.creative_id, '__meta_unmapped_creative__')
      end as group_id,

      case p_dimension
        when 'account' then coalesce(h.account_name, h.account_id, 'Conta não identificada')
        when 'campaign' then coalesce(h.campaign_name, h.campaign_id, 'Campanha não identificada')
        when 'adset' then coalesce(h.adset_name, h.adset_id, 'Conjunto não identificado')
        when 'ad' then coalesce(h.ad_name, l.meta_ad_id, 'Anúncio não identificado')
        when 'creative' then coalesce(
          h.headline,
          h.creative_name,
          h.creative_id,
          'Sem criativo identificado'
        )
      end as group_name,

      h.account_id,
      h.account_name,

      case when p_dimension in ('campaign', 'adset', 'ad') then h.campaign_id end as campaign_id,
      case when p_dimension in ('campaign', 'adset', 'ad') then h.campaign_name end as campaign_name,

      case when p_dimension in ('adset', 'ad') then h.adset_id end as adset_id,
      case when p_dimension in ('adset', 'ad') then h.adset_name end as adset_name,

      case when p_dimension in ('ad', 'creative') then l.meta_ad_id end as ad_id,
      case when p_dimension in ('ad', 'creative') then h.ad_name end as ad_name,

      case when p_dimension = 'creative' then h.creative_id end as creative_id,
      case when p_dimension = 'creative' then h.creative_name end as creative_name,

      case when p_dimension = 'creative' then h.thumbnail_url end as thumbnail_url,
      case when p_dimension = 'creative' then h.image_url end as image_url,
      case when p_dimension = 'creative' then h.creative_url end as creative_url,
      case when p_dimension = 'creative' then h.headline end as headline,
      case when p_dimension = 'creative' then h.primary_text end as primary_text,

      l.lead_date::timestamp without time zone as sort_at,
      2::integer as source_priority,

      l.contact_id,
      l.has_primeira_conversa,
      l.has_agendado,
      l.has_ganho

    from public.v_client_leads_by_stage_v2 l
    left join ad_hierarchy_latest h
      on h.ad_id = l.meta_ad_id
    where l.client_id = p_client_id
      and l.lead_date between p_start_date and p_end_date
      and l.attribution_platform = 'Meta Ads'
  ),

  -- --------------------------------------------------------------------------
  -- Vendas oficiais da coorte. Uma linha de origem = uma oportunidade ganha.
  -- --------------------------------------------------------------------------
  sale_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(h.account_id, '__meta_unmapped_account__')
        when 'campaign' then
          case
            when h.campaign_id is null then '__meta_unmapped_campaign__'
            else concat_ws('|', coalesce(h.account_id, '__no_account__'), h.campaign_id)
          end
        when 'adset' then
          case
            when h.adset_id is null then '__meta_unmapped_adset__'
            else concat_ws(
              '|',
              coalesce(h.account_id, '__no_account__'),
              coalesce(h.campaign_id, '__no_campaign__'),
              h.adset_id
            )
          end
        when 'ad' then
          coalesce(s.meta_ad_id, '__meta_unmapped_ad__')
        when 'creative' then
          coalesce(h.creative_id, '__meta_unmapped_creative__')
      end as group_id,

      case p_dimension
        when 'account' then coalesce(h.account_name, h.account_id, 'Conta não identificada')
        when 'campaign' then coalesce(h.campaign_name, h.campaign_id, 'Campanha não identificada')
        when 'adset' then coalesce(h.adset_name, h.adset_id, 'Conjunto não identificado')
        when 'ad' then coalesce(h.ad_name, s.meta_ad_id, 'Anúncio não identificado')
        when 'creative' then coalesce(
          h.headline,
          h.creative_name,
          h.creative_id,
          'Sem criativo identificado'
        )
      end as group_name,

      h.account_id,
      h.account_name,

      case when p_dimension in ('campaign', 'adset', 'ad') then h.campaign_id end as campaign_id,
      case when p_dimension in ('campaign', 'adset', 'ad') then h.campaign_name end as campaign_name,

      case when p_dimension in ('adset', 'ad') then h.adset_id end as adset_id,
      case when p_dimension in ('adset', 'ad') then h.adset_name end as adset_name,

      case when p_dimension in ('ad', 'creative') then s.meta_ad_id end as ad_id,
      case when p_dimension in ('ad', 'creative') then h.ad_name end as ad_name,

      case when p_dimension = 'creative' then h.creative_id end as creative_id,
      case when p_dimension = 'creative' then h.creative_name end as creative_name,

      case when p_dimension = 'creative' then h.thumbnail_url end as thumbnail_url,
      case when p_dimension = 'creative' then h.image_url end as image_url,
      case when p_dimension = 'creative' then h.creative_url end as creative_url,
      case when p_dimension = 'creative' then h.headline end as headline,
      case when p_dimension = 'creative' then h.primary_text end as primary_text,

      s.contact_lead_date::timestamp without time zone as sort_at,
      3::integer as source_priority,

      s.opportunity_id,
      s.contact_id,
      s.is_acquisition_sale,
      s.has_valid_value,
      s.valor_ganho

    from public.v_crm_sales_v2 s
    left join ad_hierarchy_latest h
      on h.ad_id = s.meta_ad_id
    where s.client_id = p_client_id
      and s.contact_lead_date between p_start_date and p_end_date
      and s.is_cohort_linkable is true
      and s.attribution_platform = 'Meta Ads'
  ),

  -- --------------------------------------------------------------------------
  -- Catálogo das dimensões: garante linhas de mídia e também linhas apenas CRM.
  -- --------------------------------------------------------------------------
  catalog_rows as (
    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      adset_id,
      adset_name,
      ad_id,
      ad_name,
      creative_id,
      creative_name,
      thumbnail_url,
      image_url,
      creative_url,
      headline,
      primary_text,
      sort_at,
      source_priority
    from media_tagged

    union all

    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      adset_id,
      adset_name,
      ad_id,
      ad_name,
      creative_id,
      creative_name,
      thumbnail_url,
      image_url,
      creative_url,
      headline,
      primary_text,
      sort_at,
      source_priority
    from lead_tagged

    union all

    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      adset_id,
      adset_name,
      ad_id,
      ad_name,
      creative_id,
      creative_name,
      thumbnail_url,
      image_url,
      creative_url,
      headline,
      primary_text,
      sort_at,
      source_priority
    from sale_tagged
  ),

  dimension_catalog as (
    select
      cr.group_id,
      (array_agg(cr.group_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.group_name is not null))[1] as group_name,

      (array_agg(cr.account_id order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.account_id is not null))[1] as account_id,
      (array_agg(cr.account_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.account_name is not null))[1] as account_name,

      (array_agg(cr.campaign_id order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.campaign_id is not null))[1] as campaign_id,
      (array_agg(cr.campaign_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.campaign_name is not null))[1] as campaign_name,

      (array_agg(cr.adset_id order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.adset_id is not null))[1] as adset_id,
      (array_agg(cr.adset_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.adset_name is not null))[1] as adset_name,

      (array_agg(cr.ad_id order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.ad_id is not null))[1] as ad_id,
      (array_agg(cr.ad_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.ad_name is not null))[1] as ad_name,

      (array_agg(cr.creative_id order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.creative_id is not null))[1] as creative_id,
      (array_agg(cr.creative_name order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.creative_name is not null))[1] as creative_name,

      (array_agg(cr.thumbnail_url order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.thumbnail_url is not null))[1] as thumbnail_url,
      (array_agg(cr.image_url order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.image_url is not null))[1] as image_url,
      (array_agg(cr.creative_url order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.creative_url is not null))[1] as creative_url,
      (array_agg(cr.headline order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.headline is not null))[1] as headline,
      (array_agg(cr.primary_text order by cr.sort_at desc nulls last, cr.source_priority)
        filter (where cr.primary_text is not null))[1] as primary_text

    from catalog_rows cr
    group by cr.group_id
  ),

  media_agg as (
    select
      mt.group_id,
      sum(mt.spend)::numeric as spend,
      sum(mt.impressions)::bigint as impressions,
      sum(mt.clicks)::bigint as clicks
    from media_tagged mt
    group by mt.group_id
  ),

  lead_agg as (
    select
      lt.group_id,
      count(*)::bigint as crm_leads,
      count(*) filter (where lt.has_primeira_conversa is true)::bigint
        as crm_primeiras_conversas,
      count(*) filter (where lt.has_agendado is true)::bigint
        as crm_agendados,
      count(*) filter (where lt.has_ganho is true)::bigint
        as crm_ganhos
    from lead_tagged lt
    group by lt.group_id
  ),

  sale_agg as (
    select
      st.group_id,

      count(distinct st.contact_id) filter (
        where st.is_acquisition_sale is true
      )::bigint as acquisition_buying_contacts,

      count(*) filter (
        where st.is_acquisition_sale is true
      )::bigint as acquisition_sales,

      sum(st.valor_ganho) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is true
      )::numeric as acquisition_revenue,

      count(*) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is true
      )::bigint as acquisition_sales_with_valid_value,

      count(*) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is not true
      )::bigint as acquisition_sales_without_valid_value,

      count(distinct st.contact_id)::bigint as cohort_buying_contacts,
      count(*)::bigint as cohort_total_sales,

      count(*) filter (
        where st.is_acquisition_sale is not true
      )::bigint as cohort_sales_without_own_lead,

      sum(st.valor_ganho) filter (
        where st.has_valid_value is true
      )::numeric as total_cohort_revenue,

      count(*) filter (
        where st.has_valid_value is true
      )::bigint as cohort_sales_with_valid_value,

      count(*) filter (
        where st.has_valid_value is not true
      )::bigint as cohort_sales_without_valid_value

    from sale_tagged st
    group by st.group_id
  ),

  assembled as (
    select
      dc.group_id,
      dc.group_name,
      dc.account_id,
      dc.account_name,
      dc.campaign_id,
      dc.campaign_name,
      dc.adset_id,
      dc.adset_name,
      dc.ad_id,
      dc.ad_name,
      dc.creative_id,
      dc.creative_name,
      dc.thumbnail_url,
      dc.image_url,
      dc.creative_url,
      dc.headline,
      dc.primary_text,

      coalesce(ma.spend, 0::numeric) as spend,
      coalesce(ma.impressions, 0)::bigint as impressions,
      coalesce(ma.clicks, 0)::bigint as clicks,

      coalesce(la.crm_leads, 0)::bigint as crm_leads,
      coalesce(la.crm_primeiras_conversas, 0)::bigint as crm_primeiras_conversas,
      coalesce(la.crm_agendados, 0)::bigint as crm_agendados,
      coalesce(la.crm_ganhos, 0)::bigint as crm_ganhos,

      coalesce(sa.acquisition_buying_contacts, 0)::bigint
        as acquisition_buying_contacts,
      coalesce(sa.acquisition_sales, 0)::bigint as acquisition_sales,
      sa.acquisition_revenue,
      coalesce(sa.acquisition_sales_with_valid_value, 0)::bigint
        as acquisition_sales_with_valid_value,
      coalesce(sa.acquisition_sales_without_valid_value, 0)::bigint
        as acquisition_sales_without_valid_value,

      coalesce(sa.cohort_buying_contacts, 0)::bigint as cohort_buying_contacts,
      coalesce(sa.cohort_total_sales, 0)::bigint as cohort_total_sales,
      coalesce(sa.cohort_sales_without_own_lead, 0)::bigint
        as cohort_sales_without_own_lead,
      sa.total_cohort_revenue,
      coalesce(sa.cohort_sales_with_valid_value, 0)::bigint
        as cohort_sales_with_valid_value,
      coalesce(sa.cohort_sales_without_valid_value, 0)::bigint
        as cohort_sales_without_valid_value

    from dimension_catalog dc
    left join media_agg ma on ma.group_id = dc.group_id
    left join lead_agg la on la.group_id = dc.group_id
    left join sale_agg sa on sa.group_id = dc.group_id
  )

  select
    p_dimension::text as dimension,
    a.group_id,
    a.group_name,

    a.account_id,
    a.account_name,
    a.campaign_id,
    a.campaign_name,
    a.adset_id,
    a.adset_name,
    a.ad_id,
    a.ad_name,
    a.creative_id,
    a.creative_name,

    a.thumbnail_url,
    a.image_url,
    a.creative_url,
    a.headline,
    a.primary_text,

    a.spend,
    a.impressions,
    a.clicks,

    case
      when a.impressions > 0
        then a.clicks::numeric / a.impressions::numeric
    end as ctr,

    case
      when a.clicks > 0
        then a.spend / a.clicks::numeric
    end as cpc,

    a.crm_leads,
    a.crm_primeiras_conversas,
    a.crm_agendados,
    a.crm_ganhos,

    a.acquisition_buying_contacts,
    a.acquisition_sales,
    a.acquisition_revenue,
    a.acquisition_sales_with_valid_value,
    a.acquisition_sales_without_valid_value,

    case
      when a.acquisition_sales = 0 then null
      when a.acquisition_sales_without_valid_value = 0 then true
      else false
    end as acquisition_revenue_is_complete,

    a.cohort_buying_contacts,
    a.cohort_total_sales,
    a.cohort_sales_without_own_lead,
    a.total_cohort_revenue,
    a.cohort_sales_with_valid_value,
    a.cohort_sales_without_valid_value,

    case
      when a.cohort_total_sales = 0 then null
      when a.cohort_sales_without_valid_value = 0 then true
      else false
    end as cohort_revenue_is_complete,

    case
      when a.spend > 0 and a.crm_leads > 0
        then a.spend / a.crm_leads::numeric
    end as cpl,

    case
      when a.spend > 0 and a.crm_agendados > 0
        then a.spend / a.crm_agendados::numeric
    end as cost_per_agendado,

    case
      when a.spend > 0 and a.crm_ganhos > 0
        then a.spend / a.crm_ganhos::numeric
    end as cost_per_gain,

    case
      when a.spend > 0 and a.acquisition_buying_contacts > 0
        then a.spend / a.acquisition_buying_contacts::numeric
    end as cac_acquisition,

    case
      when a.spend > 0
       and a.acquisition_sales > 0
       and a.acquisition_sales_without_valid_value = 0
        then a.acquisition_revenue / a.spend
    end as roas_acquisition,

    case
      when a.spend > 0
       and a.cohort_total_sales > 0
       and a.cohort_sales_without_valid_value = 0
        then a.total_cohort_revenue / a.spend
    end as roas_total_cohort

  from assembled a
  order by
    a.spend desc,
    a.group_name nulls last,
    a.group_id;
end;
$$;

CREATE OR REPLACE FUNCTION "public"."get_google_ads_summary_v2"("p_client_id" "uuid", "p_start_date" "date", "p_end_date" "date", "p_dimension" "text" DEFAULT 'account'::"text") RETURNS TABLE("dimension" "text", "group_id" "text", "group_name" "text", "account_id" "text", "account_name" "text", "campaign_id" "text", "campaign_name" "text", "ad_group_id" "text", "ad_group_name" "text", "ad_id" "text", "ad_name" "text", "ad_type" "text", "spend" numeric, "impressions" bigint, "clicks" bigint, "ctr" numeric, "cpc" numeric, "crm_leads" bigint, "crm_primeiras_conversas" bigint, "crm_agendados" bigint, "crm_ganhos" bigint, "acquisition_buying_contacts" bigint, "acquisition_sales" bigint, "acquisition_revenue" numeric, "acquisition_sales_with_valid_value" bigint, "acquisition_sales_without_valid_value" bigint, "acquisition_revenue_is_complete" boolean, "cohort_buying_contacts" bigint, "cohort_total_sales" bigint, "cohort_sales_without_own_lead" bigint, "total_cohort_revenue" numeric, "cohort_sales_with_valid_value" bigint, "cohort_sales_without_valid_value" bigint, "cohort_revenue_is_complete" boolean, "cpl" numeric, "cost_per_agendado" numeric, "cost_per_gain" numeric, "cac_acquisition" numeric, "roas_acquisition" numeric, "roas_total_cohort" numeric)
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
#variable_conflict use_column
begin
  if not private.can_view_client_financials(p_client_id) then
    raise exception 'Acesso financeiro não autorizado.' using errcode = '42501';
  end if;

  if p_client_id is null then
    raise exception using
      errcode = '22004',
      message = 'p_client_id não pode ser NULL';
  end if;

  if p_start_date is null or p_end_date is null then
    raise exception using
      errcode = '22004',
      message = 'p_start_date e p_end_date não podem ser NULL';
  end if;

  if p_start_date > p_end_date then
    raise exception using
      errcode = '22007',
      message = 'p_start_date não pode ser posterior a p_end_date';
  end if;

  if p_dimension is null
     or p_dimension not in ('account', 'campaign') then
    raise exception using
      errcode = '22023',
      message = format(
        'p_dimension inválida: %s. Valores aceitos: account, campaign',
        coalesce(p_dimension, 'NULL')
      );
  end if;

  return query
  with

  -- Última hierarquia conhecida para resolver nomes e conta de campanhas
  -- atribuídas no CRM, mesmo sem entrega dentro do período solicitado.
  campaign_hierarchy_latest as (
    select distinct on (m.campaign_id)
      m.campaign_id,
      m.campaign_name,
      m.customer_id,
      m.customer_name,
      m.date,
      m.updated_at,
      m.created_at,
      m.id
    from public.google_ads_campaign_daily m
    where m.client_id = p_client_id
      and m.campaign_id is not null
    order by
      m.campaign_id,
      m.date desc nulls last,
      m.updated_at desc nulls last,
      m.created_at desc nulls last,
      m.id desc
  ),

  -- Mídia real no período.
  media_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(m.customer_id, '__google_unmapped_account__')

        when 'campaign' then
          case
            when m.campaign_id is null then '__google_unmapped_campaign__'
            else concat_ws(
              '|',
              coalesce(m.customer_id, '__no_account__'),
              m.campaign_id
            )
          end
      end as group_id,

      case p_dimension
        when 'account' then
          coalesce(
            m.customer_name,
            m.customer_id,
            'Conta não identificada'
          )

        when 'campaign' then
          coalesce(
            m.campaign_name,
            m.campaign_id,
            'Campanha não identificada'
          )
      end as group_name,

      m.customer_id as account_id,
      m.customer_name as account_name,

      case
        when p_dimension = 'campaign' then m.campaign_id
      end as campaign_id,

      case
        when p_dimension = 'campaign' then m.campaign_name
      end as campaign_name,

      m.date::timestamp without time zone as sort_at,
      1::integer as source_priority,

      coalesce(m.cost, 0::numeric) as spend,
      coalesce(m.impressions, 0)::bigint as impressions,
      coalesce(m.clicks, 0)::bigint as clicks

    from public.google_ads_campaign_daily m
    where m.client_id = p_client_id
      and m.date between p_start_date and p_end_date
  ),

  -- Jornada CRM atribuída tecnicamente ao Google Ads.
  lead_resolved as (
    select
      l.*,

      ch.customer_id as resolved_account_id,
      ch.customer_name as resolved_account_name,

      coalesce(
        l.google_campaign_id,
        ch.campaign_id
      ) as resolved_campaign_id,

      ch.campaign_name as resolved_campaign_name

    from public.v_client_leads_by_stage_v2 l

    left join campaign_hierarchy_latest ch
      on ch.campaign_id = l.google_campaign_id

    where l.client_id = p_client_id
      and l.lead_date between p_start_date and p_end_date
      and l.attribution_platform = 'Google Ads'
  ),

  lead_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(
            lr.resolved_account_id,
            '__google_unmapped_account__'
          )

        when 'campaign' then
          case
            when lr.resolved_campaign_id is null
              then '__google_unmapped_campaign__'
            else concat_ws(
              '|',
              coalesce(
                lr.resolved_account_id,
                '__no_account__'
              ),
              lr.resolved_campaign_id
            )
          end
      end as group_id,

      case p_dimension
        when 'account' then
          coalesce(
            lr.resolved_account_name,
            lr.resolved_account_id,
            'Conta não identificada'
          )

        when 'campaign' then
          coalesce(
            lr.resolved_campaign_name,
            lr.resolved_campaign_id,
            'Campanha não identificada'
          )
      end as group_name,

      lr.resolved_account_id as account_id,
      lr.resolved_account_name as account_name,

      case
        when p_dimension = 'campaign'
          then lr.resolved_campaign_id
      end as campaign_id,

      case
        when p_dimension = 'campaign'
          then lr.resolved_campaign_name
      end as campaign_name,

      lr.lead_date::timestamp without time zone as sort_at,
      2::integer as source_priority,

      lr.contact_id,
      lr.has_primeira_conversa,
      lr.has_agendado,
      lr.has_ganho

    from lead_resolved lr
  ),

  -- Vendas oficiais ligadas à coorte Google Ads.
  sale_resolved as (
    select
      s.*,

      ch.customer_id as resolved_account_id,
      ch.customer_name as resolved_account_name,

      coalesce(
        s.google_campaign_id,
        ch.campaign_id
      ) as resolved_campaign_id,

      ch.campaign_name as resolved_campaign_name

    from public.v_crm_sales_v2 s

    left join campaign_hierarchy_latest ch
      on ch.campaign_id = s.google_campaign_id

    where s.client_id = p_client_id
      and s.contact_lead_date between p_start_date and p_end_date
      and s.is_cohort_linkable is true
      and s.attribution_platform = 'Google Ads'
  ),

  sale_tagged as (
    select
      case p_dimension
        when 'account' then
          coalesce(
            sr.resolved_account_id,
            '__google_unmapped_account__'
          )

        when 'campaign' then
          case
            when sr.resolved_campaign_id is null
              then '__google_unmapped_campaign__'
            else concat_ws(
              '|',
              coalesce(
                sr.resolved_account_id,
                '__no_account__'
              ),
              sr.resolved_campaign_id
            )
          end
      end as group_id,

      case p_dimension
        when 'account' then
          coalesce(
            sr.resolved_account_name,
            sr.resolved_account_id,
            'Conta não identificada'
          )

        when 'campaign' then
          coalesce(
            sr.resolved_campaign_name,
            sr.resolved_campaign_id,
            'Campanha não identificada'
          )
      end as group_name,

      sr.resolved_account_id as account_id,
      sr.resolved_account_name as account_name,

      case
        when p_dimension = 'campaign'
          then sr.resolved_campaign_id
      end as campaign_id,

      case
        when p_dimension = 'campaign'
          then sr.resolved_campaign_name
      end as campaign_name,

      sr.contact_lead_date::timestamp without time zone as sort_at,
      3::integer as source_priority,

      sr.opportunity_id,
      sr.contact_id,
      sr.is_acquisition_sale,
      sr.has_valid_value,
      sr.valor_ganho

    from sale_resolved sr
  ),

  -- Catálogo unificado: mantém grupos que só tenham mídia, CRM ou venda.
  catalog_rows as (
    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      sort_at,
      source_priority
    from media_tagged

    union all

    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      sort_at,
      source_priority
    from lead_tagged

    union all

    select
      group_id,
      group_name,
      account_id,
      account_name,
      campaign_id,
      campaign_name,
      sort_at,
      source_priority
    from sale_tagged
  ),

  dimension_catalog as (
    select
      cr.group_id,

      (
        array_agg(
          cr.group_name
          order by
            cr.sort_at desc nulls last,
            cr.source_priority
        )
        filter (where cr.group_name is not null)
      )[1] as group_name,

      (
        array_agg(
          cr.account_id
          order by
            cr.sort_at desc nulls last,
            cr.source_priority
        )
        filter (where cr.account_id is not null)
      )[1] as account_id,

      (
        array_agg(
          cr.account_name
          order by
            cr.sort_at desc nulls last,
            cr.source_priority
        )
        filter (where cr.account_name is not null)
      )[1] as account_name,

      (
        array_agg(
          cr.campaign_id
          order by
            cr.sort_at desc nulls last,
            cr.source_priority
        )
        filter (where cr.campaign_id is not null)
      )[1] as campaign_id,

      (
        array_agg(
          cr.campaign_name
          order by
            cr.sort_at desc nulls last,
            cr.source_priority
        )
        filter (where cr.campaign_name is not null)
      )[1] as campaign_name

    from catalog_rows cr
    group by cr.group_id
  ),

  media_agg as (
    select
      mt.group_id,
      sum(mt.spend)::numeric as spend,
      sum(mt.impressions)::bigint as impressions,
      sum(mt.clicks)::bigint as clicks
    from media_tagged mt
    group by mt.group_id
  ),

  lead_agg as (
    select
      lt.group_id,

      count(*)::bigint as crm_leads,

      count(*) filter (
        where lt.has_primeira_conversa is true
      )::bigint as crm_primeiras_conversas,

      count(*) filter (
        where lt.has_agendado is true
      )::bigint as crm_agendados,

      count(*) filter (
        where lt.has_ganho is true
      )::bigint as crm_ganhos

    from lead_tagged lt
    group by lt.group_id
  ),

  sale_agg as (
    select
      st.group_id,

      count(distinct st.contact_id) filter (
        where st.is_acquisition_sale is true
      )::bigint as acquisition_buying_contacts,

      count(*) filter (
        where st.is_acquisition_sale is true
      )::bigint as acquisition_sales,

      sum(st.valor_ganho) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is true
      )::numeric as acquisition_revenue,

      count(*) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is true
      )::bigint as acquisition_sales_with_valid_value,

      count(*) filter (
        where st.is_acquisition_sale is true
          and st.has_valid_value is not true
      )::bigint as acquisition_sales_without_valid_value,

      count(distinct st.contact_id)::bigint
        as cohort_buying_contacts,

      count(*)::bigint
        as cohort_total_sales,

      count(*) filter (
        where st.is_acquisition_sale is not true
      )::bigint as cohort_sales_without_own_lead,

      sum(st.valor_ganho) filter (
        where st.has_valid_value is true
      )::numeric as total_cohort_revenue,

      count(*) filter (
        where st.has_valid_value is true
      )::bigint as cohort_sales_with_valid_value,

      count(*) filter (
        where st.has_valid_value is not true
      )::bigint as cohort_sales_without_valid_value

    from sale_tagged st
    group by st.group_id
  ),

  assembled as (
    select
      dc.group_id,
      dc.group_name,
      dc.account_id,
      dc.account_name,
      dc.campaign_id,
      dc.campaign_name,

      coalesce(ma.spend, 0::numeric) as spend,
      coalesce(ma.impressions, 0)::bigint as impressions,
      coalesce(ma.clicks, 0)::bigint as clicks,

      coalesce(la.crm_leads, 0)::bigint as crm_leads,
      coalesce(
        la.crm_primeiras_conversas,
        0
      )::bigint as crm_primeiras_conversas,
      coalesce(la.crm_agendados, 0)::bigint as crm_agendados,
      coalesce(la.crm_ganhos, 0)::bigint as crm_ganhos,

      coalesce(
        sa.acquisition_buying_contacts,
        0
      )::bigint as acquisition_buying_contacts,

      coalesce(
        sa.acquisition_sales,
        0
      )::bigint as acquisition_sales,

      sa.acquisition_revenue,

      coalesce(
        sa.acquisition_sales_with_valid_value,
        0
      )::bigint as acquisition_sales_with_valid_value,

      coalesce(
        sa.acquisition_sales_without_valid_value,
        0
      )::bigint as acquisition_sales_without_valid_value,

      coalesce(
        sa.cohort_buying_contacts,
        0
      )::bigint as cohort_buying_contacts,

      coalesce(
        sa.cohort_total_sales,
        0
      )::bigint as cohort_total_sales,

      coalesce(
        sa.cohort_sales_without_own_lead,
        0
      )::bigint as cohort_sales_without_own_lead,

      sa.total_cohort_revenue,

      coalesce(
        sa.cohort_sales_with_valid_value,
        0
      )::bigint as cohort_sales_with_valid_value,

      coalesce(
        sa.cohort_sales_without_valid_value,
        0
      )::bigint as cohort_sales_without_valid_value

    from dimension_catalog dc

    left join media_agg ma
      on ma.group_id = dc.group_id

    left join lead_agg la
      on la.group_id = dc.group_id

    left join sale_agg sa
      on sa.group_id = dc.group_id
  )

  select
    p_dimension::text as dimension,
    a.group_id,
    a.group_name,

    a.account_id,
    a.account_name,
    a.campaign_id,
    a.campaign_name,

    null::text as ad_group_id,
    null::text as ad_group_name,
    null::text as ad_id,
    null::text as ad_name,
    null::text as ad_type,

    a.spend,
    a.impressions,
    a.clicks,

    case
      when a.impressions > 0
        then a.clicks::numeric
             / a.impressions::numeric
    end as ctr,

    case
      when a.clicks > 0
        then a.spend
             / a.clicks::numeric
    end as cpc,

    a.crm_leads,
    a.crm_primeiras_conversas,
    a.crm_agendados,
    a.crm_ganhos,

    a.acquisition_buying_contacts,
    a.acquisition_sales,
    a.acquisition_revenue,
    a.acquisition_sales_with_valid_value,
    a.acquisition_sales_without_valid_value,

    case
      when a.acquisition_sales = 0 then null
      when a.acquisition_sales_without_valid_value = 0 then true
      else false
    end as acquisition_revenue_is_complete,

    a.cohort_buying_contacts,
    a.cohort_total_sales,
    a.cohort_sales_without_own_lead,
    a.total_cohort_revenue,
    a.cohort_sales_with_valid_value,
    a.cohort_sales_without_valid_value,

    case
      when a.cohort_total_sales = 0 then null
      when a.cohort_sales_without_valid_value = 0 then true
      else false
    end as cohort_revenue_is_complete,

    case
      when a.spend > 0
       and a.crm_leads > 0
        then a.spend / a.crm_leads::numeric
    end as cpl,

    case
      when a.spend > 0
       and a.crm_agendados > 0
        then a.spend / a.crm_agendados::numeric
    end as cost_per_agendado,

    case
      when a.spend > 0
       and a.crm_ganhos > 0
        then a.spend / a.crm_ganhos::numeric
    end as cost_per_gain,

    case
      when a.spend > 0
       and a.acquisition_buying_contacts > 0
        then a.spend
             / a.acquisition_buying_contacts::numeric
    end as cac_acquisition,

    case
      when a.spend > 0
       and a.acquisition_sales > 0
       and a.acquisition_sales_without_valid_value = 0
        then a.acquisition_revenue / a.spend
    end as roas_acquisition,

    case
      when a.spend > 0
       and a.cohort_total_sales > 0
       and a.cohort_sales_without_valid_value = 0
        then a.total_cohort_revenue / a.spend
    end as roas_total_cohort

  from assembled a

  order by
    a.spend desc,
    a.group_name nulls last,
    a.group_id;

end;
$$;

revoke all on function public.get_client_overview_v2(uuid, date, date) from public, anon;
revoke all on function public.get_meta_ads_summary_v2(uuid, date, date, text) from public, anon;
revoke all on function public.get_google_ads_summary_v2(uuid, date, date, text) from public, anon;

grant execute on function public.get_client_overview_v2(uuid, date, date) to authenticated, service_role;
grant execute on function public.get_meta_ads_summary_v2(uuid, date, date, text) to authenticated, service_role;
grant execute on function public.get_google_ads_summary_v2(uuid, date, date, text) to authenticated, service_role;

comment on function private.can_view_client_financials(uuid) is
  'IMP-213: agência e gestão ativa podem ler métricas financeiras; attendant falha fechado.';

comment on function private.financial_client_ids() is
  'IMP-213: conjunto de clientes financeiros do usuário corrente, avaliado uma vez por consulta.';

-- Gate de integridade: se qualquer objeto essencial faltar ou uma ACL crítica
-- permanecer aberta, a transação inteira é abortada.
do $gate$
declare
  missing_views integer;
  open_views integer;
  missing_columns integer;
  data_quality_missing boolean;
begin
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'can_view_client_financials'
      and pg_get_function_identity_arguments(p.oid) = 'p_client_id uuid'
  ) then
    raise exception 'IMP213_GATE: helper financeiro ausente';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'financial_client_ids'
      and pg_get_function_identity_arguments(p.oid) = ''
  ) then
    raise exception 'IMP213_GATE: conjunto financeiro ausente';
  end if;

  select count(*) into missing_views
    from (values
      ('v_ads_spend_daily'), ('v_channel_performance_daily'), ('v_client_daily_pulse'),
      ('v_client_performance_daily'), ('v_client_performance_daily_v2'), ('v_crm_card_history_v1'),
      ('v_crm_events_daily_v2'), ('v_crm_events_enriched'), ('v_crm_events_feed_v2'),
      ('v_crm_funnel_daily'), ('v_crm_opportunities'), ('v_crm_opportunities_v2'),
      ('v_crm_sales_daily_v2'), ('v_crm_sales_v2'), ('v_google_ads_keywords_daily'),
      ('v_google_ads_v2'), ('v_google_campaign_daily'), ('v_google_campaign_performance'),
      ('v_google_keywords_v2'), ('v_meta_account_daily'), ('v_meta_ads_v2'),
      ('v_meta_campaign_daily'), ('v_meta_campaign_performance'), ('v_meta_creative_daily'),
      ('v_meta_creative_performance')
    ) required(name)
   where not exists (
     select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = required.name and c.relkind = 'v'
   );
  if missing_views <> 0 then
    raise exception 'IMP213_GATE: % views financeiras ausentes', missing_views;
  end if;

  select count(*) into open_views
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'v'
     and c.relname in (
       'v_ads_spend_daily','v_channel_performance_daily','v_client_daily_pulse',
       'v_client_performance_daily','v_client_performance_daily_v2','v_crm_card_history_v1',
       'v_crm_events_daily_v2','v_crm_events_enriched','v_crm_events_feed_v2',
       'v_crm_funnel_daily','v_crm_opportunities','v_crm_opportunities_v2',
       'v_crm_sales_daily_v2','v_crm_sales_v2','v_google_ads_keywords_daily',
       'v_google_ads_v2','v_google_campaign_daily','v_google_campaign_performance',
       'v_google_keywords_v2','v_meta_account_daily','v_meta_ads_v2',
       'v_meta_campaign_daily','v_meta_campaign_performance','v_meta_creative_daily',
       'v_meta_creative_performance'
     )
     and not (coalesce(c.reloptions, '{}') @> array['security_barrier=true','security_invoker=false']);
  if open_views <> 0 then
    raise exception 'IMP213_GATE: % views sem security_barrier/definer', open_views;
  end if;

  select count(*) into open_views
    from (values
      ('v_ads_spend_daily'), ('v_channel_performance_daily'), ('v_client_daily_pulse'),
      ('v_client_performance_daily'), ('v_client_performance_daily_v2'), ('v_crm_card_history_v1'),
      ('v_crm_events_daily_v2'), ('v_crm_events_enriched'), ('v_crm_events_feed_v2'),
      ('v_crm_funnel_daily'), ('v_crm_opportunities'), ('v_crm_opportunities_v2'),
      ('v_crm_sales_daily_v2'), ('v_crm_sales_v2'), ('v_google_ads_keywords_daily'),
      ('v_google_ads_v2'), ('v_google_campaign_daily'), ('v_google_campaign_performance'),
      ('v_google_keywords_v2'), ('v_meta_account_daily'), ('v_meta_ads_v2'),
      ('v_meta_campaign_daily'), ('v_meta_campaign_performance'), ('v_meta_creative_daily'),
      ('v_meta_creative_performance')
    ) required(name)
   where has_table_privilege('anon', format('public.%I', required.name), 'select');
  if open_views <> 0 then
    raise exception 'IMP213_GATE: anon ainda lê % views', open_views;
  end if;

  select count(*) into missing_columns
    from (values
      ('budget_status'), ('budget_value'), ('closed_value'), ('payment_method'),
      ('normalized_payload'), ('valor_ganho'), ('forma_ganho'), ('payload')
    ) forbidden(name)
   where has_column_privilege('authenticated', 'public.events_normalized', forbidden.name, 'select');
  if missing_columns <> 0 then
    raise exception 'IMP213_GATE: % colunas financeiras ainda legíveis', missing_columns;
  end if;

  select not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'v_data_quality_v2' and c.relkind = 'v'
  ) into data_quality_missing;
  if data_quality_missing then
    raise exception 'IMP213_GATE: v_data_quality_v2 ausente';
  end if;
end;
$gate$;

commit;
