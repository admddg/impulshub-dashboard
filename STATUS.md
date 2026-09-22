IMP-217 — BLOQUEIO após duas falhas na prova transacional de staging
Data da execução: 2026-09-22
Branch: feat/imp-217-outcome-value-reason

Correção aplicada nesta execução:
- crm_register_won: stage_history insert -> commercial_outcomes insert -> opportunities update -> milestones.
- crm_register_lost: stage_history insert -> commercial_outcomes insert -> opportunities update.
- APLICAR-imp217.sql sincronizado com a migration.
- imp217-isolation.sql alinhado ao padrão de isolamento autenticado do IMP-213; a segunda prova passou por esse arquivo.

Evidências desta execução:
- python scripts/db-prova.py --dry-run: passou; writes=0, ddl=0, commit=0.
- Prova staging tentativa 1: migration + acceptance executados; falhou em imp217-isolation.sql porque o teste exigia eventos preexistentes para Central/Royal e lançou IMP217_ISOLATION: event scope crossed. Runner fez rollback.
- Prova staging tentativa 2: migration + acceptance + isolamento executados; isolamento passou, com claims dos dois usuários retornados; falhou no rollback em 20261003000000_imp217_outcome_value_reason.rollback.sql, erro 42601 syntax error near CREATE. Causa: definição de função sem terminador foi concatenada ao próximo CREATE.
- Runner fez rollback automático também na segunda tentativa.

Não executado:
- nenhuma escrita em produção;
- nenhuma migration persistida em staging;
- nenhum commit, push ou PR draft;
- nenhum aceite transacional completo após a correção do rollback.

Bloqueio:
- Duas falhas na mesma etapa de prova staging consumiram o limite do contrato. O rollback precisa ser corrigido para inserir terminador após cada pg_get_functiondef antes de nova prova. Não repetir staging nesta execução.

## Revisão do Head — provado em staging

Corrigido pelo Head: `;` faltando após cada `$function$` no rollback (concatenava com o próximo
CREATE). Provado em staging (nfratueiutxnypbxfnmi): migration + aceite + isolamento + rollback numa
transação, sem erro. Negativo confere (aceite falha sem a migration). `APLICAR-imp217.sql`
autocontido, verde sozinho.
