# STATUS — reconstrução do staging — 2026-09-22

## Estado

Seed da Fase 3 executado com sucesso; aceites da Fase 4 bloqueados por incompatibilidade do harness com diretivas psql. Não repetir os aceites nesta sessão: o limite de duas falhas da etapa foi atingido.

## Evidência

- Alvo autorizado: `nfratueiutxnypbxfnmi`.
- Produção `mtxnwtqwfagjzkvgsncs` foi usada somente para dump schema-only e preflight somente-leitura.
- Guard contra produção: `SUPABASE_TARGET_REF=mtxnwtqwfagjzkvgsncs` abortou com exit 10 antes de qualquer operação.
- Reset dos schemas do staging: `COMMIT ok (6 statements)`.
- Restore schema-only: concluído no staging.
- Estrutura pós-restore: 35 tabelas, 46 views/materialized views, 43 funções, 39 policies.
- `to_regclass('cron.job') is null`: `true`.
- Ledger `supabase_migrations.schema_migrations`: 2 linhas.
- Preflight `python scripts/db-prova.py --dry-run`: `dry_run=passed`, `writes=0`, `ddl=0`, `commit=0`; o script está fixado na produção, então as contagens retornadas por ele não são do staging.
- Preflight auth no staging: `auth.users.confirmed_at` e `auth.identities.email` são `GENERATED ALWAYS`.
- Seed corrigido executado em 2026-09-22 com `python scripts/staging-run.py commit supabase/staging/seed-synthetic.sql`: `COMMIT ok (21 statements) em nfratueiutxnypbxfnmi`.
- Leitura de volta após o commit: `clients=4`, `users=4`, `client_users=10`, `tenant_memberships=10`, `cards=8`, `contacts=4`, `activities=8`, `normalized_events=6`.
- `select to_regclass('cron.job') is null`: `true`.
- Aceites da Fase 4: `imp213-acceptance.sql` tentou primeiro pelo `staging-run.py` e falhou antes do SQL por diretiva `\\gset`; a tentativa pelo CLI/API também falhou porque o executor remoto não interpreta `\\set`; o executor temporário de compatibilidade falhou novamente ao encontrar a diretiva. As tentativas foram rollback/sem persistência. O limite de duas falhas da etapa foi atingido; `imp213-isolation.sql`, `imp214-acceptance.sql` e os aceites 216/230/231 não foram executados nesta sessão.
- O aceite 231 não é compatível com a reconstrução atual: exige `cron.job`, enquanto o contrato desta reconstrução exige sua ausência; não foi executado por causa do bloqueio da etapa.

## Diagnóstico e correção

O dump cria `crm.event_map`, mas a fixture não inseria suas seis linhas canônicas. O trigger `crm.emit_opportunity_stage_event` consulta esse catálogo ao inserir `crm.opportunities`, causando o abort.

`supabase/staging/seed-synthetic.sql` foi corrigido para inserir os seis mapeamentos. A correção foi executada remotamente no staging nesta retomada e confirmou as contagens esperadas.

## Próxima execução autorizada

1. Corrigir o harness para interpretar as diretivas `psql` usadas nos aceites, sem alterar o contrato dos arquivos.
2. Executar os aceites IMP-213, isolamento, IMP-214 e aceites posteriores disponíveis em transações com rollback.
3. Confirmar novamente `cron.job` ausente após os aceites.

Não declarar staging reconstruído até essas medições e aceites passarem.
