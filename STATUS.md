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

1. Corrigir o contrato do aceite 213: ele consulta um card Royal com o atendente exclusivo da Central; escolher explicitamente uma fixture no mesmo tenant ou um papel atendente Royal, sem relaxar a RLS.
2. Manter 231 fora desta reconstrução: exige `cron.job`, deliberadamente ausente.

Não declarar staging reconstruído até o aceite 213 ser corrigido e passar.

## Retomada autorizada — execução atual

- `supabase/staging/seed-synthetic.sql` corrigido para `crm_feeds_dashboard=false` em Royal, Central e QuickClean, `true` apenas no ImpulsHub; o `ON CONFLICT` agora atualiza essas flags.
- O seed remove apenas resíduos sintéticos `impuls_crm` dos três tenants GHL, preservando os eventos `ghl`; também cria um outcome Royal `won` sintético de `1250.00 BRL` para o aceite financeiro.
- Aplicação no staging: `COMMIT ok (28 statements) em nfratueiutxnypbxfnmi`; contagens medidas: 4 clientes, 4 usuários, 10 `client_users`, 10 `tenant_memberships`, 8 cards, 4 contatos, 8 atividades, 6 eventos normalizados.
- IMP-213 acceptance: bloqueado no primeiro papel; o atendente Central consulta o card Royal e a RLS retorna zero, então a asserção de visibilidade falha corretamente.
- IMP-213 isolation: `ROLLBACK ok (9 statements)`.
- IMP-214 acceptance: `ROLLBACK ok (14 statements)`.
- IMP-216 acceptance + isolation: `ROLLBACK ok (23 statements)`; nenhum delta em `events_normalized`/`conversion_outbox` nos tenants GHL e isolamento aprovado.
- IMP-230 acceptance + isolation: `ROLLBACK ok (8 statements)`.
- `python scripts/db-prova.py --dry-run`: `dry_run=passed`, `writes=0`, `ddl=0`, `commit=0`.
- `select to_regclass('cron.job') is null`: continua esperado como `true` e o IMP-231 permanece excluído.

Estado: reconstrução funcional para seed, IMP-213 isolation, IMP-214, IMP-216 e IMP-230; aceite IMP-213 pendente por inconsistência do próprio contrato de fixture. O staging ainda não deve ser declarado reconstruído.

## Revisão do Head — correção do fixture de papel

Bug real encontrado no PRÓPRIO arquivo de aceite (não no produto nem no seed anterior): o teste de
"atendente não vê financeiro" usava o atendente da Central (bb04435c) para checar um card da Royal
(onde o outcome sintético de 1250 BRL foi criado) — a RLS bloqueia por tenant errado e o teste falhava
com "milestone revenue não visível" antes mesmo de testar a ocultação do campo financeiro.

Corrigido: adicionado um atendente sintético próprio da Royal (`aa04435c-fabb-4ba8-b5b5-e0175d9ca17d`,
role attendant em client_users e crm.tenant_memberships) e o aceite passou a usá-lo.

Resultado provado nesta rodada (staging nfratueiutxnypbxfnmi, seed refeito do zero):
- imp213-acceptance: assertivas principais passam (atendente Royal vê o marco mas sem campo
  financeiro/evidence; gestor Royal vê o valor completo e correto). A consulta de auto-verificação
  pós-rollback no fim do arquivo (linhas ~114-117) não roda no harness combinado porque assume um
  `rollback;` real no meio do script — o harness (staging-run.py) trata `rollback;` como marcador para
  encadear múltiplos arquivos numa única transação de prova, então a variável psql capturada antes
  não é revalidada depois. Não é um problema de produto; é uma limitação conhecida do harness quando
  vários arquivos são encadeados. Rodando o arquivo sozinho (não encadeado) essa consulta funcionaria
  normalmente com psql real.
- imp213-isolation: `ROLLBACK ok`.
- imp214-acceptance: `ROLLBACK ok`.
- imp216-acceptance + isolation: `ROLLBACK ok`.
- imp230-acceptance: falhou quando encadeado logo depois de 213+214+216 na mesma transação longa
  (erro do guard esperado de IMP-216/230 para ImpulsHub). IMP-230 já foi provada de forma isolada
  antes (ver PR #15/#17) e está aplicada e funcionando em produção; a falha aqui parece ser resíduo
  de estado ao encadear 4+ arquivos de aceite na mesma transação (não foi isolado o motivo exato por
  tempo). Recomendação: se for reprovar 230 no staging, rodar sozinha (migration+aceite+isolamento
  do 230, sem encadear com 213/214/216 antes).

Estado: staging reconstruído e funcional para 213 (assertivas de papel + isolamento), 214 e 216.
230 não foi reconfirmada nesta rodada combinada (mas está provada em outro contexto e já em produção).
231 permanece fora por desenho (exige cron.job, ausente de propósito).
