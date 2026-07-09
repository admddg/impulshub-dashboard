# Arquitetura — mapa view por aba

## Camadas de dados

1. **Raw** — `events_raw`, `meta_ads_daily`, `google_ads_daily`,
   `google_ads_keywords_daily`. Dado cru, escrito pelo n8n.
2. **Enriquecida** — `v_crm_events_enriched` (eventos + canal resolvido),
   `v_crm_opportunities` (1 linha por oportunidade: atribuição first-touch +
   receita deduplicada + etapa mais avançada).
3. **Marts (leitura)** — as views consumidas diretamente pelo dashboard.
4. **Acesso** — `client_users` + RLS por `client_id`.

## Mapa: view por aba

| Aba | View principal | O que entrega |
|---|---|---|
| Visão geral | `v_client_performance_daily` | KPIs executivos + evolução de leads e CPL por dia |
| Funil | `v_crm_funnel_daily` | Contagem por etapa (lead, 1ª conversa, agendado, ganho, perdido) a partir dos **eventos** |
| Canais | `v_crm_events_enriched` | Leads por Entrada (`lead_entrada`) e por Origem (`lead_origem`) + cruzamento |
| Meta — Contas | `v_meta_account_daily` | Investido, Conversões Meta, Leads, CPL, Agendam., CPag por conta |
| Meta — Campanhas | `v_meta_campaign_daily` | Mesmo mix por campanha, com seletor de conta |
| Meta — Anúncios/Criativos | `v_meta_creative_performance` | Tabela (CTR, CPC, CPL, CPag) e grid visual de criativos |
| Google — Campanhas/Gráfico | `v_google_campaign_daily` | Impressões/cliques/leads por dia, evolução de conversões, tabela de campanhas |
| Google — Palavras-chave | `v_google_ads_keywords_daily` | Keyword, tipo, status, impressões, cliques, CTR, CPC, custo |
| Leads | `v_client_leads_by_stage` | As pessoas do funil (nome, telefone, entrada, origem, etapa), filtrável por data de entrada |
| Eventos | `v_client_recent_events` | Feed dos últimos 50 eventos do CRM |
| Seletor/cabeçalho de cliente | `v_client_profile_safe` | Nome/slug do cliente, sem dados sensíveis — é a view usada para resolver acesso multi-cliente |

## A espinha analítica: `v_crm_opportunities`

Resolve três coisas em uma linha por oportunidade:

- **Atribuição (first-touch):** canal e campanha vêm do primeiro evento
  (`lead_origem` do GHL; `source_id`/`meta_ad_id` do Meta; `google_campaign_id`/
  `gclid` do Google).
- **Receita deduplicada:** `valor_ganho` contado uma única vez por oportunidade,
  no evento de ganho (flag `has_revenue_duplication_risk` audita risco de
  duplicidade).
- **Estado do funil:** etapa mais avançada atingida, com a data de cada etapa.

**Atenção:** nem todo lead vira oportunidade formal — em produção real, a maioria
dos leads fica só como eventos soltos. Por isso `v_crm_funnel_daily` e
`v_client_leads_by_stage` contam a partir dos **eventos por contato**, não da
`v_crm_opportunities`. Usar a tabela de oportunidades para contagens de funil foi
um bug real já corrigido (ver `docs/sql/04_fix_funnel.sql`).

## Como o canal é resolvido

A origem de cada lead é definida na entrada (automações do GHL) e consolidada no
dashboard em três buckets:

- **Meta Ads** — `source_id`/`meta_ad_id` presente, ou `lead_origem` = Facebook.
- **Google Ads** — `google_campaign_id`/`gclid` presente, ou `lead_origem` = Google.
- **Orgânico** — tudo que não for Meta nem Google (WhatsApp, Site, Indicação, etc.)

Já **"Entrada"** (`lead_entrada`) é um conceito diferente e não deve ser confundido
com origem: é *por onde* o lead chegou (WhatsApp, Site, Formulário), enquanto
origem é *qual canal pagou* por ele. Um lead pode entrar por WhatsApp tendo vindo
de um anúncio do Meta — as duas dimensões são independentes e por isso o
dashboard as mostra separadas, com uma tabela cruzando as duas.

## Conversões: plataforma x CRM

Convenção adotada para não confundir "o que a plataforma diz" com "o que
realmente virou cliente":

- **Conversões Meta** = `meta_lead_forms + meta_messaging_conversations_started`
  (campo `meta_platform_conversions` em `meta_ads_daily`). É o que a Meta reporta.
- **Conversões Google** = campo `conversions` de `google_ads_daily`. Também é
  reportado pela plataforma, sem quebra por tipo (pendência de sync para o
  futuro).
- **Leads / Agendamentos / CPL / CPag** = sempre vêm do CRM (`crm_leads`,
  `crm_agendados` nas views de mídia, calculados via join com os eventos).

As tabelas de Meta e Google no dashboard mostram as duas coisas lado a lado de
propósito — a diferença entre "conversões que a plataforma conta" e "leads que
o CRM confirma" é, ela mesma, um insight valioso para o cliente.

## Segurança multi-cliente (V10)

Ver `README.md` para a regra geral. Em termos de código:

- `lib/access.ts` — `getMyClients()` lista os clientes permitidos ao usuário
  logado; `resolveClient(slug)` resolve um slug para `client_id`, validando
  acesso via RLS da `v_client_profile_safe`.
- `lib/data.ts` — `fetchWindowed`/`fetchAll` exigem `clientId` e filtram
  `.eq('client_id', clientId)` em toda query. Necessário porque, quando um
  usuário tem acesso a vários clientes, a RLS sozinha deixaria passar os dados
  de todos — o filtro explícito é o que isola qual cliente está sendo exibido.
- `components/DashboardClient.tsx` — resolve o slug, valida, e só então
  renderiza as abas passando o `clientId` já resolvido.
