# Status operacional

**Fonte de verdade operacional do projeto.** Reconciliado em **25/09/2026**,
partindo de `origin/main` no commit **`53b1ad09ad414a1f4cf693bcbc1db25bc060f0cc`**.

Este documento registra o estado observado entre GitHub, Supabase, Vercel, n8n
e ClickUp. Ele não substitui o [ROADMAP](ROADMAP.md): o ROADMAP continua sendo
direção de produto; este arquivo é o inventário operacional datado. Nenhuma
migration, flag, DNS, código de produção ou workflow de produção foi alterado
nesta reconciliação.

## Resumo executivo

- `main` contém os PRs **#25, #26, #27 e #29**, todos mergeados.
- A correção do empate de timestamps do parser está em `main`, foi aplicada em
  produção e o acceptance correspondente em staging foi **PASS**.
- O parser continua ativo por cron; as últimas execuções observadas foram
  `succeeded`.
- Não há mensagens brutas elegíveis da Impuls para envio: **0**.
- Os artefatos de workflow do **IMP-215** estão versionados no n8n, porém
  **inativos**. O primeiro envio externo do IMP-215 ainda não ocorreu.
- O projeto Vercel é `impulshub-painel` e a URL de produção é
  [`https://painel.impulshub.com`](https://painel.impulshub.com).
- O domínio oficial da operação é [`impulshub.com`](https://impulshub.com).
  `painel.impulshub.com.br` foi um endereço incorreto e não é oficial.

## Confirmado em produção

| Área | Estado confirmado | Evidência / data |
|---|---|---|
| GitHub | `main` em `53b1ad0` (SHA completo no cabeçalho) com PRs #25/#26/#27/#29 mergeados | GitHub, leitura em 25/09/2026: [#25](https://github.com/admddg/impulshub-dashboard/pull/25), [#26](https://github.com/admddg/impulshub-dashboard/pull/26), [#27](https://github.com/admddg/impulshub-dashboard/pull/27), [#29](https://github.com/admddg/impulshub-dashboard/pull/29) |
| Vercel | Projeto `impulshub-painel`; produção em `https://painel.impulshub.com` | Inspeção somente leitura do projeto/deployment em 25/09/2026 |
| Parser | Correção de empate de `stage_history` aplicada em produção | PR #26 mergeado em `53b1ad0`; runbook e evidência em [`docs/incidentes/RUNBOOK-PRODUCAO-17TPEPCDUFJ.md`](incidentes/RUNBOOK-PRODUCAO-17TPEPCDUFJ.md) |
| Parser cron | Ativo; últimas execuções observadas como `succeeded` | Verificação somente leitura do cron/execuções em 25/09/2026 |
| Raw elegível | Mensagens `Impuls` elegíveis para o caminho de conversão: **0** | Leitura operacional somente leitura em 25/09/2026 |
| Envio externo IMP-215 | Ainda não ocorreu | n8n inativo e sem ativação autorizada; ver bloqueios |

### Correções documentais de produção

- A referência antiga a um commit de produção anterior ao CRM publicado não é
  mais válida. O estado atual deve ser lido pelo commit do cabeçalho e pela
  URL oficial acima.
- O domínio oficial não é `.com.br`. Não usar `painel.impulshub.com.br` em
  links, instruções de acesso ou critérios de aceite.

## Confirmado em staging

| Item | Estado confirmado | Evidência / data |
|---|---|---|
| Parser tie fix | Acceptance **PASS** em staging | [`supabase/acceptance/imp17tpepcdufj-parser-tie-fix.sql`](../supabase/acceptance/imp17tpepcdufj-parser-tie-fix.sql), PR [#26](https://github.com/admddg/impulshub-dashboard/pull/26) |
| Segurança do IMP-215 | Harness/claim/lease e fechamento protegido provados em staging conforme evidência do PR | PR [#25](https://github.com/admddg/impulshub-dashboard/pull/25) |
| Efeito colateral | Nenhuma fixture de acceptance deve persistir; não houve escrita em produção nesta entrega | [`docs/incidentes/RUNBOOK-PRODUCAO-17TPEPCDUFJ.md`](incidentes/RUNBOOK-PRODUCAO-17TPEPCDUFJ.md) |

"PASS em staging" não significa envio externo nem ativação em n8n de produção.

## Mergeado, mas não exercitado como operação externa

- **IMP-215:** o contrato claim/dispatcher, o consumidor agendado e os
  dispatchers Meta/Google estão versionados e protegidos, mas permanecem
  inativos. O caminho externo não foi exercitado.
- **PR #27:** a fronteira de fallback de criativos foi mergeada. O refresh
  operacional de URLs/ativos de criativos é separado e não foi executado por
  este trabalho.
- **PR #29:** a separação dos typechecks do app e da Edge Function foi
  mergeada; isso é uma correção de CI, não uma prova de envio externo.

## Bloqueios e incertezas reais

1. **IMP-229** ainda depende de medição de staging alinhada antes de ser
   considerado encerrado operacionalmente. O código mergeado não substitui a
   medição comparável.
2. **Refresh operacional de criativos** é um gate separado do fallback de UI
   do PR #27. Não declarar URLs renovadas sem executar e medir esse processo.
3. **Primeiro envio externo do IMP-215** não ocorreu. Não ligar workflows,
   flags ou consumidores para transformar `0` em envio sem autorização e gate
   específico.
4. O status do n8n não autoriza inferir que uma execução `succeeded` de um
   workflow existente equivale a entrega externa do IMP-215.

## Próximos gates

1. Registrar a medição de staging alinhada que falta para o IMP-229.
2. Definir e revisar o corte/allowlist do primeiro canário do IMP-215.
3. Obter autorização explícita para ativação controlada, executar o acceptance
   aplicável e observar o primeiro envio externo sem reabrir linhas antigas.
4. Tratar o refresh operacional de criativos como tarefa própria, com evidência
   separada do fallback de interface.
5. Atualizar este documento com data, commit e evidência após cada gate; não
   usar o ROADMAP como inventário diário.

## Fontes consultadas

- GitHub: `origin/main` em `53b1ad09ad414a1f4cf693bcbc1db25bc060f0cc` e PRs
  [#25](https://github.com/admddg/impulshub-dashboard/pull/25),
  [#26](https://github.com/admddg/impulshub-dashboard/pull/26),
  [#27](https://github.com/admddg/impulshub-dashboard/pull/27) e
  [#29](https://github.com/admddg/impulshub-dashboard/pull/29), leitura em
  25/09/2026.
- Supabase `Clients_Base` (`mtxnwtqwfagjzkvgsncs`): leituras operacionais do
  parser, cron e elegibilidade raw; nenhum comando mutável foi executado nesta
  reconciliação.
- Supabase staging: acceptance e evidências versionadas em
  [`supabase/acceptance`](../supabase/acceptance).
- Vercel: projeto `impulshub-painel` e deployment de produção, leitura em
  25/09/2026.
- n8n: leitura de workflows e execuções em 25/09/2026. Os três artefatos
  `IMP-215` foram encontrados com `active=false`; workflows existentes de
  entrada/dispatch reportaram execuções recentes `success`.
- ClickUp: tarefa `ETAPA 5 — IMP-215 — Ninguém consome a conversion_outbox`
  em `in progress` e tarefa `IMP-229 — Overview estourava o timeout de 8 s`
  em `in progress`, leitura em 25/09/2026.
