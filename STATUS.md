# TASK-STAGING — bloqueio após etapa 2

## Etapa 1 — dump schema-only

- Concluída e commitada em `466fdd1`.
- Fonte somente leitura: `mtxnwtqwfagjzkvgsncs`.
- Resultado: exit `0`; `498797` bytes; `11773` linhas; `3` schemas; `33` tabelas; sem `COPY`, `INSERT`, `UPDATE` ou `DELETE` no início de linha.

## Etapa 2 — restore em staging

- Restore executado somente contra `nfratueiutxnypbxfnmi`.
- O script `supabase/staging/restore-schema.sh` aborta se o alvo for `mtxnwtqwfagjzkvgsncs` e também rejeita qualquer ref diferente do staging.
- Preflight somente leitura retornou `database=postgres` e `role=postgres` no staging.
- Restore terminou com exit `0`.

## Contagens após o restore

Consulta somente leitura com `to_regclass('cron.job')`:

- staging: 34 tabelas, 46 views/materialized views, 42 funções, 39 políticas RLS, `cron.job` ausente (`false`);
- produção: 33 tabelas, 46 views/materialized views, 42 funções, 39 políticas RLS, `cron.job` presente (`true`).

A ausência de `pg_cron` no staging é esperada e não deve ser corrigida criando a extensão. Os jobs do parser não existem no staging por desenho.

## Bloqueio atual da etapa 3 — seed sintético

A decisão do Head zerou o contador da etapa anterior e permitiu iniciar o seed. O preflight obrigatório `python scripts/db-prova.py --dry-run` passou com `writes=0`, `ddl=0`, `commit=0`.

1. Primeira tentativa do seed: falha de sintaxe em `set local constraints all deferred`; corrigido para `set constraints all deferred`.
2. Segunda tentativa: PostgreSQL recusou valor explícito em `auth.users.confirmed_at`, pois a coluna é gerada (`428C9`). A transação não concluiu.

Pela regra de duas falhas na mesma etapa, não foi feita terceira tentativa. As etapas de aceite IMP-213/IMP-214 não foram iniciadas.

## Segurança e escopo

- Nenhuma escrita foi feita em `mtxnwtqwfagjzkvgsncs`.
- Restore e tentativas de seed foram direcionados somente a `nfratueiutxnypbxfnmi`.
- Nenhum dado real foi copiado.
- `README.md` registra a reconstrução do zero e a regra de `to_regclass('cron.job')`.
