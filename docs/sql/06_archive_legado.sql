-- ============================================================================
-- ImpulsHub — Organização: move tabelas de backup e objetos deprecated para
-- um schema "archive", fora do caminho do public. Nada é apagado — só
-- organizado. Se precisar consultar algo antigo no futuro, é só trocar
-- "public.tabela" por "archive.tabela".
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS archive;

-- ----------------------------------------------------------------------------
-- 1) Tabelas de backup da Royal (08/07) — reprocessamento pontual já validado
-- ----------------------------------------------------------------------------
ALTER TABLE public.backup_events_normalized_royal_20260708 SET SCHEMA archive;
ALTER TABLE public.backup_events_raw_royal_20260708 SET SCHEMA archive;
ALTER TABLE public.backup_rebuild_royal_conversion_outbox_20260708_1551 SET SCHEMA archive;
ALTER TABLE public.backup_rebuild_royal_events_normalized_20260708_1551 SET SCHEMA archive;
ALTER TABLE public.backup_rebuild_royal_events_raw_20260708_1551 SET SCHEMA archive;

-- ----------------------------------------------------------------------------
-- 2) Tabela de criativos Meta descontinuada (campos migraram para meta_ads_daily)
-- ----------------------------------------------------------------------------
ALTER TABLE public.meta_ads_creatives_deprecated SET SCHEMA archive;

-- ----------------------------------------------------------------------------
-- 3) View de mídia unificada legada (substituída por v_ads_spend_daily)
-- ----------------------------------------------------------------------------
ALTER VIEW public.ads_daily SET SCHEMA archive;

-- ----------------------------------------------------------------------------
-- 4) Garante que anon/authenticated não enxergam nem alcançam o schema novo
--    (defesa extra: mesmo achando o nome da tabela, não conseguem nem "entrar"
--    no schema sem USAGE — camada a mais além da RLS que já bloqueia tudo)
-- ----------------------------------------------------------------------------
REVOKE ALL ON SCHEMA archive FROM anon, authenticated;


-- ============================================================================
-- VALIDAÇÃO — rodar depois de aplicar
-- ============================================================================

-- 1. confirma que sumiram do schema public
select table_name from information_schema.tables
where table_schema = 'public'
  and table_name in (
    'backup_events_normalized_royal_20260708',
    'backup_events_raw_royal_20260708',
    'backup_rebuild_royal_conversion_outbox_20260708_1551',
    'backup_rebuild_royal_events_normalized_20260708_1551',
    'backup_rebuild_royal_events_raw_20260708_1551',
    'meta_ads_creatives_deprecated',
    'ads_daily'
  );
-- esperado: nenhuma linha

-- 2. confirma que estão intactas dentro de archive
select table_schema, table_name from information_schema.tables
where table_schema = 'archive'
order by table_name;
-- esperado: as 6 tabelas + a view ads_daily (7 linhas)

-- 3. como ficou o schema public agora (deve mostrar só o que está em uso ativo)
select table_name from information_schema.tables
where table_schema = 'public' and table_type = 'BASE TABLE'
order by table_name;
