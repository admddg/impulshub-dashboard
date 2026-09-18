# ImpulsHub — Arquitetura do frontend

> Estrutura do app, convenções de UI e decisões de design já tomadas.

---

## Rotas

```
/login                              autenticação Supabase
/dashboard                          redirecionador: 1 cliente → direto
                                    vários → /clientes
/clientes                           seletor multi-cliente
/clientes/[client_slug]/dashboard   dashboard principal (8 abas)
/operacao                           painel interno da agência
```

**Regra de ouro do multi-cliente:** o slug na URL **escolhe** qual cliente
olhar, mas **nunca concede acesso**. `lib/access.ts` resolve o slug para
`client_id` consultando `v_client_profile_safe` — protegida por RLS. Um
slug sem permissão retorna vazio e o app bloqueia.

**`/operacao`** foge do padrão por cliente (é agência-wide). Só aparece no
menu para usuários multi-cliente, e a própria view no banco bloqueia quem
não se qualifica.

---

## Mapa: aba → fonte

| Aba | Fonte | Régua |
|---|---|---|
| **Visão Geral** | `get_client_overview_v2()` + `v_client_performance_daily_v2` | A |
| **Funil** | `v_crm_funnel_daily_v2` | A |
| **Canais** | `v_crm_channels_daily_v2` | A |
| **Meta Ads** | `get_meta_ads_summary_v2()` | A |
| **Google Ads** | `get_google_ads_summary_v2()` + `v_google_ads_v2` + `v_google_keywords_v2` | A + B |
| **Leads** | `v_client_leads_by_stage_v2` | B |
| **Eventos** | `v_crm_events_feed_v2` | B |
| **Diário** | `v_crm_events_daily_v2` + `v_client_performance_daily_v2` | B |
| **Operação** | `v_workflow_health_daily` + `v_client_workflow_health` | — |

---

## Componentes

| Arquivo | Responsabilidade |
|---|---|
| `components/DashboardClient.tsx` | Resolve slug, valida acesso, renderiza abas e seletor de período |
| `components/KpiCard.tsx` | Card de métrica. Props: `label`, `value`, `prefix`, `suffix`, `current`, `previous`, `prevLabel`, `primary`, `small`, `invert` |
| `components/DataTable.tsx` | Tabela ordenável. `Column<T>` aceita `tooltip` opcional no cabeçalho e `totalRow` |
| `components/Charts.tsx` | `LineTimeChart`, `HBarChart`, `ColumnChart` |
| `components/CohortNote.tsx` | Banner retrátil explicando coorte (Meta, Google, Funil) |
| `components/DailyPulseNote.tsx` | Banner retrátil explicando régua diária (Diário) |
| `components/Lightbox.tsx` | Zoom de imagem de criativo |
| `components/PeriodSelector.tsx` | Seletor 15/30/90/Datas |
| `lib/data.ts` | `fetchWindowed` (com filtro de data), `splitByDate`, `fetchAll` |
| `lib/utils.ts` | `getRanges`, `brl`, `int`, `num`, `hiResImg`, tipos `Period`/`CustomRange` |
| `lib/access.ts` | `getMyClients`, `resolveClient` |
| `lib/supabase.ts` | Cliente Supabase configurado |

### Detalhes importantes de componentes

**`KpiCard`** — o `prefix` (ex: `"R$"`) é renderizado **separadamente** do
`value`. Passar `brl(v)` sem "R$" no value, senão duplica o símbolo.
(Erro já cometido duas vezes.)

**`num()` do utils** — converte `null` para `0`. Quando `NULL` tem
significado semântico (dado indisponível), tratar **antes** de passar por
`num()`:
```typescript
crm_leads: r.crm_leads === null ? null : num(r.crm_leads)
```

**`fetchAll`** — existe em `lib/data.ts` mas **não deve ser usado**. Busca
a tabela inteira sem filtro. Foi a causa do bug de truncamento na aba
Leads. Mantido apenas por compatibilidade histórica.

---

## Seletor de período

**Opções:** 15 dias / 30 dias / 90 dias / Datas personalizado
**Padrão:** 30 dias

"7 dias" foi removido — períodos curtos distorcem métricas de coorte
(leads não tiveram tempo de maturar, CPA de agendamento fica
artificialmente ruim).

Cada período mostra comparativo vs. período anterior de mesmo tamanho.

---

## Paleta de cores (Impuls)

```css
--petrol:      #00313d
--petrol-deep: #002832
--mint:        #94d2bd
--mint-deep:   #5fae95
--ink:         #0f1a1e
--ink-soft:    #546069
--ink-faint:   #8794a0
--line:        #e5e9ec
--surface:     #ffffff
--bg:          #f5f7f7
--up:          #1f7a63    /* variação positiva */
--down:        #b0432f    /* variação negativa */
```

**Nunca usar cores fora da paleta.** Especificamente: os azuis oficiais de
Meta (`#1877F2`) e Google (`#4285F4`) foram removidos por fugirem da
identidade. Usar petrol para Meta, mint-deep para Google, tons de cinza
para "não atribuído" e "conflito".

---

## Meta Ads — carregamento sob demanda

A aba tem 4 sub-abas, cada uma com sua chamada de RPC. Carregar as 4
simultaneamente causava lentidão e timeouts em períodos de 90 dias.

**Padrão implementado:**
```typescript
type DimState = { data: Row[]; status: 'idle' | 'loading' | 'ok' | 'error' }
```

- Só a dimensão ativa é carregada
- Guarda `if (status !== 'idle') return` evita chamadas duplicadas
- Um único `useEffect` reagindo a `[sub, loadDim]` — **não criar um segundo
  effect de pré-carregamento** (causava chamada dupla)
- Cache mantido enquanto cliente e período não mudarem
- Erro mostra botão "Tentar novamente" (nunca tabela vazia silenciosa)

---

## Hierarquia de nome do criativo

Contrato oficial do banco (16/07):
```
Título    → ad_name || creative_name || creative_id || "Criativo sem nome"
Subtítulo → headline (quando diferente do título)
```

**Nunca:** `headline` como título principal, ou inverter a ordem quando
algum campo estiver vazio. `creative_name` tem hash técnico no final
(`"AGENDE AGORA >>> 2026-06-22-ee836e..."`) — é fallback, não primeira
opção.

---

## Convenções de UI acumuladas

**Valores ausentes:** traço simples `—`. Não usar textos longos ("Valor
não informado", "Indisponível") — o usuário achou visualmente poluído.

**Cards de KPI:** 4 principais + 4 secundários. Investimento é o card
destacado (`primary`). Todos do mesmo tamanho — não misturar tamanhos.

**Notas explicativas:** banner retrátil no topo (`CohortNote`,
`DailyPulseNote`) para explicar metodologia. Nota discreta no rodapé
(`muted-note`) para detalhes secundários.

**Tabelas:** ordenáveis por padrão. `tooltip` no cabeçalho quando a coluna
precisa de explicação (aparece com sublinhado pontilhado).

**Feed de eventos:** simples, sem expansão. A tentativa de detalhes
expansíveis foi revertida por poluir visualmente.

---

## Estrutura de uma aba típica

```typescript
'use client'

export default function AlgumaTab({ clientId, period, custom }: {
  clientId: string; period: Period; periodLabel: string; custom: CustomRange | null
}) {
  const [loading, setLoading] = useState(true)
  const [data, setData] = useState<Row[]>([])

  useEffect(() => {
    let alive = true
    setLoading(true)
    const { start, end } = getRanges(period, custom ?? undefined).current

    supabase.rpc('funcao_oficial', { p_client_id: clientId, p_start_date: start, p_end_date: end })
      .then(({ data, error }) => {
        if (!alive) return
        if (error) { console.error('[Impuls] contexto:', error.message); return }
        setData((data ?? []).map(mapRow))
        setLoading(false)
      })
    return () => { alive = false }
  }, [clientId, period, custom])

  if (loading) return <div className="state"><div className="spinner" />Carregando…</div>
  // ...
}
```

**Padrões:** flag `alive` para evitar setState após desmontar; `console.error`
com prefixo `[Impuls]` e contexto; dependências `[clientId, period, custom]`.

---

## Segurança multi-cliente (camadas)

1. **RLS no banco** — protege: usuário só vê linhas dos clientes a que
   tem acesso
2. **Filtro explícito por `client_id`** no código — seleciona: qual desses
   clientes está sendo exibido

As duas camadas são necessárias. RLS sozinha deixaria passar dados de
todos os clientes do usuário quando ele tem acesso a vários.

**Teste de segurança já feito:** slug inválido → bloqueado corretamente.
