Tarefa: FASE 0 do plano em docs/staging/RECONSTRUCAO-STAGING.md (leia o documento inteiro primeiro).
Execução SOMENTE-LEITURA no projeto de staging nfratueiutxnypbxfnmi (nunca mtxnwtqwfagjzkvgsncs — aborte
se qualquer credencial resolver para produção). Use scripts/staging-run.py em modo leitura (ou
equivalente com BEGIN READ ONLY ... ROLLBACK) — nunca commit.

Passos (seção "Fase 0" do plano):
1. Confirmar que o alvo é exatamente nfratueiutxnypbxfnmi.
2. select version, name from supabase_migrations.schema_migrations order by version; — comparar
   com os 20 arquivos de avanço listados no plano.
3. Consultar information_schema, pg_class, pg_proc, pg_policies e to_regclass('cron.job') no staging.
4. Medir as contagens da fixture: clientes, usuários, memberships, oportunidades, contatos,
   atividades, eventos.
5. Confirmar to_regclass('cron.job') is null (não criar a extensão).

Saída obrigatória: tabela "migration / ledger / objeto presente / decisão" em
docs/staging/FASE0-RECONCILIACAO.md, sem executar nenhum DDL, INSERT, UPDATE ou DELETE.

Ao final: decida e registre no mesmo documento, com base no que a Fase 1 do plano descreve, se o
caminho é "reparar" (schema integro, so corrigir seed) ou "reconstruir" (schema ausente/inconsistente).
Não execute a Fase 2/3 (restore ou seed) nesta entrega — só decida e documente qual seria o próximo
passo. Se aparecer qualquer sinal de escrita apontando para produção, pare e escreva BLOQUEIO.

Commit na branch atual (docs/staging-fase0-reconciliacao) e abra PR draft com gh pr create --draft.
Relate em 3 blocos (verificado rodando / correto por construção / não bateu) ao final do log.
