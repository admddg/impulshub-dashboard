# ImpulsHub — Banco de Dados: Inteligência Acumulada

> Este documento consolida (1) o schema real confirmado via `information_schema`
> e `pg_catalog` em 09/07/2026, (2) os documentos fundadores de metodologia
> (Playbook de Base de Dados, Update RLS, Mapa de Migração n8n — produzidos
> antes desta conversa), e (3) o que foi descoberto na prática ao construir o
> dashboard. Onde a metodologia original diverge do que está em produção, isso
> é marcado explicitamente — não foi escondido nem "corrigido silenciosamente".

**Última atualização:** 09/07/2026.

---

## 1. As quatro camadas (como o banco foi pensado)

Do Playbook original, ainda válido como princípio:

1. **Cadastro/Configuração** — `clients_base`, `client_meta_ad_accounts`,
   `client_google_ads_accounts`, `client_users`.
2. **Técnica interna** — `events_raw`, `conversion_outbox`. Nunca expostas
   diretamente ao cliente.
3. **Normalizada** — `events_normalized`, `meta_ads_daily`, `google_ads_daily`,
   `google_ads_keywords_daily`.
4. **Semântica/client-facing** — as views `v_*`, todas com
   `security_invoker = true`.

> **Tese central do projeto** (Update Metodologia RLS, 02/07): *"CRM é fonte
> da verdade para resultado. Meta Ads e Google Ads são fontes da verdade para
> investimento, cliques, impressões e estrutura de campanha. Views unem as
> camadas. RLS transforma relatório interno em produto com login."*

---

## 2. Tabelas físicas (catálogo completo confirmado)

### 2.1 Cadastro/Configuração

**`clients_base`** — cadastro mestre do cliente. ~90 colunas cobrindo: identidade
(`client_slug`, `client_name`, `ghl_location_id`, `status`, `timezone`,
`currency`), credenciais/segredos de integração (`meta_access_token`,
`google_ads_refresh_token`, `google_ads_developer_token`, `ga4_api_secret`,
`tiktok_access_token` — **texto puro**), configuração de tracking por
plataforma (Meta, Google, GA4, TikTok — cada uma com enable/labels/conversion
actions), e campos de readiness/status de sync
(`meta_ads_sync_ready`, `google_ads_sync_ready`, `sync_ready`,
`*_last_backfill_at`, `*_last_sync_at`, `media_backfill_status`).

⚠️ **Nunca deve ser lida diretamente pelo app** — só através de
`v_client_profile_safe`, que expõe apenas identidade e status, sem nenhum
segredo. Ver seção 6 sobre reforço de grant recomendado.

**`client_meta_ad_accounts`** / **`client_google_ads_accounts`** — permitem
mais de uma conta de mídia por cliente (`is_primary`, `sync_enabled`,
`source`). É por isso que a Royal aparece com 3 contas Meta distintas no
dashboard.

**`client_users`** — vínculo usuário↔cliente. `id, client_id, user_id, role,
is_active`. É a **fonte da verdade de acesso multi-cliente** — tudo que a
V10 do frontend faz depende desta tabela, via `private.user_can_access_client()`.

### 2.2 Técnica interna (nunca client-facing)

**`events_raw`** — payload bruto do webhook do GHL, antes de qualquer
normalização (`request_headers/query/body` em jsonb, `processing_status`).
Existe para auditoria/replay, não para o dashboard.

**`conversion_outbox`** — fila de envio de conversões server-side para
Meta/Google (CAPI / Data Manager API). Campos de controle: `status` (pending/
sent/skipped/failed), `attempts`, `next_attempt_at`, `last_error`,
`match_keys`. É o "painel de saúde de tracking" interno, nunca do cliente.

### 2.3 Normalizada

**`events_normalized`** — a tabela mais importante do sistema. 1 linha por
evento de funil, já limpo. Contém: identidade do contato (`contact_id`,
`full_name`, `phone`, `email`), `event_code` (lead/primeira_conversa/
agendado/ganho/perdido), `event_datetime`, atribuição
(`lead_origem`, `lead_entrada`, `source_id`, `source_type`, todos os UTMs,
`gclid/gbraid/wbraid/fbclid/fbp/fbc`, `ctwa_clid`), dados comerciais
(`valor_ganho`, `forma_ganho`, `procedimento_ganho`, `motivo_perda_categoria`),
e vínculo ao GHL (`opportunity_id`, `pipeline_id`, `pipeline_stage`, `status`).

**`meta_ads_daily`** — performance diária Meta em nível de anúncio: `spend,
impressions, clicks, reach, frequency`, mais os campos de conversão da
plataforma adicionados na rodada de metodologia de conversões
(`meta_lead_forms`, `meta_messaging_conversations_started`,
`meta_platform_conversions` = soma dos dois). Também carrega os campos de
criativo diretamente nela (`thumbnail_url`, `image_url`, `creative_url`,
`headline`, `primary_text`, `video_id`) — **não existe mais uma tabela
separada de criativos Meta em uso** (ver `meta_ads_creatives_deprecated`
abaixo).

**`google_ads_daily`** — performance diária Google em nível de anúncio:
`impressions, clicks, cost, conversions, all_conversions` (sem quebra por
tipo de conversão — pendência conhecida).

**`google_ads_keywords_daily`** — performance diária por palavra-chave
configurada: `keyword_text, keyword_match_type, keyword_status, impressions,
clicks, cost, conversions`. Não contém termo de pesquisa (search term) —
decisão consciente de não abrir esse fluxo de sync por ora.

### 2.4 Legado — movido para o schema `archive` em 09/07/2026

As tabelas e a view abaixo saíram do schema `public` e vivem hoje em
`archive` (ver seção 10). Nada foi apagado — só organizado, fora do caminho
do app e sem acesso de `anon`/`authenticated` ao schema. Se precisar
consultar algo antigo, trocar `public.` por `archive.` no nome.

- **`archive.meta_ads_creatives_deprecated`** — os campos de criativo
  migraram para dentro da própria `meta_ads_daily`; esta tabela não é mais
  escrita nem lida por nada em produção.
- **`archive.backup_events_normalized_royal_20260708`**,
  **`archive.backup_events_raw_royal_20260708`**,
  **`archive.backup_rebuild_royal_conversion_outbox_20260708_1551`**,
  **`archive.backup_rebuild_royal_events_normalized_20260708_1551`**,
  **`archive.backup_rebuild_royal_events_raw_20260708_1551`** — snapshots
  pontuais de um reprocessamento da Royal em 08/07/2026, já validado.
- **`archive.ads_daily`** (view) — versão legada de `v_ads_spend_daily`,
  confirmada como sem dependências relevantes antes de arquivar.

---

## 3. Views (camada semântica/client-facing)

Todas usam `WITH (security_invoker = true)`. Ver `docs/ARQUITETURA.md` para
o mapa de qual view alimenta qual aba do dashboard — esta seção foca na
**definição técnica** de cada uma.

| View | Grão | Join/lógica central |
|---|---|---|
| `v_crm_events_enriched` | 1 linha = 1 evento CRM | `events_normalized` + `channel_source` via `normalize_channel_source()` + `event_date` calculado em `America/Sao_Paulo` |
| `v_crm_opportunities` | 1 linha = 1 oportunidade | Consolida eventos por `opportunity_id`: first-touch de atribuição, `valor_ganho_final` deduplicado, `has_revenue_duplication_risk` |
| `v_crm_funnel_daily` | cliente + data + canal | **Ver seção 4 — divergência de metodologia** |
| `v_client_performance_daily` | cliente + data | Visão executiva: spend + métricas CRM + `cpl_real/cac/roas_real/ticket_medio` |
| `v_channel_performance_daily` | cliente + data + canal | Mesma métrica de performance, com canal como dimensão |
| `v_ads_spend_daily` | cliente + data + plataforma + campanha/anúncio | Mídia limpa (Meta ∪ Google via `UNION ALL`), sem conversão de plataforma. **Fonte padrão** — usar esta, não a legada abaixo |
| `v_meta_account_daily`, `v_meta_campaign_daily` | conta / campanha + data | Mix Investido + Conversões Meta (plataforma) + CRM leads/agendados, via join `meta_ads_daily.ad_id → evento.meta_ad_id` |
| `v_meta_campaign_performance` | campanha/conjunto/anúncio Meta | Agregado sem data (todo o período do sync) |
| `v_meta_creative_performance` | criativo/anúncio Meta | Imagem, headline, métricas + resultado CRM, sem coluna de data |
| `v_google_campaign_daily`, `v_google_campaign_performance` | campanha Google (+data / agregado) | Mesma lógica de mix, via `google_ads_daily.campaign_id → evento.google_campaign_id` |
| `v_google_ads_keywords_daily` | keyword + data | Direto de `google_ads_keywords_daily`, filtrada por RLS |
| `v_client_leads_by_stage` | 1 linha = 1 contato | A partir dos **eventos** (não oportunidades) — pessoa na etapa mais avançada atingida |
| `v_client_recent_events` | 1 linha = 1 evento | Feed cronológico, direto de `events_normalized` |
| `v_client_profile_safe` | 1 linha = 1 cliente acessível | Identidade e status do cliente, **sem nenhum segredo/token** — é a view usada para resolver acesso multi-cliente (`lib/access.ts`) |

---

## 4. Nota de qualidade de dado: a Royal como caso histórico

Isto ficou registrado como "divergência de metodologia" numa versão anterior
deste documento — mas com mais contexto, é mais preciso chamar de **nota de
qualidade de dado específica da Royal**, não de um problema estrutural do
banco.

**O que a metodologia original definiu** (Update RLS, 02/07): eventos não são
oportunidades. `primeira_conversa`, `agendado`, `ganho`, `perdido` e `receita`
deveriam vir de `v_crm_opportunities` — consolidada, deduplicada — para nunca
contar duas vezes o mesmo avanço de funil. Esse princípio **continua correto**
e é a forma certa de calcular receita (que `v_crm_opportunities` resolve bem,
via `valor_ganho_final` deduplicado).

**Por que a Royal foge do padrão:** a Royal foi a **primeira cliente** do
sistema, e passou por uma mudança de metodologia no meio do caminho — antes
do fluxo atual (webhook → banco), o processo alimentava uma **planilha**, não
o banco de dados diretamente. Esse histórico de migração explica por que
`v_crm_opportunities` tem só ~32 linhas para 1.165 contatos: parte da jornada
desses contatos nunca passou pelo fluxo que cria oportunidade formal no GHL
com todas as datas de etapa preenchidas.

**A correção aplicada** (`docs/sql/04_fix_funnel.sql`): para não perder a
visão do funil da Royal enquanto esse histórico não é reconciliado,
`v_crm_funnel_daily` e `v_client_leads_by_stage` foram ajustadas para contar
a partir de `v_crm_events_enriched.event_code` (eventos por contato), não de
`v_crm_opportunities`. Isso resolveu o "Primeira conversa = 0" que aparecia
mesmo com 354 eventos reais no período.

**Expectativa para clientes novos:** com o cliente entrando 100% pelo fluxo
atual desde o primeiro dia (sem bagagem de planilha), a tendência é
`v_crm_opportunities` refletir o funil de forma muito mais completa desde o
início — o que a torna a fonte preferencial assim que a base de clientes
crescer. Vale reavaliar, cliente a cliente, qual das duas fontes (eventos ou
oportunidades) está mais completa antes de decidir qual usar no funil dele.

---

## 5. Funções (schema `private`/`public`)

Só duas funções no banco — design enxuto e intencional.

### `private.user_can_access_client(p_client_id uuid) returns boolean`
```sql
SECURITY DEFINER, STABLE, search_path = 'public','auth'

select exists (
  select 1 from public.client_users cu
  where cu.client_id = p_client_id
    and cu.user_id = (select auth.uid())
    and cu.is_active = true
);
```
Base de toda política RLS do projeto — usada em `USING (private.user_can_access_client(client_id))`.

### `public.normalize_channel_source(...) returns text`
Regra **única e centralizada** de classificação de canal (antes vivia
duplicada em mais de uma view — corrigido na rodada de metodologia de 02/07).
Lógica, em ordem de prioridade:

1. **Fonte primária — `lead_origem`** (regex, case-insensitive):
   - `fbads|facebook|meta|ctwa|click_to_whatsapp|lead_ads|3_1|3_2` → **Meta Ads**
   - `gmb|google meu neg` → **Google Meu Negócio**
   - `google_ads|google ads|gads|google cpc|paid_google` → **Google Ads**
   - `instagram|ig` → **Instagram Orgânico**
   - `form_site|form site|site|website|formul|3_3` → **Site**
   - `first_whatsapp|whatsapp_direto|whatsapp direto|whatsapp|3_4` → **WhatsApp Direto**
   - `indic` → **Indicação**
   - `organico|orgânico|organic` → **Orgânico**
   - não bate em nenhuma regra → usa o texto original (`trim(p_lead_origem)`)
2. **Fallback técnico** (só se `lead_origem` vazio): `meta_ad_id` preenchido
   → Meta Ads; `google_campaign_id`/`gclid`/`gbraid`/`wbraid` preenchido →
   Google Ads; `lead_entrada` contém "whatsapp" → WhatsApp Direto; contém
   "site"/"form" → Site.
3. **Sem nenhum dado** → `'Não Identificado'`.

> Nota: os códigos `3_1, 3_2, 3_3, 3_4` no regex são valores internos do GHL
> (provavelmente IDs de origem configurados no funil) — confirmar com o time
> que mantém as automações do CRM o que cada um representa, se for preciso
> depurar um caso específico.

> **Importante para o dashboard:** o `channelBucket()` do frontend (em
> `lib/utils.ts`) simplifica essas ~9 categorias em só 3 (Meta Ads / Google
> Ads / Orgânico) — "Instagram Orgânico", "Google Meu Negócio", "Indicação"
> etc. todas caem em "Orgânico" na visualização. A função do banco preserva
> o detalhe completo; a simplificação é só de exibição.

---

## 6. Segurança: RLS, grants — reforços aplicados em 09/07/2026

### 6.1 Estado confirmado

Tabelas com RLS ativa **e política funcionando**: `client_google_ads_accounts`,
`client_meta_ad_accounts`, `client_users`, `clients_base`, `events_normalized`,
`google_ads_daily`, `google_ads_keywords_daily`, `meta_ads_daily` — todas com
policy `..._select_by_client_user` usando `private.user_can_access_client()`.

Tabelas com RLS ativa **sem nenhuma política** (bloqueadas por padrão para
`authenticated`/`anon`, mesmo com GRANT amplo — RLS sem policy nega tudo):
`events_raw`, `conversion_outbox`, e as 6 hoje movidas para `archive`
(seção 2.4). Isso é intencional e correto — são internas, não devem ser lidas
pelo app.

### 6.2 ✅ Resolvido — grants de escrita revogados nas tabelas internas

Script `docs/sql/05_hardening_grants.sql`, aplicado e validado. `events_raw`,
`conversion_outbox` e as tabelas hoje arquivadas perderam
`INSERT/UPDATE/DELETE/TRUNCATE` de `anon` e `authenticated` — sobrou só
`SELECT/TRIGGER/REFERENCES`, inofensivo por trás de RLS sem política. Reduz
o risco de uma política futura mal escrita reabrir escrita indevida por
acidente.

### 6.3 ✅ Resolvido — `clients_base` protegida por grant de coluna

Script `docs/sql/05_hardening_grants.sql`. **Achado original:** a tabela
guarda tokens/segredos em texto puro (`meta_access_token`,
`google_ads_refresh_token`, `google_ads_developer_token`, `ga4_api_secret`,
`tiktok_access_token`, entre outros) e tinha `GRANT SELECT` **de tabela
inteira** para `authenticated` — um usuário logado do próprio cliente
poderia, tecnicamente, consultar `clients_base` direto e ler os próprios
tokens.

**Detalhe técnico importante descoberto durante a correção:** `v_client_
profile_safe` é um `SELECT` simples de `clients_base`, sem filtro de
segurança próprio — ela depende inteiramente da RLS da tabela base rodando
via `security_invoker`. Isso significa que **simplesmente revogar todo o
SELECT quebraria a própria view** (que precisa do grant do usuário invocador
para funcionar). A correção certa foi granular:

```sql
REVOKE SELECT ON public.clients_base FROM authenticated;
GRANT SELECT (id, client_name, client_slug, status, timezone, currency,
  tracking_status, tracking_ready, meta_ready, google_ads_ready,
  meta_ads_sync_ready, google_ads_sync_ready, sync_ready,
  meta_ads_last_sync_at, google_ads_last_sync_at,
  meta_ads_last_backfill_at, google_ads_last_backfill_at,
  created_at, updated_at
) ON public.clients_base TO authenticated;
```

Grant só nas colunas que `v_client_profile_safe` realmente usa. A view
continua funcionando normalmente; uma tentativa de `SELECT meta_access_token
FROM clients_base` como usuário comum agora retorna `permission denied for
table clients_base` — **confirmado em produção** rodando `SET ROLE
authenticated` antes da query de teste (o SQL Editor comum roda como
superusuário e ignora grants, então testar sem esse `SET ROLE` dá falso
positivo — mesma pegadinha da RLS).

### 6.4 Views: grants amplos, mas RLS protege por baixo (não testado formalmente)

Todas as views (`v_*`) têm grant para `anon` **e** `authenticated`. O grant
de `SELECT` para `anon` numa view client-facing, embora provavelmente inócuo
(porque `security_invoker` + a policy da tabela base checam `auth.uid()`,
que não existe para `anon`), **não foi testado formalmente** com uma chamada
real não-autenticada. Fica como item para validar quando houver tempo —
não é bloqueador.

### 6.5 Checklist de segurança

- [x] RLS ativo nas tabelas base principais.
- [x] `security_invoker=true` nas views client-facing.
- [x] `clients_base` sem exposição de tokens via view (`v_client_profile_safe`).
- [x] `clients_base` sem exposição de tokens via grant direto — **resolvido 09/07**.
- [x] `events_raw`/`conversion_outbox` mantidas internas.
- [x] Grants de escrita revogados de tabelas internas/arquivadas — **resolvido 09/07**.
- [x] Tabelas de backup e legado organizadas fora do `public` — **resolvido 09/07**.
- [ ] Teste formal de acesso `anon` sem sessão retornando vazio em todas as views — pendente.

---

## 7. Perguntas que estavam em aberto — respondidas em 09/07/2026

1. **`ads_daily` vs `v_ads_spend_daily`** — confirmado (resposta de quem
   mantém o pipeline): as duas retornam o mesmo volume, `v_ads_spend_daily`
   é a versão segura (normaliza nulos com `COALESCE`), `ads_daily` não tinha
   dependências relevantes. **Ação:** arquivada em `archive.ads_daily`
   (seção 2.4/10). Novos usos devem sempre ser em `v_ads_spend_daily`.
2. **Por que tão poucas oportunidades formais na Royal** — respondido: é
   um caso histórico específico dela (migração de planilha para banco no
   meio do caminho), não um problema estrutural do fluxo atual. Ver seção 4.
   Expectativa é que clientes novos, 100% no fluxo atual desde o início,
   tenham `v_crm_opportunities` mais completa.
3. **Tabelas de backup de 08/07** — confirmado que o reprocessamento já foi
   validado. **Ação:** arquivadas em `archive.*` (seção 2.4/10).
4. **`meta_ads_creatives_deprecated`** — confirmado sem uso ativo. **Ação:**
   arquivada em `archive.meta_ads_creatives_deprecated` (seção 2.4/10).
5. **Conversões Google por tipo** — sem solução ainda; fica no roadmap de
   longo prazo, registrado também em `docs/DIARIO_PROJETO.md`.

---

## 8. O pipeline que alimenta este banco (n8n) — visão resumida

Não é o foco deste documento (que é sobre o banco em si), mas é essencial
para entender **por que** os dados chegam do jeito que chegam. Resumo do
Mapa de Migração (02/07):

**9 workflows**, organizados em 3 camadas + eventos:
- **Onboarding** (`01A`-`01D`): cadastra cliente em `clients_base`, contas de
  mídia, sincroniza conversion actions do Google, dispara backfill de 6 meses
  de Meta/Google.
- **Eventos** (`02A`-`02C`): `02A` recebe webhook do GHL em `/inbound-events`,
  grava em `events_raw`, normaliza para `events_normalized`, cria registro em
  `conversion_outbox`, dispara `02B`/`02C` (dispatch para Meta CAPI / Google
  Data Manager API).
- **Mídia diária** (`03A`/`03B`): rodam às 05h/05h15, sincronizam
  `meta_ads_daily`/`google_ads_daily` com lookback de alguns dias (para
  capturar atrasos de atribuição das plataformas).

**Mapeamento de `event_code` para eventos de plataforma** (usado no
dispatch):
| event_code | Meta | Google | Elegível para dispatch? |
|---|---|---|---|
| `lead` | `Lead` (ou `LeadSubmitted` via WhatsApp BM) | `Lead` | Sim |
| `agendado` | `Schedule` (ou `QualifiedLead` via WhatsApp BM) | `Agendou` | Sim |
| `ganho` | `Purchase` | `Compra` | Sim, com valor/moeda |
| `primeira_conversa` | — | — | **Não** — normalizado mas não enviado às plataformas |
| `perdido` | — | — | **Não** — normalizado mas não enviado às plataformas |

**As automações do GHL que geram os eventos** (documentado no material de
CRM/funil): `00_pipe_contato_criado_lead` (cria oportunidade + dispara
webhook), `01_atribuir_origem_API_WhatsApp` (marca `lead_entrada=WhatsApp`,
`lead_origem=FacebookAds` — só roda para uma parte do tráfego de WhatsApp,
o que explica por que grande parte dos leads tem `lead_entrada` nulo),
`02_atribuir_origem_form_fbads`, `03_atribuir_origem_form_site`,
`04_pipe_primeira_conversa` até `07_pipe_perdido` (uma automação por etapa
do funil, cada uma move o pipeline e dispara o webhook correspondente).

**Roadmap original de migração do n8n para uma "Central Impuls" própria**
(não teve execução iniciada até esta data): observabilidade primeiro, depois
API de eventos própria, depois workers de dispatch, depois syncs de mídia,
por último onboarding — migração gradual, sem big bang, mantendo o n8n
rodando em paralelo até cada peça ser validada.

---

## 9. Schema `archive` — organização do legado (criado em 09/07/2026)

Script `docs/sql/06_archive_legado.sql`, aplicado e validado. Criado um
schema separado, `archive`, para tirar do caminho do `public` tudo que é
histórico/descontinuado mas ainda vale preservar (em vez de apagar).

**O que está lá dentro:** as 5 tabelas de backup da Royal (08/07), a
`meta_ads_creatives_deprecated`, e a view `ads_daily` — ver detalhe de cada
uma na seção 2.4.

**Proteção extra:** `REVOKE ALL ON SCHEMA archive FROM anon, authenticated`
— nem com o nome exato da tabela em mãos um usuário comum consegue "entrar"
no schema. Camada a mais além da RLS que já bloqueava tudo.

**Como consultar algo arquivado, se precisar:** troca `public.nome_da_tabela`
por `archive.nome_da_tabela` em qualquer query rodada como administrador no
SQL Editor (o app nunca precisa fazer isso).

**Resultado visível:** o schema `public` caiu de 16 para **10 tabelas
físicas**, todas realmente em uso: `clients_base`, `client_users`,
`client_meta_ad_accounts`, `client_google_ads_accounts`, `events_normalized`,
`events_raw`, `conversion_outbox`, `meta_ads_daily`, `google_ads_daily`,
`google_ads_keywords_daily`.

---

## 10. Ver também

- `docs/README.md` e `docs/ARQUITETURA.md` — os conceitos e o mapa view→aba
  do dashboard (nível de aplicação).
- `docs/DIARIO_PROJETO.md` — histórico narrativo de bugs e decisões da
  construção do frontend.
- `docs/sql/` — scripts de migração já aplicados (01-04, camada de
  aplicação) e de segurança/organização (05-06, camada de fundação: grants
  de `clients_base`/tabelas internas, e o schema `archive`).
- Este documento (`docs/BANCO_DE_DADOS.md`) — a fundação: schema, RLS,
  funções e o pipeline que os alimenta.
