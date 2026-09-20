-- IMP-211 Parte 1 -- trigger de stage_version.
-- Abrir este arquivo, Ctrl+A, Ctrl+C, colar no SQL Editor do Clients_Base.
-- Idempotente: pode rodar quantas vezes quiser.
-- Nao toca em tabela, coluna, linha nem schema.

begin;

set local lock_timeout = '5s';

create or replace function crm.bump_stage_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if new.current_stage_id is distinct from old.current_stage_id then
    new.stage_version := old.stage_version + 1;
  end if;
  return new;
end;
$fn$;

revoke all on function crm.bump_stage_version() from public, anon, authenticated, service_role;

drop trigger if exists opportunities_bump_stage_version on crm.opportunities;

-- BEFORE de proposito: a ponte de conversoes (AFTER UPDATE) precisa enxergar a
-- versao ja incrementada no payload que envia.
create trigger opportunities_bump_stage_version
before update of current_stage_id on crm.opportunities
for each row execute function crm.bump_stage_version();

comment on function crm.bump_stage_version() is
  'Garante stage_version = anterior + 1 em qualquer troca de etapa, inclusive movimentos automaticos do parser.';

-- Trava de seguranca: se o trigger nao estiver de pe ao chegar aqui, aborta
-- tudo em vez de reportar sucesso.
do $check$
begin
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'crm.opportunities'::regclass
       and tgname = 'opportunities_bump_stage_version'
  ) then
    raise exception 'FALHOU: opportunities_bump_stage_version nao foi criado';
  end if;
end
$check$;

commit;

-- Confere (pode rodar junto, depois do commit): tem que voltar 1 e 1.
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'crm' and p.proname = 'bump_stage_version')   as funcao,
  (select count(*) from pg_trigger
    where tgrelid = 'crm.opportunities'::regclass
      and tgname = 'opportunities_bump_stage_version')              as trigger;
