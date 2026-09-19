-- Corrige a trava otimista: movimentos automaticos nao incrementavam stage_version.
--
-- O parser promove Lead -> Atendimento com um UPDATE direto em crm.opportunities
-- e nunca tocou stage_version. Medido em producao antes desta correcao:
-- 259 de 259 oportunidades em atendimento com stage_version = 0.
--
-- Efeito pratico: a tela carrega um card em Lead na versao 0, o parser move o
-- card para Atendimento (ainda versao 0), e a acao do usuario passa pela
-- checagem de conflito como se nada tivesse acontecido. A trava existe
-- exatamente para esse caso e estava cega.
--
-- A correcao fica no banco, nao no parser: qualquer caminho que mude a etapa
-- passa a incrementar a versao, inclusive codigo futuro. As RPCs ja fazem o +1
-- explicito e continuam corretas -- o trigger grava o mesmo valor.

set local lock_timeout = '5s';

create function crm.bump_stage_version()
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

-- BEFORE de proposito: a ponte de conversoes (AFTER UPDATE) precisa enxergar a
-- versao ja incrementada no payload que envia.
create trigger opportunities_bump_stage_version
before update of current_stage_id on crm.opportunities
for each row execute function crm.bump_stage_version();

comment on function crm.bump_stage_version() is
  'Garante stage_version = anterior + 1 em qualquer troca de etapa, inclusive movimentos automaticos do parser.';

-- DOWN (executar em uma transacao):
-- drop trigger if exists opportunities_bump_stage_version on crm.opportunities;
-- drop function if exists crm.bump_stage_version();
