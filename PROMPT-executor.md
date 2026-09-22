Tarefa: FASES 1, 2, 3 e 4 do plano em docs/staging/RECONSTRUCAO-STAGING.md, com a decisão já
tomada na Fase 0 (PR #20, mesclado): o ledger do staging não reconcilia com as 20 migrations —
RECONSTRUIR do zero, não reparar.

Escrita SOMENTE no projeto nfratueiutxnypbxfnmi. Aborte qualquer script se o alvo resolver para
mtxnwtqwfagjzkvgsncs (produção). Use scripts/staging-run.py (modo commit) ou equivalente.

Passos:
1. Fase 2 — novo dump schema-only de produção (public, crm, private; tabelas, views, funções,
   policies RLS, grants, triggers, índices, extensões) e restore em nfratueiutxnypbxfnmi via
   restore-schema.sh (confira o guard antes de rodar). Repita a contagem estrutural (tabelas,
   views, funções, policies) e confirme a diferença de 1 tabela documentada na Fase 0, ou explique
   se ela sumiu.
2. Fase 3 — seed sintético: preflight de colunas geradas em auth.users/auth.identities antes do
   INSERT (achado conhecido: confirmed_at e identities.email são geradas). Revisar o diff de
   supabase/staging/seed-synthetic.sql, especialmente origin='sistema' (não 'system') no
   opportunity_stage_history. Rodar uma única vez em transação controlada; ler de volta as
   contagens (4 clientes, 4 usuários, 10 vínculos, 8 cards, 4 contatos, 8 atividades, 6 eventos
   normalizados). Duas falhas na mesma etapa: pare e reporte, não tente a terceira vez.
3. Fase 4 — aceites: rode (com scripts/staging-run.py, modo rollback — nunca commit nos aceites)
   imp213-acceptance.sql, imp213-isolation.sql, imp214-acceptance.sql, e os aceites das migrations
   216/230/231 se existirem em supabase/acceptance/. Confirme isolamento entre clientes.
4. Confirme novamente to_regclass('cron.job') is null ao final (não criar a extensão).
5. Atualize supabase/staging/README.md com o resultado real desta reconstrução (data, números
   medidos, quaisquer erros e como foram corrigidos).

Ao final: commit por etapa (dump, restore, seed, aceites, doc). Abra PR draft com gh pr create
--draft, relatório em 3 blocos. Se travar duas vezes na mesma etapa, pare e escreva STATUS.md.
