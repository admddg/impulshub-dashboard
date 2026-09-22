# TASK-STAGING — retomada 21/09/2026

## Etapas anteriores

- Etapa 1, dump schema-only: concluída em `466fdd1`; fonte `mtxnwtqwfagjzkvgsncs`, sem dados.
- Etapa 2, restore: concluída em `e877e8f`; alvo somente `nfratueiutxnypbxfnmi`.
- Etapa 3, seed: retomada com contador zerado conforme instrução do turno.

## Preflight

`python scripts/db-prova.py --dry-run` → `dry_run=passed`, `writes=0`, `ddl=0`, `commit=0`.

Consulta de `information_schema.columns` executada no staging antes dos INSERTs em `auth.users`/`auth.identities`. Confirmou `auth.users.confirmed_at` e `auth.identities.email` como colunas geradas (`ALWAYS`). O seed foi reduzido às colunas mínimas e omite ambas.

## Seed

O arquivo agora usa os UUIDs canônicos de quatro clientes e quatro usuários, memberships/client_users correspondentes, catálogo global copiado por leitura da produção, oito cards, quatro contatos, oito atividades e eventos GHL sintéticos.

Duas tentativas foram feitas nesta retomada:

1. `42601` em `auth.identities`: listas `VALUES` incompatíveis. Transação abortada.
2. `23514` em `crm.opportunity_stage_history`: `origin='system'` não pertence ao check atual. A consulta de leitura confirmou os valores permitidos: `frase_configurada`, `manual`, `integracao`, `sistema`. Transação abortada.

O arquivo foi corrigido para `origin='sistema'`, mas a etapa está bloqueada pela regra de duas falhas: não executar uma terceira tentativa nesta sessão.

## Aceites

`imp213-isolation.sql` e `imp214-acceptance.sql` não foram executados, pois o seed não concluiu e não há fixture válida no staging.

## Segurança

- Nenhuma escrita foi feita na produção.
- As duas tentativas foram feitas somente no projeto `nfratueiutxnypbxfnmi` e abortaram sem commit.
- Nenhum dado real foi copiado.

## Próxima retomada

Executar o seed corrigido como nova etapa/sessão com contador explícito, validar contagens e somente então rodar os dois aceites. Não alterar os UUIDs dos aceites.
