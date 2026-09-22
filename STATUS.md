# STATUS — reconstrução do staging — 2026-09-22

## Estado

Seed da Fase 3 executado com sucesso; o harness agora interpreta o subconjunto psql usado pelos aceites. A reconstrução segue incompleta: IMP-213 depende de fixture financeira ausente e IMP-216 encontrou variação indevida no staging.

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
- Harness corrigido em `scripts/staging-run.py`: suporta `\\set`, `\\gset PREFIXO`, `:variavel` e `:'variavel'`, com casts preservados; validação local mediu 14 SQL + 5 diretivas em IMP-213 e 16 SQL + 4 diretivas em IMP-229.
- `imp213-acceptance.sql`: rollback sem persistência, bloqueado no primeiro `\\gset` porque a query encontrou 0 linhas elegíveis (`commercial_outcomes.value` não nulo e `value_status='valid'`) na fixture sintética.
- `imp213-isolation.sql`: `ROLLBACK ok (9 statements)`.
- `imp214-acceptance.sql`: `ROLLBACK ok (14 statements)`.
- `imp216-acceptance.sql` + `imp216-isolation.sql`: rollback após falha de aceite; para cliente GHL Royal houve delta indevido em `events_normalized` (delta observado 2, esperado 0). O limite operacional de duas falhas nesta etapa de aceites foi atingido; 230 e 231 não foram executados.
- Confirmação final somente-leitura: `cron.job_absent=True`.
- O aceite 231 continua fora desta reconstrução: exige `cron.job`, deliberadamente ausente.

## Diagnóstico e correção

O dump cria `crm.event_map`, mas a fixture não inseria suas seis linhas canônicas. O trigger `crm.emit_opportunity_stage_event` consulta esse catálogo ao inserir `crm.opportunities`, causando o abort.

`supabase/staging/seed-synthetic.sql` foi corrigido para inserir os seis mapeamentos. A correção foi executada remotamente no staging nesta retomada e confirmou as contagens esperadas.

## Próxima execução autorizada

1. Corrigir a fixture/contrato do aceite 213 para fornecer um outcome financeiro elegível, sob nova autorização.
2. Investigar a emissão indevida do IMP-216 para clientes GHL antes de repetir a etapa.
3. Executar 230 somente após resolver os dois bloqueios e sob nova autorização; manter 231 fora deste staging.

Não declarar staging reconstruído até essas medições e aceites passarem.
