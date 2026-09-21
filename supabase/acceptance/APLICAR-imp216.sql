\set ON_ERROR_STOP on

-- IMP-216: aplicar somente apos revisao do Head e autorizacao escrita do Caio.
-- Este arquivo executa a migration completa e registra a versao no ledger.
-- Nao executar em staging/producao nesta entrega do Executor.

begin;
set local lock_timeout = '5s';
\ir ../migrations/20260930000000_imp216_split_flags.sql

-- Registro explicito: a migration tambem faz upsert idempotente no ledger.
do $ledger$
begin
  if not exists (
    select 1 from supabase_migrations.schema_migrations
     where version = '20260930000000'
       and name = 'imp216_split_flags'
  ) then
    raise exception 'IMP216_APLICAR: registro ausente no ledger';
  end if;
end
$ledger$;

commit;
