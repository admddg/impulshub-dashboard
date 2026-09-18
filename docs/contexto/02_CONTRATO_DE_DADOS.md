# ImpulsHub — Contrato de dados (fontes V2)

> Referência técnica das fontes oficiais. **Consultar antes de escrever
> qualquer query ou chamada de RPC.** Se uma coluna não está aqui,
> confirmar no banco antes de usar — nunca assumir por analogia.

---

## Regra de consumo

O frontend consome **apenas** as fontes listadas neste documento. Views
antigas (sem sufixo `_v2`) estão congeladas/depreciadas e não devem ser
usadas em código novo.

**Segurança confirmada:** todas as views V2 têm `security_invoker = true`.
As funções RPC são `SECURITY INVOKER STABLE`. As tabelas base têm RLS ativa
com política por `client_id`. Um `client_id` sem acesso retorna vazio.

---

## 1. `get_client_overview_v2(p_client_id, p_start_date, p_end_date)`

Retorna **1 linha** com o resumo executivo do período. Fonte da aba Visão Geral.

```typescript
interface ClientOverviewV2 {
  client_id: string
  client_name: string
  client_slug: string
  period_start: string
  period_end: string

  media_days: number
  investment: number | null
  investment_is_complete: boolean | null

  leads: number
  paid_attributed_leads: number
  meta_ads_leads: number
  google_ads_leads: number
  unattributed_leads: number
  attribution_conflicts: number

  primeiras_conversas: number
  agendados: number
  crm_ganhos: number                      // jornada por contato

  acquisition_buying_contacts: number     // comercial
  acquisition_sales: number               // comercial
  cohort_total_sales: number
  cohort_sales_without_own_lead: number

  acquisition_revenue: number | null
  total_cohort_revenue: number | null
  acquisition_revenue_is_complete: boolean | null
  cohort_revenue_is_complete: boolean | null

  closed_sales: number
  closed_buying_contacts: number
  closed_revenue: number | null
  closed_revenue_is_complete: boolean | null

  cpl_paid: number | null
  cac_acquisition: number | null
  roas_acquisition: number | null
  roas_total_cohort: number | null
}
```

**Indicadores já calculados no banco** — nunca recalcular:
- `cpl_paid` = investimento ÷ leads tecnicamente atribuídos
- `cac_acquisition` = investimento ÷ compradores com lead próprio
- `roas_acquisition` = receita de aquisição ÷ investimento
- Todos retornam `NULL` quando os dados necessários estão incompletos

**Regra de cálculo:** os indicadores são calculados **depois** da soma do
período. Nunca calcular pela média dos valores diários.

---

## 2. `get_meta_ads_summary_v2(p_client_id, p_start_date, p_end_date, p_dimension)`

Fonte da aba Meta Ads. Agregação inteira no banco.

**`p_dimension`:** `'account'` | `'campaign'` | `'adset'` | `'ad'` | `'creative'`

**Colunas de saída:**
```
group_id, group_name
account_id, account_name
campaign_id, campaign_name
adset_id, adset_name
ad_id, ad_name
creative_id, creative_name
thumbnail_url, image_url, creative_url
headline, primary_text

spend, impressions, clicks
crm_leads, crm_primeiras_conversas, crm_agendados, crm_ganhos
acquisition_revenue, acquisition_revenue_is_complete
roas_acquisition
```

**Atribuição:** `client_id + meta_ad_id = ad_id`. CRM contado por safra de
lead (`lead_date`), usando flags cumulativos.

**Nota sobre o nível `creative`:** usa ramo separado que agrega direto por
`creative_id` real. Auditoria confirmou que nenhum `ad_id` tem mais de um
`creative_id` na base atual. Se aparecer no futuro, a regra oficial é
resolver pelo último criativo conhecido na data do lead.

**Performance:** 137ms após otimização de índices (era 2.350ms).

---

## 3. `get_google_ads_summary_v2(p_client_id, p_start_date, p_end_date, p_dimension)`

Fonte da aba Google Ads.

**`p_dimension`:** `'account'` | `'campaign'` | `'ad_group'` | `'ad'`

**Colunas de saída:**
```
group_id, group_name
customer_id, customer_name
campaign_id, campaign_name
ad_group_id, ad_group_name
ad_id, ad_name

spend, impressions, clicks, conversions
crm_leads, crm_primeiras_conversas, crm_agendados
crm_attribution_level
```

**Limite de confiança:** CRM confiável apenas em `account` e `campaign`
(`google_campaign_id` está sempre presente; `google_ad_id` nem sempre).
Em `ad_group`/`ad`, CRM vem `NULL`.

**Buckets explícitos:** registros sem ID técnico aparecem como "Sem grupo
identificado" / "Sem anúncio identificado". **Nunca somem dos totais.**

---

## 4. Views canônicas CRM

### `v_client_leads_by_stage_v2` (36 colunas)
Grão: lead/contato. Fonte da aba Leads.

```
client_id, client_name, client_slug
contact_id, full_name, phone, email
lead_at, lead_date
primeira_conversa_at, agendado_at, ganho_at, perdido_at
has_primeira_conversa, has_agendado, has_ganho, has_perdido   ← flags CUMULATIVOS
etapa_codigo, etapa, etapa_ordem                               ← estágio ATUAL
lead_origem, lead_entrada
meta_ad_id, google_campaign_id, google_adgroup_id, google_ad_id
google_keyword, gclid, gbraid, wbraid
has_meta_attribution, has_google_attribution, attribution_platform
total_events, lead_event_count, lead_events_without_datetime
```

**Distinção crítica:**
- `etapa` = estágio **atual** da pessoa → use para os pills de filtro
- `has_*` = flags **cumulativos** → use para validar funil e RPCs de mídia

Quem agendou também passou por primeira conversa. Validar funil com
`group by etapa` dá números errados.

**Valores de `attribution_platform`:** `'Meta Ads'`, `'Google Ads'`,
`'Não atribuído'`, `'Conflito'`

### `v_crm_funnel_daily_v2` (10 colunas)
Grão: cliente + data da coorte + plataforma. Fonte da aba Funil.
```
client_id, client_name, client_slug
event_date, attribution_platform
crm_leads, crm_primeiras_conversas, crm_agendados, crm_ganhos, crm_perdidos
```
O frontend **ignora** `attribution_platform` (soma tudo) — canal fica só
na aba Canais.

### `v_crm_channels_daily_v2` (11 colunas)
Grão: cliente + coorte + dimensão. Fonte da aba Canais.
```
client_id, date, dimension_type, dimension_value, crm_leads, ...
```

**`dimension_type` tem 3 valores:**
| Valor | Significado | Exemplos |
|---|---|---|
| `plataforma_atribuida` | Técnico, oficial | Meta Ads, Não atribuído |
| `entrada_informada` | Bruto | WhatsApp, Form_Site, Form_FBAds |
| `origem_informada` | Bruto | FacebookAds, Site, WhatsApp |

### `v_crm_events_daily_v2` (18 colunas)
Grão: cliente + data + evento. Fonte da aba Diário.
```
client_id, date, event_code, event_count, ...
```

### `v_crm_events_feed_v2` (63 colunas)
Grão: evento. Fonte da aba Eventos.
```
event_id, event_datetime_local, event_code, event_name
full_name, phone, opportunity_id
lead_origem, lead_entrada, pipeline_stage, status
utm_source, utm_medium, utm_campaign, utm_content, utm_term
ctwa_clid, fbclid, gclid, gbraid, wbraid
google_campaign_id, google_adgroup_id, google_ad_id, google_keyword
valor_ganho, forma_ganho, produto_servico
source_system, source_event_type, source_workflow_id
normalization_status, has_opportunity_id
gain_has_informed_value, gain_has_missing_value
```

### Outras views CRM (existem, ainda não consumidas pelo frontend)
```
v_crm_lead_journey_v2       — jornada canônica com datas dos marcos
v_crm_opportunities_v2      — status oficial e vínculo com jornada
v_crm_sales_v2              — venda oficial, comprador e receita
v_crm_sales_daily_v2        — vendas e receita por data de fechamento
```

---

## 5. Views canônicas de mídia

### `v_meta_ads_v2` (42 colunas)
Grão: anúncio por dia. **Mídia pura, sem CRM.**
```
id, client_id, client_name, client_slug, date
account_id, account_name, campaign_id, campaign_name
adset_id, adset_name, ad_id, ad_name
ad_status, ad_effective_status
creative_id, creative_name, effective_object_story_id
thumbnail_url, image_url, creative_url, destination_url
primary_text, headline, image_hash
impressions, reach, frequency, clicks, inline_link_clicks, unique_clicks
spend, cpc, cpm, ctr, leads, purchases, purchase_value
conversions_count, conversions_value, created_at, updated_at
```
**Não tem `video_id`.** (Erro que já cometi.)

### `v_google_ads_v2` (30 colunas)
Grão: anúncio por dia. Mídia pura.
```
client_id, date, customer_id, customer_name
campaign_id, campaign_name, ad_group_id, ad_group_name
ad_id, ad_name, cost, impressions, clicks, conversions, ...
```

### `v_google_keywords_v2` (26 colunas)
Grão: palavra-chave por dia.
```
client_id, date, keyword_text, campaign_name, ad_group_name
keyword_match_type, keyword_status
impressions, clicks, cost, ...
```

---

## 6. `v_client_performance_daily_v2`

Grão: cliente + data. Consolida mídia, coorte e atividade comercial.
Fonte dos gráficos diários e da aba Diário.

**Blocos de métricas** (cada um com sua data de referência):

| Bloco | Data | Colunas principais |
|---|---|---|
| Mídia | Data de entrega | `reported_spend`, `spend_is_complete`, `reported_impressions`, `reported_clicks` |
| Coorte | `lead_date` | `cohort_leads`, `cohort_primeiras_conversas`, `cohort_agendados`, `cohort_paid_attributed_leads`, `cohort_meta_ads_leads`, `cohort_google_ads_leads`, `cohort_unattributed_leads`, `cohort_attribution_conflicts` |
| Aquisição | Data do lead | `acquisition_won_opportunities`, `acquisition_won_contacts`, `acquisition_open_*`, `acquisition_lost_*` |
| Vendas coorte | Data do lead | `cohort_total_sales`, `cohort_acquisition_sales`, `cohort_confirmed_revenue`, `cohort_confirmed_acquisition_revenue`, `cohort_revenue_is_complete` |
| Atividade comercial | Data do ganho | `closed_sales`, `closed_buying_contacts`, `closed_confirmed_revenue`, `closed_revenue_is_complete`, `closed_average_ticket_with_valid_value` |

---

## 7. Views de suporte e acesso

```
v_client_profile_safe        — nome/slug do cliente, sem dado sensível
                                (usada para resolver acesso multi-cliente)
v_workflow_health_daily      — saúde dos workflows n8n (agência)
v_client_workflow_health     — execuções recentes de workflow
```

**`v_workflow_health_daily`** tem trava de acesso na própria view: só
retorna linhas se o usuário logado tiver mais de 1 cliente ativo em
`client_users`.

---

## 8. Views de qualidade (diagnóstico, não alimentam métricas)

```
v_crm_data_quality_v2
v_crm_event_repeat_quality_v2
v_crm_journey_quality_v2
v_crm_opportunity_quality_v2
```

Decisão do time: manter separadas por enquanto. Não usar como caminho
principal do dashboard do cliente.

---

## 9. IDs de referência

```
Admin:              caio@dinizdigital.com
                    d036c4d6-0969-4175-b917-ff7e4dd3b376

Royal Odontologia:  fa6fc071-7529-4317-93cb-9b0bfea3bca3  (slug: royal_odontologia)
[TEMPLATE]:         1675286a-805f-4f90-88a2-cd0895700082  (dados fictícios)
ImpulsHub:          3ec294db-a64a-4420-9b4a-0d917f65d399
Central-Gama:       19c9d8c6-1a6d-499b-95fd-cc23d1cd555b

Supabase URL:       https://mtxnwtqwfagjzkvgsncs.supabase.co
Repositório:        github.com/admddg/impulshub-dashboard (branch main)
```

---

## 10. Queries de validação úteis

**Confirmar colunas de uma view:**
```sql
select column_name, data_type, ordinal_position
from information_schema.columns
where table_name = 'NOME_DA_VIEW'
order by ordinal_position;
```

**Contar colunas (detecta se o resultado veio truncado):**
```sql
select table_name, count(*) as n_colunas
from information_schema.columns
where table_name in ('view_a', 'view_b')
group by table_name;
```

**Benchmark de funil (flags cumulativos, datas fixas):**
```sql
select
  count(*) as leads,
  count(*) filter (where has_primeira_conversa) as primeiras_conversas,
  count(*) filter (where has_agendado) as agendados,
  count(*) filter (where has_ganho) as ganhos,
  count(*) filter (where has_perdido) as perdidos
from public.v_client_leads_by_stage_v2
where client_id = '<CLIENT_ID>'
  and lead_date between date '<INI>' and date '<FIM>';
```

**Benchmark Meta (mesmo padrão, filtrado por plataforma):**
```sql
-- adicionar: and attribution_platform = 'Meta Ads'
```

**Validar pills da aba Leads (estágio atual, não cumulativo):**
```sql
select etapa, count(*) as leads
from public.v_client_leads_by_stage_v2
where client_id = '<CLIENT_ID>'
group by etapa order by etapa;
```

**Importante:** usar sempre **datas fixas** nas validações, nunca
`current_date - interval` — senão o benchmark muda todo dia.

---

## 11. Limitações do SQL Editor do Supabase

- Limite de exibição de **100 linhas** no resultado
- O botão "Download CSV" também respeita esse limite em alguns casos
- **Sempre confirmar com `count(*)`** se um resultado longo veio completo
  (isso já causou trabalho em cima de dado incompleto duas vezes)
