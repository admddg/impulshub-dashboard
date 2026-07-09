-- ============================================================================
-- ImpulsHub — Reforço de segurança (achados do BANCO_DE_DADOS.md, seção 6)
-- Nenhuma dessas mudanças altera comportamento do app: o frontend já usa
-- exclusivamente v_client_profile_safe (nunca clients_base direto) e nunca
-- lê as tabelas de backup/deprecated. São só revogações de permissão —
-- reduzem superfície de risco sem quebrar nada em produção.
--
-- ATENÇÃO: a v_client_profile_safe é um SELECT simples de clients_base, SEM
-- filtro próprio de segurança — ela depende 100% da RLS de clients_base
-- rodando via security_invoker, o que exige que 'authenticated' continue
-- com SELECT na tabela. Por isso o item 1 NÃO revoga tudo: troca o grant de
-- tabela inteira por um grant só nas colunas que a view realmente usa.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1) clients_base — troca grant de "todas as colunas" por "só as seguras"
--    Motivo: a tabela guarda tokens/segredos em texto puro (meta_access_token,
--    google_ads_refresh_token, google_ads_developer_token, ga4_api_secret,
--    tiktok_access_token, entre outros). Um usuário autenticado hoje poderia
--    consultar a tabela crua e ler esses campos. Depois deste script, ele só
--    consegue ler exatamente as colunas que v_client_profile_safe expõe.
-- ----------------------------------------------------------------------------
REVOKE SELECT ON public.clients_base FROM authenticated;

GRANT SELECT (
  id, client_name, client_slug, status, timezone, currency,
  tracking_status, tracking_ready, meta_ready, google_ads_ready,
  meta_ads_sync_ready, google_ads_sync_ready, sync_ready,
  meta_ads_last_sync_at, google_ads_last_sync_at,
  meta_ads_last_backfill_at, google_ads_last_backfill_at,
  created_at, updated_at
) ON public.clients_base TO authenticated;


-- ----------------------------------------------------------------------------
-- 2) Tabelas internas com RLS ativa e SEM política — hoje já bloqueadas pela
--    ausência de política, mas com grants de escrita abertos "por via das
--    dúvidas". Revogando a escrita de anon/authenticated, removemos o risco
--    de uma política futura mal escrita reabrir essas tabelas por acidente.
-- ----------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.events_raw FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.conversion_outbox FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.meta_ads_creatives_deprecated FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.backup_events_normalized_royal_20260708 FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.backup_events_raw_royal_20260708 FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.backup_rebuild_royal_conversion_outbox_20260708_1551 FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.backup_rebuild_royal_events_normalized_20260708_1551 FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.backup_rebuild_royal_events_raw_20260708_1551 FROM anon, authenticated;


-- ============================================================================
-- VALIDAÇÃO — rodar depois de aplicar, NESTA ORDEM
-- ============================================================================

-- 1. confirma que a view de perfil AINDA funciona (o teste mais importante —
--    se isso quebrar, algo na lista de colunas do passo 1 está errado)
select client_id, client_slug, client_name from v_client_profile_safe;

-- 2. confirma que uma coluna sensível NÃO é mais acessível direto
--    (esperado: erro "permission denied for table clients_base")
-- select meta_access_token from clients_base limit 1;

-- 3. confirma os grants remanescentes nas tabelas internas
select table_name, grantee, string_agg(privilege_type, ', ') as privileges
from information_schema.role_table_grants
where table_name in (
  'events_raw','conversion_outbox','meta_ads_creatives_deprecated',
  'backup_events_normalized_royal_20260708','backup_events_raw_royal_20260708',
  'backup_rebuild_royal_conversion_outbox_20260708_1551',
  'backup_rebuild_royal_events_normalized_20260708_1551',
  'backup_rebuild_royal_events_raw_20260708_1551'
) and grantee in ('anon','authenticated')
group by table_name, grantee
order by table_name, grantee;
