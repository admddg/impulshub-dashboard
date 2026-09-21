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

## Bloqueio conforme regra das duas falhas

1. Primeira falha: o CLI rejeitou `--project-ref` sem `--linked`; falhou no preflight, antes de qualquer escrita. Corrigido para usar `--linked --project-ref`.
2. Segunda falha: a verificação combinada dos objetos tentou consultar `cron.job`, mas o staging respondeu `42P01 relation "cron.job" does not exist`. A consulta inteira abortou; não foi feita nova tentativa.

Como houve duas falhas na mesma etapa, a execução foi interrompida conforme `TASK-STAGING.md`. As etapas 3 (seed sintético) e 4 (aceite de isolamento) não foram iniciadas.

## Segurança e escopo

- Nenhuma escrita foi feita em `mtxnwtqwfagjzkvgsncs`.
- A única escrita remota foi o restore do schema em `nfratueiutxnypbxfnmi`.
- Nenhum dado real foi copiado.
- Não é possível afirmar ainda a contagem final de objetos nem o estado dos jobs pg_cron além do erro observado: a relação `cron.job` não existe no staging.
