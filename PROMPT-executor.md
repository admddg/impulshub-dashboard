Tarefa: implemente EXATAMENTE conforme docs/task-files/TASK-IMP-217.md (leia inteiro primeiro) e
AGENTS.md. Branch atual feat/imp-217-outcome-value-reason, a partir de origin/main.

DECISÕES DO CAIO (resolvem os itens PENDENTE do task file — não reabra):
- Decisão 8 (Purchase com valor pendente): opção (a) — NÃO criar a linha em conversion_outbox
  enquanto value_status='pending'. O dashboard (events_normalized) recebe o evento de ganho
  normalmente, sempre. A linha de conversion_outbox só nasce quando o valor existir.
- Decisão 9 (preenchimento de valor depois do ganho): NÃO existe esse caso de negócio hoje. Fica
  fora de escopo. Não implemente um segundo caminho de emissão para isso.
- Decisão 10 (moeda): CRIAR coluna de moeda no evento (public.events_normalized). Hoje será sempre
  'BRL' (mesmo default de crm.commercial_outcomes.currency), mas a coluna existe para o futuro.
  Escolha o nome seguindo a convenção já usada na tabela (ex.: currency, moeda — confira o padrão
  das colunas vizinhas antes de nomear) e documente a escolha no PR.

Confirmação de ordem: você implementa APENAS a IMP-217 nesta branch/worktree. A IMP-218 (mesma
função crm.emit_opportunity_stage_event) roda DEPOIS, em outro worktree, só quando a 217 estiver
mesclada. Não espere pela 218.

Antes de codificar: leia a definição viva (pg_get_functiondef) de crm.emit_opportunity_stage_event,
crm_register_won, crm_register_lost em produção (mtxnwtqwfagjzkvgsncs), SOMENTE LEITURA. Prove no
staging (nfratueiutxnypbxfnmi) com scripts/staging-run.py quando ele estiver pronto (pode já estar,
uma reconstrução está rodando em paralelo em outro worktree); se staging não estiver disponível
ainda, use scripts/db-prova.py --dry-run em produção e registre isso no PR — não espere
indefinidamente, entregue os arquivos e diga no relatório que falta a prova em staging.

NÃO execute nenhuma migration fora de transação com ROLLBACK. NÃO aplique em produção. Commit a
cada etapa (leitura documentada, migration, rollback, aceite, isolamento, APLICAR). Abra PR draft
com gh pr create --draft. Relatório em 3 blocos. Duas falhas na mesma etapa: pare, escreva
STATUS.md e descreva o bloqueio exato.
