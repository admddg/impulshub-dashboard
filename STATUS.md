# STATUS — reconstrução do staging — 2026-09-22

## Estado

Bloqueado na Fase 3 após uma execução do seed. Não executar nova tentativa nesta sessão.

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
- Seed: uma execução, rollback por `P0001 IMP-216 cannot map CRM stage 00000000-0000-0000-0000-000000000201 to an event code`.

## Diagnóstico e correção

O dump cria `crm.event_map`, mas a fixture não inseria suas seis linhas canônicas. O trigger `crm.emit_opportunity_stage_event` consulta esse catálogo ao inserir `crm.opportunities`, causando o abort.

`supabase/staging/seed-synthetic.sql` foi corrigido para inserir os seis mapeamentos. A correção ainda não foi executada remotamente nesta sessão.

## Próxima execução autorizada

1. Rodar uma nova execução controlada do seed corrigido no staging.
2. Ler de volta 4 clientes, 4 usuários, 10 vínculos, 8 cards, 4 contatos, 8 atividades e 6 eventos normalizados.
3. Só então executar os aceites IMP-213, isolamento, IMP-214 e aceites posteriores disponíveis.
4. Confirmar novamente `cron.job` ausente.

Não declarar staging reconstruído até essas medições e aceites passarem.
