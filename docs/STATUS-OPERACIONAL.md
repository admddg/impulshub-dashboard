# Status operacional

**Fonte de verdade operacional do projeto.** Reconciliado em **25/09/2026**,
partindo de `origin/main` no commit **`d4f37a42c80c67d7ced6ad4a9bc72336d23c2464`**.

Este documento separa estado verificado de relato. Não substitui o ROADMAP e não
inclui onboarding, criativos ou os clientes Royal, Central e QuickClean.

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
- Onboarding está explicitamente fora desta onda.

## Confirmado em produção

| Área | Estado confirmado | Evidência / data |
|---|---|---|
| GitHub | `main` em `d4f37a4` com PRs #25/#26/#27/#29/#31 mergeados | GitHub, leitura em 25/09/2026 |
| Parser | Tie fix de `stage_history` aplicado | PR #26 e runbook `docs/incidentes/RUNBOOK-PRODUCAO-17TPEPCDUFJ.md` |
| Parser cron | Ativo; últimas execuções observadas como `succeeded` | leitura operacional somente leitura em 25/09/2026 |
| Raw elegível Impuls | **0** mensagens elegíveis | leitura operacional somente leitura em 25/09/2026 |
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
- **Onboarding:** fora do escopo e não deve ser alterado ou marcado nesta onda.

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
