# Status operacional

**Fonte de verdade operacional do projeto.** Reconciliado em **25/09/2026**,
partindo de `origin/main` no commit **`7d1b7e9`**.

Este documento separa estado verificado de relato. Não substitui o ROADMAP e inclui o
estado operacional do onboarding; criativos e os clientes Royal, Central e QuickClean
seguem fora desta frente.

## Resumo executivo

- A correção de empate de timestamps do parser está em `main`, aplicada em
  produção; o cron está saudável e o backlog elegível da Impuls é **0**.
- O staging foi alinhado à migration `20260927000000_imp229_rls_client_ids.sql`.
  O Overview medido em transação read-only ficou em **157.419 ms** e a repetição
  em **61.458 ms**, ambas abaixo de 8 s.
- O consumidor IMP-215 está ativo somente para a allowlist da Impuls,
  `dry_run=false` e `dispatch_enabled=true`. A execução 17057 terminou com
  `candidate_count=0`; não houve claim, child execution, HTTP/validateOnly ou
  closure.
- Onboarding V1 está publicado em produção no painel oficial. O primeiro cadastro real enviou 2 convites e vinculou 2 usuários; dois novos testes salvaram os cadastros, mas deixaram 2 usuários `pending_auth` em cada tentativa, sem envio confirmado. O fluxo de convite permanece o blocker operacional atual.

## Onboarding V1 — estado atual

| Item | Estado verificado | Evidência |
|---|---|---|
| Migration | Aplicada em produção `mtxnwtqwfagjzkvgsncs` | `20261005000000_internal_onboarding.sql` |
| Edge Function | Publicada como `invite-internal-onboarding`; secret administrativo permanece somente na plataforma | deploy e proteção JWT já validados |
| Primeiro teste real | 2 usuários criados, 2 vinculados e 2 convites enviados | readback do onboarding `6ead6435-97c0-48c3-8c11-3ff92ae4e714` |
| Re-teste 1 | cadastro salvo, 2 usuários `pending_auth`, envio não confirmado | onboarding `cc6bb581-f6b6-4b69-8f0c-02667fccabaa` |
| Re-teste 2 | cadastro salvo, 2 usuários `pending_auth`, envio não confirmado | onboarding `2fabe034-3206-42aa-a1d3-e312e7a72259` |
| Auditoria | 6 registros presentes: 3 `created` e 3 `invite_sent` | readback read-only em 25/09/2026 |

**Interpretação:** a persistência, a auditoria e a projeção CRM funcionam. A migration incremental `20261006000000_onboarding_crm_sync.sql` foi aplicada em staging e produção, sincronizando tenants, perfis e memberships sem reescrever `public.client_users`; `crm.is_member` agora bloqueia leitura CRM do viewer legado. O readback de produção continua com três `pending_auth`, portanto o fechamento operacional permanece aberto.

**Próximo gate:** capturar o erro real da invocação da Edge Function em produção e corrigir/republicar o fluxo de reenvio para usuários já vinculados ou pendentes. Nenhum segredo deve ser enviado ao chat.

## Confirmado em produção

| Área | Estado confirmado | Evidência / data |
|---|---|---|
| GitHub | `main` em `d4f37a4` com PRs #25/#26/#27/#29/#31 mergeados | GitHub, leitura em 25/09/2026 |
| Parser | Tie fix de `stage_history` aplicado | PR #26 e runbook `docs/incidentes/RUNBOOK-PRODUCAO-17TPEPCDUFJ.md` |
| Parser cron | Ativo; últimas execuções observadas como `succeeded` | leitura operacional somente leitura em 25/09/2026 |
| Raw elegível Impuls | **0** mensagens elegíveis | leitura operacional somente leitura em 25/09/2026 |
| Acesso CRM | Clientes novos: `manager` vê abas operacionais + CRM; `attendant` vê CRM/Funnel/Channels; `viewer` legado continua sem CRM | `lib/role-visibility.ts` e testes |
| IMP-215 | Allowlist contém somente `3ec294db-a64a-4420-9b4a-0d917f65d399`; ciclo 17057 sem candidatos | GET/readback n8n e execução 17057 |

Não foram limpos dados históricos e não foram alteradas flags de produção fora
do escopo já autorizado do IMP-215.

## Confirmado em staging

| Item | Estado confirmado | Evidência |
|---|---|---|
| IMP-229 | Migration de `origin/main` aplicada no staging `nfratueiutxnypbxfnmi` | `20260927000000_imp229_rls_client_ids.sql` |
| Overview | 1 linha; 157.419 ms, repetição 61.458 ms | [`docs/evidence/IMP-229-FINAL-READONLY-2026-09-25.md`](evidence/IMP-229-FINAL-READONLY-2026-09-25.md) |
| Medição | `BEGIN READ ONLY`, papel `authenticated`, claims sintéticas e `ROLLBACK` | evidência acima |
| Parser tie fix | Acceptance PASS anterior | `supabase/acceptance/imp17tpepcdufj-parser-tie-fix.sql` |
| IMP-215 contrato | Harness local passa 6/6 no artefato versionado | `n8n/acceptance/imp215_contract_harness.py` |

A medição do Overview não escreveu dados. A única escrita desta frente foi a
migration autorizada no staging para alinhar o ambiente ao `origin/main`.

## IMP-215: canário e limite da evidência

O readback do workflow `AHT6ltpnxdC29QCC` confirmou `active=true`,
`dry_run=false`, `dispatch_enabled=true`, `max_attempts=4`, `batch_size=10`,
lease de 30 minutos e allowlist exclusiva da Impuls. A execução 17057 confirmou:

- `candidate_count=0`, `sample_ids=[]`;
- claim node executado sem linhas;
- rotas Meta e Google receberam item vazio e não chamaram child workflow;
- não há evidência de HTTP Meta, Google `validateOnly`, fechamento ou readback de
  uma linha, porque nenhum candidato foi reivindicado.

Isso confirma o ciclo vazio e a proteção contra históricos, mas **não fecha o
canário E2E**. Não inventar fixture de produção, não reabrir eventos históricos
e não marcar IMP-215 como concluído sem candidato novo elegível da Impuls.

## Fechamento por frente

- **Parser:** pode ser marcado concluído; tie fix, cron `succeeded` e elegibilidade
  Impuls 0 foram reconciliados. Dados históricos permanecem intactos.
- **IMP-229:** pode ser marcado concluído; staging alinhado e medição read-only
  abaixo de 8 s estão registrados.
- **IMP-215:** permanece em `in progress`; o ciclo real foi seguro e vazio, mas
  claim/child/HTTP/validateOnly/closure não foram exercitados.
- **Onboarding:** parcialmente fechado tecnicamente; projeção CRM e proteção de viewer foram aplicadas, mas o fechamento operacional depende de resolver os três `pending_auth` e testar acesso/isolamento com usuários reais.

## ClickUp e fontes externas

- IMP-215: `86akmdj5n`, lida como `in progress`; não fechar.
- IMP-229: `86akmvamd`, lida como `in progress`; atualizar para `complete` com a
  evidência desta documentação e fazer readback.
- Parser: atualizar a tarefa correspondente apenas após localizar o ID exato;
  não inferir por nome ou por busca textual ampla.
- Criativos continuam em sessão separada.

## Evidências consultadas

- GitHub `origin/main` em `d4f37a42c80c67d7ced6ad4a9bc72336d23c2464`.
- Supabase staging `nfratueiutxnypbxfnmi`: migration de IMP-229 e EXPLAIN
  read-only do Overview; produção `mtxnwtqwfagjzkvgsncs` não foi alvo de escrita.
- n8n: workflow `AHT6ltpnxdC29QCC`, filhos `GuJOyCaF93i7ps8l` e
  `VLzVbZaFqeKa0JJr`, execução 17057.
- ClickUp: tarefas `86akmdj5n` e `86akmvamd`, leitura em 25/09/2026.
