# ImpulsHub — Arquitetura do Dashboard

**Última atualização:** 17/07/2026 — migração frontend V2 concluída.

---

## Camadas de dados

```
Tabelas brutas (Supabase/Postgres)
  └── Views canônicas V2 (uma por entidade/canal)
        └── Consolidado (v_client_performance_daily_v2 + get_client_overview_v2)
              └── RPCs de detalhe (get_meta_ads_summary_v2, get_google_ads_summary_v2)
                    └── Frontend Next.js (dashboard)
```

**Regra de ouro:** o frontend consome fontes oficiais e não recria
metodologia. Não recalcula atribuição, deduplicação, estágio de jornada,
vendas, receita, CAC, ROAS ou vínculos de criativo.

---

## As duas réguas de análise

Todo número no dashboard responde a **uma** de duas perguntas:

| Régua | Pergunta | Data de referência | Abas |
|---|---|---|---|
| **A — Coorte** | O que aconteceu com os leads que entraram no período? | `lead_date` | Visão Geral, Funil, Canais, Meta Ads, Google Ads |
| **B — Diário** | O que aconteceu em cada dia? | Data real do evento | Diário, Eventos, Leads |

Uma aba inteira responde A **ou** B — nunca as duas misturadas.

---

## Mapa: fonte → aba

| Aba | Fonte principal | Régua | O que entrega |
|---|---|---|---|
| **Visão Geral** | `get_client_overview_v2()` + `v_client_performance_daily_v2` | A | KPIs executivos (Investimento, Leads, Agendamentos, Receita, Ganhos, CPL, CAC, ROAS) + gráfico diário |
| **Funil** | `v_crm_funnel_daily_v2` | A | Lead → Conversa → Agendado → Ganho, total agregado sem quebra por canal |
| **Canais** | `v_crm_channels_daily_v2` | A | 3 seções: Atribuição técnica / Entrada informada / Origem informada |
| **Meta Ads** | `get_meta_ads_summary_v2()` | A | 4 sub-abas: Contas / Campanhas / Anúncios / Criativos |
| **Google Ads** | `get_google_ads_summary_v2()` + `v_google_ads_v2` + `v_google_keywords_v2` | A + B | Tabela de campanhas (A) + gráficos diários (B) + keywords |
| **Leads** | `v_client_leads_by_stage_v2` | B | Lista de pessoas com etapa atual, plataforma atribuída e origem, paginada (50/página) |
| **Eventos** | `v_crm_events_feed_v2` | B | Feed dos últimos 50 eventos, atualização manual |
| **Diário** | `v_crm_events_daily_v2` + `v_client_performance_daily_v2` | B | Pulso dia a dia: eventos + investimento + vendas fechadas |
| **Operação** | `v_workflow_health_daily` + `v_client_workflow_health` | — | Saúde dos workflows n8n — só para usuários multi-cliente |

---

## Rotas

```
/login
/dashboard                          redirecionador: 1 cliente → direto; vários → /clientes
/clientes                           seletor de clientes (multi-cliente)
/clientes/[client_slug]/dashboard   dashboard principal (8 abas)
/operacao                           painel interno da agência (só multi-cliente)
```

---

## Segurança multi-cliente

- `lib/access.ts`: `getMyClients()` lista clientes do usuário logado;
  `resolveClient(slug)` valida acesso via RLS de `v_client_profile_safe`.
- `lib/data.ts`: `fetchWindowed`/`fetchAll` exigem `clientId` e filtram
  `.eq('client_id', clientId)` em toda query.
- RLS nas tabelas base garante que um `client_id` ao qual o usuário não
  tem acesso retorne vazio — mesmo via chamada direta de RPC.
- `/operacao` só aparece para `multiClient` no frontend, e a própria view
  `v_workflow_health_daily` bloqueia no banco (subquery de contagem de
  clientes ativos do usuário > 1).

---

## Meta Ads — carregamento sob demanda

A aba Meta tem 4 sub-abas (Contas, Campanhas, Anúncios, Criativos). Cada
uma faz uma chamada separada à RPC `get_meta_ads_summary_v2`. Para evitar
4 chamadas simultâneas ao abrir (que causava lentidão e timeouts em 90
dias), o carregamento é **sob demanda**:

- Ao abrir a aba Meta, só a dimensão `account` é buscada.
- Cada sub-aba só carrega quando o usuário clica nela pela primeira vez.
- Dados já carregados ficam em cache enquanto cliente e período não mudarem.
- Se a RPC falhar (ex: timeout), aparece botão "Tentar novamente" — não
  silencia o erro com tabela vazia.

Cache invalidado ao trocar de cliente ou período.

---

## Hierarquia de nome do criativo (Meta)

Conforme contrato banco 16/07:

```
Título    → ad_name || creative_name || creative_id || "Criativo sem nome"
Subtítulo → headline (quando diferente do título)
```

`headline` nunca é título principal. `creative_name` é fallback/auditoria.

---

## Formatação de valores ausentes

Conforme contrato V2 — NULL não é zero:

| Situação | Exibição |
|---|---|
| Receita sem valor preenchido | `—` |
| ROAS quando receita incompleta | `—` |
| CAC sem compradores | `—` |
| CPL sem leads pagos | `—` |
| Leads/agendados zero | `0` (é zero real) |

---

## Seletor de período

**Opções:** 15 dias / 30 dias / 90 dias / Datas personalizado.
**Padrão ao abrir:** 30 dias.

"7 dias" foi removido — períodos curtos distorcem métricas de coorte (leads
não tiveram tempo de maturar). Cada período mostra comparativo vs. o período
anterior de mesmo tamanho.

---

## Componentes principais

| Componente | Responsabilidade |
|---|---|
| `DashboardClient.tsx` | Resolve slug, valida acesso, renderiza abas e seletor de período |
| `KpiCard.tsx` | Card de métrica com valor, comparativo e variação |
| `DataTable.tsx` | Tabela ordenável com suporte a `tooltip` em cabeçalhos e linha de total |
| `Charts.tsx` | `LineTimeChart`, `HBarChart`, `ColumnChart` |
| `CohortNote.tsx` | Banner retrátil explicando a lógica de coorte (Meta, Google, Funil) |
| `DailyPulseNote.tsx` | Banner retrátil explicando a régua diária (aba Diário) |
| `Lightbox.tsx` | Zoom de imagem de criativo |
| `PeriodSelector.tsx` | Seletor 15/30/90/Datas |
| `lib/data.ts` | `fetchWindowed` (com filtro de data), `splitByDate`, `fetchAll` |
| `lib/utils.ts` | `getRanges`, `brl`, `int`, `num`, `hiResImg` e helpers de formatação |
| `lib/access.ts` | `getMyClients`, `resolveClient`, `multiClient` |

---

## Ver também

- `docs/BANCO_DE_DADOS.md` — schema, RLS, funções, RPCs e o histórico
  de decisões metodológicas.
- `docs/DIARIO_PROJETO.md` — linha do tempo e bugs encontrados.
- `N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md` — os 9 workflows de produção.
