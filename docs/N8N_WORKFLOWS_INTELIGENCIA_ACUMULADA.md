# ImpulsHub — n8n: Workflows, JSONs e Inteligência Acumulada

> Documento complementar ao `BANCO_DE_DADOS.md`.
> Esta versão fecha o ciclo de trabalho de 11/07/2026: leitura dos 10 JSONs de
> produção, criação da tabela de logs, instrumentação de todos os workflows,
> e fusão do backfill Meta em um só fluxo. Tudo abaixo foi **implementado e
> confirmado em produção nesta mesma sessão**, não é só recomendação.

**Última atualização:** 11/07/2026 (fechamento do dia)
**Escopo:** os workflows de produção do ecossistema ImpulsHub, agora **9**
(eram 10 — `0.1` e `0.2` viraram um só), todos com log de execução.

---

## 0. Resumo do que foi feito hoje (nessa ordem)

1. Lidos os 10 JSONs de produção reenviados — inventário confirmado
   diretamente no arquivo (seção 2).
2. Criada `public.workflow_execution_logs` no Supabase — resumo + etapas-chave
   por execução, com vínculo de cliente (seção 12).
3. Criado `9.9 - Log Workflow Error` — workflow compartilhado de captura de
   erro, referenciado no `Settings → Error Workflow` dos 9 workflows de
   produção (seção 12.4). Levou um patch no mesmo dia (`and status = 'running'`)
   depois que o desenho dos logs por conta em `2.1`/`2.2` expôs um bug em
   potencial nele.
4. Instrumentados com log de abertura/fechamento, um por um, nesta ordem:
   `1.1` → `1.2`/`1.3` → `2.1`/`2.2` → `0.1`+`0.2` (fundidos) → `0.0`/`0.3`/`0.4`.
5. **Fusão decidida e aplicada em produção**: `0.1 - Meta Ads Backfill
   Performance` e `0.2 - Meta Ads Creative Enrichment Only` viraram um único
   workflow (seção 6.1). As versões antigas foram **arquivadas** no n8n.
6. Links entre workflows corrigidos manualmente na UI do n8n (`0.0` reapontado
   pros IDs novos de `0.1`-fusão, `0.3` e `0.4` — ver seção 0.1 abaixo).

Resultado: hoje, qualquer execução de qualquer um dos 9 workflows gera pelo
menos uma linha em `workflow_execution_logs`, com cliente vinculado quando
aplicável, e qualquer erro (instrumentado ou não) é capturado pelo `9.9`.

---

## 0.1 Lição operacional nova: `executeWorkflow` quebra ao reimportar

Toda vez que um workflow é reimportado como cópia nova (o padrão que usamos
o dia inteiro — "importa desativado, testa, só depois troca o ativo"), o n8n
atribui um **ID novo**. Qualquer outro workflow que chame aquele via nó
`executeWorkflow` (por `workflowId`, não por nome) **continua apontando pro
ID antigo** até alguém reabrir o node e reselecionar manualmente no dropdown.

Isso mordeu a gente hoje: depois de arquivar `0.1`/`0.2` antigos, o `0.0`
ainda chamava o ID arquivado. Foi corrigido na hora (`0.0` reapontado pros
IDs novos de `0.1`-fusão, `0.3` e `0.4`).

**Regra daqui pra frente:** sempre que um workflow for reimportado como
cópia nova, checar **quem mais o chama** via `executeWorkflow` antes de
arquivar a versão antiga. Hoje isso afeta:

```txt
0.0  chama  0.1-fusão, 0.3, 0.4
1.1  chama  1.2, 1.3
```

Se `1.2`/`1.3` também forem reimportados no futuro (não só editados in-place),
`1.1` precisa do mesmo tratamento.

---

## 1. Visão geral do papel do n8n (sem mudança de arquitetura)

```txt
GHL / Formulários / CRM
      ↓
1.1 Inbound Events (webhook /inbound-events)
      ↓
events_raw → events_normalized → conversion_outbox
      ↓              ↓                   ↓
 auditoria       dashboard      1.2 / 1.3 dispatch Meta/Google

Meta Ads / Google Ads APIs
      ↓
2.1 / 2.2 sync diário (05h / 05h15) · 0.1-fusão / 0.4 backfill 6 meses
      ↓
meta_ads_daily / google_ads_daily / google_ads_keywords_daily
      ↓
views v_* → dashboard

Todos os 9 workflows acima também escrevem em:
workflow_execution_logs (log de execução, ver seção 12)
```

---

## 2. Inventário atual — 9 workflows de produção

| # | Nome (arquivo) | Trigger | Categoria | Log instrumentado? |
|---|---|---|---|---|
| `0.0` | Agency Onboarding - Clients Base | Webhook `agency/onboarding-client` | onboarding | ✅ 1 linha/execução |
| `0.1` (fusão) | Meta Ads - Backfill Last 6 Months (Performance + Criativos) | Execute Workflow Trigger (chamado por `0.0`) | backfill | ✅ 1 linha/execução |
| `0.3` | Google Ads - Google Conversion Actions | Manual + Execute Workflow Trigger (chamado por `0.0`) | onboarding | ✅ 1 linha/execução, 3 desfechos possíveis |
| `0.4` | Google Ads - Backfill Last 6 Months | Execute Workflow Trigger (chamado por `0.0`) | backfill | ✅ 1 linha/execução |
| `1.1` | Inbound Events - Normalize + Conversion Router | Webhook `inbound-events` | eventos | ✅ 1 linha/execução, com estágio `client_not_found` |
| `1.2` | Dispatch Single Meta Conversion | Execute Workflow Trigger (chamado por `1.1`) | dispatch | ✅ 1 linha/execução |
| `1.3` | Dispatch Single Google Ads Conversion | Execute Workflow Trigger (chamado por `1.1`) | dispatch | ✅ 1 linha/execução |
| `2.1` | Meta Ads - Daily Sync | Manual + Schedule diário **05h00** | media_sync | ✅ 1 linha **por conta** dentro do loop |
| `2.2` | Google Ads - Daily Sync - Unificado | Manual + Schedule diário **05h15** | media_sync | ✅ 1 linha **por conta** (sem loop node — 1 item por conta) |

Mais o workflow de suporte:

| Workflow | Função |
|---|---|
| `9.9 - Log Workflow Error` | Error Trigger compartilhado — captura falha de qualquer nó de qualquer um dos 9 acima e fecha a linha de log como `status='error'` |

---

## 3. Workflow `1.1` — contrato de normalização (lógica inalterada)

Sem mudança de lógica de negócio desde a versão anterior deste documento —
só ganhou logging (seção 12). Fluxo:

```txt
Webhook (POST /inbound-events)
→ Normalize Raw Event → Insert Raw Event  [abre log: stage=raw_inserted]
→ Get Raw Event + Client (LEFT JOIN clients_base por ghl_location_id)
→ Normalize Event
→ IF Client Found
    → sim: Upsert Normalized Event → Mark Raw as Normalized   [fecha log: success]
    → não: Mark Raw as Client Not Found                        [fecha log: error, stage=client_not_found]
→ Build Platform Conversion Jobs → Upsert Conversion Outbox
→ Prepare Platform Dispatch Input
→ IF Should Dispatch Meta → Call 1.2
→ IF Should Dispatch Google → Call 1.3
→ Respond to Webhook
```

---

## 4. Workflows `1.2` / `1.3` — Dispatch (lógica inalterada)

```txt
When Executed by Workflow → Normalize Dispatch Input
→ Get Single Meta/Google Outbox   [abre log: já tem client_id/client_name herdados de events_normalized]
→ Build Request → IF Should Send
→ Send / (skip) → Finalize Response
→ Update Single Outbox Result     [fecha log: status mapeado de sent/skipped/failed → success/skipped/error]
```

---

## 5. Roteamento de conversões (sem mudança)

| `event_code` | Meta | Google | Elegível? |
|---|---|---|---|
| `lead` | `Lead` (ou `LeadSubmitted` via WhatsApp BM) | `Lead` | Sim |
| `agendado` | `Schedule` (ou `QualifiedLead` via WhatsApp BM) | `Agendou` | Sim |
| `ganho` | `Purchase` | `Compra` | Sim, com valor |
| `primeira_conversa` | — | — | Não |
| `perdido` | — | — | Não |

---

## 6. Workflows de mídia

### 6.1 `0.1` — Meta Backfill, agora fundido com o antigo `0.2`

**Decisão de 11/07/2026, aplicada em produção:** o antigo par
`0.1` (performance) → chama → `0.2` (creative enrichment) virou **um workflow
só**. O `0.2` foi colado inteiro no ponto exato onde `0.1` antes fazia a
chamada via `executeWorkflow` — mesma lógica interna, zero nós reescritos.

```txt
Execute Workflow Trigger → Mark Running   [abre log: 1 linha, client_id/slug/name]
→ Get Meta Accounts → Build Account Chunks
→ Meta Insights - Ad Level Daily → Upsert Meta Ads Daily
→ Mark Completed → Build Payload (client_id/slug/name)
→ [ex-0.2] Get Meta Creative Accounts → Loop Over Meta Accounts
   → Fetch Creative Details → Enrich Meta Daily
   → Fetch 9x16 Images → Update Meta Daily With Images
   → volta pro loop até acabar as contas
→ Mark Meta Creative Enrichment Completed   [fecha log]
```

**Trade-off aceito conscientemente:** não dá mais pra rodar só o
enriquecimento de criativo isoladamente (sem repuxar 6 meses de performance
de novo). O `0.2` original **foi arquivado hoje** — se um dia precisar
recuperar a capacidade de "só criativo", o JSON original fica preservado
neste histórico de conversa/backups.

**Por que só 1 linha de log, e não por conta:** diferente do `2.1`/`2.2`
(sync diário, que misturam contas de clientes diferentes numa execução), o
`0.1`-fusão sempre roda pra **1 cliente por execução** — mesmo que esse
cliente tenha 2-3 contas Meta passando pelo loop de criativo internamente.

### 6.2 `2.1` — Meta Daily Sync (05h00)

Sem mudança de lógica. Log **por conta**, porque cada execução varre contas
de clientes diferentes num mesmo loop (`splitInBatches`):

```txt
Loop Over Meta Accounts (item = 1 conta)
  → [abre log em paralelo]
  → Meta Insights - Daily Sync → Upsert → Creative Enrichment → Update 9x16
  → [fecha log em paralelo, filtrando client_id + status='running']
  → volta pro loop
```

### 6.3 `2.2` — Google Daily Sync Unificado (05h15)

Confirmado: **não usa loop** (`splitInBatches`) — o próprio comentário do
código original diz que o n8n roda o HTTP uma vez por item automaticamente.
Ainda assim, log por conta, porque cada item ainda é uma conta:

```txt
Build Google Daily GAQL (item = 1 conta)
  → [abre log em paralelo]
  → SearchStream Performance → Upsert Daily → Creative GAQL → Creatives
  → Keyword GAQL → SearchStream Keywords → Upsert Keywords Daily
  → [fecha log em paralelo]
→ (todas as contas convergem) Build SQL - Mark Google Daily Sync Completed
  [agregado — NÃO é ponto de fechamento por conta, fica só como resumo geral]
```

### 6.4 `0.4` — Google Backfill

Sem mudança de lógica (já vinha performance + criativos no mesmo fluxo desde
sempre — não precisou de fusão como o Meta precisou). 1 cliente por execução,
1 linha de log, abre em `Mark Google Running`, fecha em `Mark Google
Completed`.

---

## 7. Workflow `0.0` — Agency Onboarding

```txt
Webhook (agency/onboarding-client)
→ Normalize + Validate + Build SQL → Upsert clients_base   [abre log]
→ Build SQL - Upsert Meta/Google Accounts (paralelo)
→ Prepare 06 Payload → Call 0.3 (fire-and-forget)
→ IF/IF1 → Call 0.1-fusão (fire-and-forget)
→ IF - Should Call 08 → Call 0.4 (fire-and-forget)
→ Build Onboarding Response → Respond to Webhook            [fecha log]
```

**Importante sobre o log daqui:** cobre só a parte própria do `0.0`. As três
chamadas em cascata (`0.3`, `0.1`-fusão, `0.4`) são `waitForSubWorkflow:
false` — cada uma roda como execução independente e **já se auto-loga** com
seu próprio `n8n_execution_id`. Não dá pra (nem faz sentido) logar elas de
dentro do `0.0`.

Links reapontados hoje na UI do n8n depois da fusão/reimportação: `Call 06`
(→ `0.3` novo), `Call '07...'` (→ `0.1`-fusão), `Call 08` (→ `0.4` novo).

## 8. Workflow `0.3` — Google Conversion Actions

3 desfechos possíveis, 3 pontos de fechamento de log:

| Desfecho | `status` do log | `stage` |
|---|---|---|
| API do Google chamada e `clients_base` atualizado | `success` | `conversion_actions_synced` |
| API chamada mas achou que não devia atualizar (preview) | `success` | `preview_only_no_update` |
| Nem chegou a chamar a API do Google | `skipped` | `google_call_skipped` |

---

## 9. Correção crítica: atribuição Meta Lead Ads / Form Nativo (sem mudança)

Continua válida — 131 de 177 leads de Form Nativo (74%) com atribuição
corrigida; 46 seguem sem causa identificada. Ver `BANCO_DE_DADOS.md` seção 7.

---

## 10. Workflows temporários da Royal (sem mudança)

Fora do escopo desta rodada — não fazem parte dos 9 workflows de produção
atuais. Mantidos como histórico nas versões anteriores deste documento.

---

## 11. Regras operacionais (atualizadas)

- Nunca dois workflows ativos no mesmo path de webhook (`agency/onboarding-client`,
  `inbound-events`).
- Para atualizar qualquer um dos 9: importar como cópia/desativado, testar,
  só depois trocar o ativo.
- **Novo (seção 0.1):** antes de arquivar a versão antiga de um workflow,
  checar quem mais o chama via `executeWorkflow` e reapontar manualmente
  na UI do n8n. Isso não é automático nem é possível de resolver só no JSON.
- Antes de qualquer backfill: snapshot, pausar dispatchers, flags de
  segurança, dry-run quando possível.
- Todo workflow novo/reimportado deve ter `Settings → Error Workflow`
  apontando pro `9.9 - Log Workflow Error`.

---

## 12. Tabela de logs de execução — implementada

Tabela `public.workflow_execution_logs` no Supabase (schema completo em
`SUPABASE_WORKFLOW_LOGS_SCHEMA.sql`, já aplicado). Resumo das decisões:

- Granularidade: **resumo por execução + etapas-chave**.
- Estrutura: **tabela única** com coluna de categoria
  (`onboarding` / `events` / `dispatch` / `media_sync` / `backfill`).
- Cliente: `client_id` (FK nullable) + `client_slug`/`client_name`
  denormalizados — sobrevive a casos como `1.1` com `client_not_found`
  (onde só existe `ghl_location_id`, sem cliente resolvido ainda).
- **Granularidade por workflow** (decidido caso a caso, ver seções 3-8):
  - 1 linha por execução: `0.0`, `0.1`-fusão, `0.3`, `0.4`, `1.1`, `1.2`, `1.3`
  - 1 linha por conta dentro da execução: `2.1`, `2.2` (únicos que misturam
    clientes diferentes numa mesma execução)

### 12.1 `9.9 - Log Workflow Error`

Error Trigger compartilhado, referenciado no `Settings → Error Workflow` dos
9 workflows. Query final:

```sql
update public.workflow_execution_logs
set status = 'error', error_message = ..., error_node = ..., finished_at = now()
where n8n_execution_id = ...
  and status = 'running'   -- patch de 11/07, ver abaixo
```

**Por que o patch `and status = 'running'`:** sem ele, num workflow com
múltiplas linhas por execução (`2.1`/`2.2`), um erro numa conta reabriria
como erro a linha de uma conta anterior que já tinha fechado com sucesso na
mesma execução.

**Limitação conhecida, aceita por ora:** só atualiza log que já existe. Se o
workflow falhar antes do próprio nó de abertura do log rodar, não há linha
pra atualizar. Cobre a grande maioria dos casos reais.

### 12.2 Views de consumo (dashboard)

- `v_client_workflow_health` — client-facing, RLS herdada, sem detalhe
  técnico de erro.
- `v_workflow_health_daily` — agregado interno da agência, por dia/workflow/
  cliente, com contagem de sucesso/erro e duração média.

---

## 13. Pendências e pontos de atenção (atualizado, fechamento 11/07)

1. ~~Confirmar no n8n qual JSON está ativo em produção~~ — **resolvido**:
   9 workflows confirmados e todos com log ativo.
2. ~~Nenhum workflow tinha Error Workflow configurado~~ — **resolvido**: `9.9`
   criado e referenciado nos 9.
3. **Repontar `executeWorkflow` após reimportar** — não é mais "pendência",
   virou regra operacional permanente (seção 11). Fazer sempre que uma cópia
   nova for ativada no lugar de uma antiga.
4. **Drift de nomenclatura interno** (`cachedResultName` desatualizado) —
   deve estar bem menor agora que os links foram todos reapontados hoje;
   vale uma conferida visual rápida da próxima vez que alguém abrir `1.1`
   ou `0.0` no editor.
5. Critério exato das condicionais de backfill em `0.0` (`If`, `If1`, `IF -
   Should Call 08...`) segue sem documentação explícita da regra de negócio
   por trás — não bloqueou o trabalho de hoje, mas ainda vale mapear.
6. Conversões Google por tipo — ainda sem solução (roadmap de longo prazo).
7. Monitorar novos Formulários Nativos Meta — os 46 casos sem atribuição
   seguem em aberto.
8. **Novo:** validar depois de alguns dias rodando que `v_workflow_health_daily`
   e `v_client_workflow_health` estão populando como esperado, e que os
   `2.1`/`2.2` realmente geram várias linhas por execução (uma por conta) —
   é a parte mais nova/menos testada do desenho.
9. **Novo:** decidir o que fazer com o `0.2` original arquivado — manter
   arquivado indefinidamente, ou formalizar em algum lugar (este documento
   já serve como registro) que a capacidade de "só creative enrichment"
   deixou de existir como fluxo separado.

---

## 14. Resumo executivo

Em uma única sessão de trabalho (11/07/2026), o ImpulsHub ganhou observabilidade
de ponta a ponta sobre seu pipeline n8n: uma tabela de log centralizada com
vínculo de cliente, um workflow de captura de erro compartilhado, e
instrumentação de abertura/fechamento em todos os 9 workflows de produção —
com granularidade ajustada caso a caso (por execução vs. por conta, conforme
o workflow mistura ou não clientes numa mesma execução). Paralelamente, os
dois workflows de backfill Meta (`0.1` performance + `0.2` criativos) foram
fundidos em um só, reduzindo o inventário de 10 para 9 workflows e
simplificando o mapa mental de "1 backfill Meta = 1 fluxo". A lição
operacional mais importante que fica registrada pro futuro: **workflows
reimportados como cópia nova quebram silenciosamente quem os chama via
`executeWorkflow`, até alguém reapontar manualmente na UI** — isso agora é
checklist padrão (seção 11), não surpresa.
