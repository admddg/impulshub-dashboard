# Staging ImpulsHub

Projeto Supabase de staging: `nfratueiutxnypbxfnmi`.

## Escopo e segurança

- A produção `mtxnwtqwfagjzkvgsncs` é somente leitura para esta entrega.
- O restore usa apenas o dump schema-only versionado em `supabase/staging/production-schema.sql`.
- O seed planejado usa IDs, e-mails e nomes sintéticos; não copia dados reais.
- Scripts de escrita devem recusar qualquer alvo diferente do staging e abortar explicitamente para produção.

## Estado verificado

Após o restore, as contagens lidas foram:

| objeto | staging | produção |
|---|---:|---:|
| tabelas em `public`, `crm`, `private` | 34 | 33 |
| views/materialized views | 46 | 46 |
| funções | 42 | 42 |
| políticas RLS | 39 | 39 |
| `to_regclass('cron.job') is not null` | false | true |

A diferença de uma tabela está fora do conjunto restaurado de negócio e precisa ser reconciliada antes de declarar equivalência estrutural. O staging não possui a extensão `pg_cron` por desenho. Portanto, os jobs do parser não existem no staging; não criar a extensão. Toda verificação deve usar `to_regclass('cron.job') is null`, nunca consultar `cron.job` diretamente.

## Reconstrução do zero

1. Obter um dump schema-only de produção, sem dados, para `supabase/staging/production-schema.sql`.
2. Executar `supabase/staging/restore-schema.sh` com `SUPABASE_TARGET_REF=nfratueiutxnypbxfnmi`.
3. Executar `scripts/db-prova.py --dry-run` antes de qualquer escrita.
4. Executar `supabase/staging/seed-synthetic.sql` no staging.
5. Adaptar os IDs sintéticos nos aceites e executar `supabase/acceptance/imp213-isolation.sql` e `supabase/acceptance/imp214-acceptance.sql`, sempre em transações que terminem em `ROLLBACK` quando o aceite criar ou alterar fixtures.
6. Confirmar os contadores de objetos e registrar a ausência esperada de `cron.job` com `to_regclass`.

O seed e os aceites ainda não podem ser considerados concluídos neste commit: a execução foi interrompida após duas falhas distintas, conforme o contrato operacional.
