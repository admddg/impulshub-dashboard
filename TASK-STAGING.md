# TASK — Restaurar STAGING (nfratueiutxnypbxfnmi) a partir de dump de esquema do Clients_Base (mtxnwtqwfagjzkvgsncs)

Objetivo (1 frase): dar ao ImpulsHub um projeto Supabase de staging com esquema public/crm/private equivalente a produção, seed sintético, sem jobs pg_cron ativos, para provar migrations antes do Caio aplicar em produção.

REGRA DE OURO, sem exceção: todo script que escreve deve abortar (exit != 0, sem tocar em nada) se a connection string / project ref de destino for mtxnwtqwfagjzkvgsncs (produção). Cheque isso ANTES de qualquer comando de escrita, em todo script. Staging é nfratueiutxnypbxfnmi — só esse projeto recebe escrita.

Escopo:
- Ler esquema (DDL) de public/crm/private em produção só por SELECT/pg_dump --schema-only (sem dados reais, sem PII).
- Restaurar esse esquema em staging (nfratueiutxnypbxfnmi).
- Seed SINTÉTICO (dados fake, sem PII de clientes reais) suficiente para rodar migrations e testes de isolamento entre tenants.
- Jobs pg_cron devem ficar DESATIVADOS em staging (nunca rodar o parser real contra dados fake sem necessidade).
- Scripts em supabase/staging/.
- Teste de isolamento entre clientes (verde) rodando contra staging.

Fora de escopo: qualquer escrita em mtxnwtqwfagjzkvgsncs; dados reais de clientes; ligar flags; deploy; novo custo além do já existente.

Entrega em ETAPAS, com commit a cada etapa (não esperar tudo pronto):
1. dump (schema-only de public/crm/private) — commit
2. restore em staging — commit
3. seed sintético — commit
4. aceite (isolamento entre clientes verde) — commit
Abra o PR draft assim que a etapa 1 tiver commit, e siga atualizando o mesmo PR a cada etapa. Se a sessão cair, o próximo executor retoma do último commit.

Duas falhas seguidas na MESMA etapa: pare, não tente uma terceira vez. Escreva no PR o que falhou e por quê, e finalize a sessão.

Entrega: PR draft (branch atual feat/staging-restore-v2, a partir de origin/main), relatório em 3 blocos (VERIFICADO RODANDO / CORRETO POR CONSTRUÇÃO NÃO TESTADO / NÃO BATEU-BLOQUEIO).

Leia AGENTS.md, docs/ROADMAP.md, ADRs relevantes antes de começar.
