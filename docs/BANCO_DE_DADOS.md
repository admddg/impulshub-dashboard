# ImpulsHub — Banco de Dados: Inteligência Acumulada

> Este documento consolida (1) o schema real confirmado via `information_schema`
> e `pg_catalog` em 09/07/2026, (2) os documentos fundadores de metodologia
> (Playbook de Base de Dados, Update RLS, Mapa de Migração n8n — produzidos
> antes desta conversa), e (3) o que foi descoberto na prática ao construir o
> dashboard. Onde a metodologia original diverge do que está em produção, isso
> é marcado explicitamente — não foi escondido nem "corrigido silenciosamente".

**Última atualização:** 13/07/2026, tarde (fechamento adicional: reforço de
segurança na `v_workflow_health_daily` — vazamento cross-cliente corrigido,
seção 6.6 — e primeira integração real dela e da `v_client_workflow_health`
no frontend, aba "Operação". Ver `ARQUITETURA.md` e `DIARIO_PROJETO.md`.

Base do mesmo dia, mais cedo: fechamento: auditoria completa de coorte
em todo o dashboard — `v_client_performance_daily`, `v_channel_performance_
daily` e `v_client_leads_by_stage` confirmadas corretas sem necessidade de
correção; achado adicional de contaminação do backfill de 08/07 inflando
em >3x a métrica antiga de agendados em dias específicos, reforçando a
robustez da lógica de coorte além da correção conceitual. Ver seção 4.4.
Base anterior, mesma data: lógica de coorte da seção 4.1 estendida para
views de mídia (`v_meta_campaign_daily`, `v_meta_account_daily`,
`v_google_campaign_daily`). Base anterior, 11/07/2026: cliente `[TEMPLATE]`
populado com cenário fictício completo para demonstração — ver seção 10; e
nova tabela `workflow_execution_logs` + 2 views de saúde de workflow,
observabilidade do pipeline n8n — ver seção 2.5. Base anterior, 09/07/2026:
mudança de metodologia do funil comercial + investigação de duplicidade de
eventos + gap de atribuição Meta Ads em leads de Form nativo, com backfill
via Meta Lead Center concluído).

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
`archive` (ver seção 9). Nada foi apagado — só organizado, fora do caminho
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

### 2.5 Nova, 11/07/2026 — observabilidade do pipeline n8n

**`public.workflow_execution_logs`** — tabela técnica interna (mesma
categoria de `events_raw`/`conversion_outbox`: nunca client-facing direta).
Registra resumo + etapas-chave de cada execução dos workflows n8n do
ImpulsHub — motivada pela falta de qualquer visibilidade centralizada sobre
o que estava rodando/falhando no pipeline (até então, só existia dentro da
própria UI do n8n).

Colunas principais: `workflow_key` (`"1.1"`, `"2.1"` etc.), `workflow_name`,
`workflow_category` (`onboarding`/`events`/`dispatch`/`media_sync`/
`backfill`/`other`), `n8n_execution_id`, `client_id` (FK para `clients_base`,
**nullable** — cobre casos como evento sem cliente resolvido ainda),
`client_slug`/`client_name` denormalizados, `ghl_location_id`, `status`
(`running`/`success`/`partial`/`error`/`skipped`), `stage` (etapa-chave
textual), `started_at`/`finished_at`/`duration_ms` (calculado via trigger),
`items_processed`/`items_failed`, `error_message`/`error_node`, e dois
campos `jsonb` flexíveis (`stages`, `metadata`).

**Granularidade decidida por workflow** (não é uniforme de propósito):
maioria dos workflows gera **1 linha por execução** (onboarding, dispatch,
backfill); os dois de sync diário (`2.1`/`2.2`) geram **1 linha por conta**
processada dentro da execução, porque uma única execução deles varre contas
de clientes diferentes — logar só por execução misturaria clientes numa
mesma linha.

RLS ativa, sem policy pra `anon`/`authenticated` (mesmo padrão de
`events_raw`) — acesso só via as duas views abaixo ou `service_role`.

**Trigger** `fn_workflow_execution_logs_set_duration()` calcula
`duration_ms` automaticamente sempre que `finished_at` é preenchido.

**Índices:** `(client_id, started_at desc)`, `(workflow_key, started_at
desc)`, `(status, started_at desc)`, e um índice parcial em
`started_at desc where status = 'error'` pra acelerar consultas de "só os
erros recentes".

Documentação completa do desenho e da instrumentação workflow a workflow
vive em `N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md` (seção 12) e no arquivo
`SUPABASE_WORKFLOW_LOGS_SCHEMA.sql` (DDL aplicado).

---

## 3. Views (camada semântica/client-facing)

Todas usam `WITH (security_invoker = true)`. Ver `docs/ARQUITETURA.md` para
o mapa de qual view alimenta qual aba do dashboard — esta seção foca na
**definição técnica** de cada uma.

| View | Grão | Join/lógica central |
|---|---|---|
| `v_crm_events_enriched` | 1 linha = 1 evento CRM | `events_normalized` + `channel_source` via `normalize_channel_source()` + `event_date` calculado em `America/Sao_Paulo` |
| `v_crm_opportunities` | 1 linha = 1 oportunidade | Consolida eventos por `opportunity_id`: first-touch de atribuição, `valor_ganho_final` deduplicado, `has_revenue_duplication_risk` |
| `v_crm_funnel_daily` | cliente + data (do `lead`) + canal | **Coorte de leads, não evento-no-período — ver seção 4.1 (mudança de 09/07)** |
| `v_client_performance_daily` | cliente + data | Visão executiva: spend + métricas CRM + `cpl_real/cac/roas_real/ticket_medio` |
| `v_channel_performance_daily` | cliente + data + canal | Mesma métrica de performance, com canal como dimensão |
| `v_ads_spend_daily` | cliente + data + plataforma + campanha/anúncio | Mídia limpa (Meta ∪ Google via `UNION ALL`), sem conversão de plataforma. **Fonte padrão** — usar esta, não a legada abaixo |
| `v_meta_account_daily`, `v_meta_campaign_daily` | conta / campanha + data | Mix Investido + Conversões Meta (plataforma) + CRM leads/agendados, via join `meta_ads_daily.ad_id → evento.meta_ad_id`. **Coorte por nascimento do lead — ver seção 4.4 (13/07)** |
| `v_meta_campaign_performance` | campanha/conjunto/anúncio Meta | Agregado sem data (todo o período do sync) |
| `v_meta_creative_performance` | criativo/anúncio Meta | Imagem, headline, métricas + resultado CRM, sem coluna de data |
| `v_google_campaign_daily` | campanha Google + data | Mesma lógica de mix, via `google_ads_daily.campaign_id → evento.google_campaign_id`. **Coorte por nascimento do lead — ver seção 4.4 (13/07)** |
| `v_google_campaign_performance` | campanha Google, agregado | Agregado sem data (todo o período) — **não precisou da correção de coorte** por não quebrar por dia. Usa `v_crm_opportunities` (limitação conhecida da Royal, seção 4) |
| `v_google_ads_keywords_daily` | keyword + data | Direto de `google_ads_keywords_daily`, filtrada por RLS |
| `v_client_leads_by_stage` | 1 linha = 1 contato | A partir dos **eventos** (não oportunidades) — pessoa na etapa mais avançada atingida |
| `v_client_recent_events` | 1 linha = 1 evento | Feed cronológico, direto de `events_normalized` |
| `v_client_profile_safe` | 1 linha = 1 cliente acessível | Identidade e status do cliente, **sem nenhum segredo/token** — é a view usada para resolver acesso multi-cliente (`lib/access.ts`) |
| `v_client_workflow_health` **(novo, 11/07)** | 1 linha = 1 execução (ou 1 conta, pros sync diário) | Direto de `workflow_execution_logs` filtrado por `client_id is not null`, **sem** `error_message`/`error_node` (detalhe técnico fica interno) — RLS herdada de `clients_base` via `security_invoker` |
| `v_workflow_health_daily` **(novo, 11/07)** | cliente + dia + workflow | Agregação (`count`/`avg duration_ms`) por `workflow_execution_logs`, uso interno da agência. **Protegida contra vazamento cross-cliente desde 13/07** — só retorna linha para usuários com acesso a mais de 1 cliente (ver seção 6.6) |

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

## 4.1 Mudança de metodologia: funil por coorte de leads (09/07/2026)

**Problema identificado:** a tela de Funil comercial do dashboard mostrava,
para janelas curtas (ex: 7 dias), etapas posteriores com volume **maior**
que etapas anteriores — ex: `126 Leads` → `156 Primeira conversa` (124% de
"conversão"). Isso é estruturalmente impossível num funil e gerava
desconfiança no dado.

**Causa raiz:** `v_crm_funnel_daily`, na versão original, contava cada
`event_code` pelo `event_date` em que **aquele evento específico** ocorreu,
dentro da janela selecionada — não pela jornada de um mesmo lead. Um contato
podia ter virado `lead` **antes** da janela e avançado para
`primeira_conversa` **dentro** da janela, inflando a etapa seguinte sem
inflar a etapa anterior. Na validação da Royal (7 dias), 53 dos 175 eventos
de `primeira_conversa` do período vieram de leads criados fora da janela.

**Decisão tomada:** abandonar a visão "evento ocorrido no período" e adotar
**coorte de leads**: a etapa `lead` é filtrada pela data do evento dentro do
período selecionado (7 dias / 30 dias / Datas — os seletores do frontend não
mudaram); as etapas seguintes (`primeira_conversa`, `agendado`, `ganho`,
`perdido`) são verificadas **sem trava de data**, olhando se aquele mesmo
contato da coorte chegou lá em qualquer momento. Resultado: topo do funil
sempre ≥ etapas seguintes, garantido pela própria lógica da query.

**Trade-off aceito conscientemente:** períodos recentes (principalmente
"7 dias") vão sempre parecer com conversão mais baixa que períodos mais
longos, porque parte da coorte ainda não teve tempo de avançar ("coorte
imatura"). Isso é esperado e correto — não é bug. Ainda não foi feito
nenhum ajuste de copy na UI para comunicar isso ao usuário final
(considerado, mas não implementado em 09/07 — ver pendências, seção 7).

**Implementação:** `v_crm_funnel_daily` foi recriada com `CREATE OR REPLACE
VIEW`, mantendo exatamente as mesmas colunas de saída (`crm_leads,
crm_primeiras_conversas, crm_agendados, crm_ganhos, crm_perdidos, receita`)
e o mesmo agrupamento (`client_id, client_name, client_slug, event_date,
channel_source`) — **nenhuma mudança foi necessária no frontend**. A lógica
interna passou a ser: CTE `leads` filtra `event_code = 'lead'` na janela;
cada etapa seguinte usa `count(*) FILTER (WHERE EXISTS (...))` checando o
`contact_id` da coorte contra `v_crm_events_enriched` sem filtro de data.
Critérios de `ganho`/`perdido` por `status`/`pipeline_stage` (além de
`event_code`) foram preservados como estavam na view original.

**Validado em produção (Royal, 09/07):** `primeira_conversa` passou a ser
sempre ≤ `crm_leads`, linha a linha, nos 7 dias testados.

---

## 4.2 Investigação de duplicidade de eventos (09/07/2026)

Motivada pela observação de `primeira_conversa > leads` (seção 4.1), foi
feita uma varredura geral por `contact_id + event_code` duplicado em
`events_normalized`. Achado: **apenas 4 casos em toda a base** — 3 de
`primeira_conversa`, 1 de `ganho` (nenhum com `valor_ganho` preenchido).
Não é um problema sistêmico de volume, mas valia entender a causa por poder
afetar `receita` no futuro.

**Metodologia de investigação:** comparar o intervalo de tempo entre os
`event_datetime` de cada par duplicado. Intervalos de segundos/minutos
sugerem disparo duplo (bug); intervalos de dias/semanas sugerem reentrada
legítima do contato no funil (ex: voltou depois de `perdido`).

**Achados por caso:**
- **3 casos** (incluindo um contato real, não de teste — Marília Ferreira
  Borges) tiveram intervalo de **segundos a poucos minutos** entre os dois
  eventos, mesmo `opportunity_id`, mesmo `pipeline_stage` → padrão de
  disparo duplo, não reentrada.
- **1 caso** teve 5 dias de intervalo, mas era um contato de teste — não
  indicativo de bug em produção.

**Cruzamento com `events_raw`:** para os 3 casos de disparo duplo, existem
**dois webhooks distintos** chegando em `/inbound-events` com segundos de
diferença — ou seja, o n8n normalizou corretamente 1 webhook → 1 evento,
duas vezes. **A duplicação não nasce na normalização (n8n), nasce antes.**

**Caso Marília — aprofundado com o Audit Log do GHL:** o audit log mostrou
uma única ação `TAG_ADDED: primeira_conversa` (14:08:13), mas dois webhooks
chegaram 9s e 24s depois. Isso descartou inicialmente a hipótese de "duas
automações escutando o mesmo gatilho", mas a investigação seguinte revelou
a causa real: **existem dois contatos distintos no GHL com o mesmo nome**
("Marília Ferreira Bor...", criados com 1 minuto de diferença em 25/04,
telefones diferentes) — e o time de CRM mexeu/deletou um deles
manualmente, contrariando orientação prévia de não fazer alterações diretas
nesse tipo de registro. Isso complica a rastreabilidade do caso.

**Decisão (09/07):** dado o baixo volume (4 casos na base toda), não
investigar o cadastro duplicado de contato a fundo agora. Prioridade foi
blindar o dado agregado contra o sintoma que mais importa — duplicação de
receita:

```sql
-- trecho da v_crm_funnel_daily: substitui sum(valor_ganho) direto
-- por DISTINCT ON via LATERAL JOIN, pegando o evento de ganho mais
-- recente por contato (ORDER BY received_at DESC, único timestamp
-- disponível em v_crm_events_enriched)
LEFT JOIN LATERAL (
  SELECT DISTINCT ON (e.contact_id) e.valor_ganho
  FROM v_crm_events_enriched e
  WHERE e.contact_id = l.contact_id
    AND (e.event_code = 'ganho'::text OR e.status = 'won'::text)
  ORDER BY e.contact_id, e.received_at DESC
) dedup ON true
```

**Nota técnica:** as colunas `crm_primeiras_conversas`, `crm_agendados`,
`crm_ganhos`, `crm_perdidos` **não precisaram** desse tratamento — usam
`count(*) FILTER (WHERE EXISTS (...))`, que já é imune a duplicidade de
evento por natureza (responde só "esse contato chegou nessa etapa?", não
"quantas vezes"). Só `receita`, por fazer `sum()` direto sobre eventos, tinha
esse risco.

**Validado em produção (Royal, 09/07):** `sum(crm_ganhos) = 6`,
`sum(receita) = 0` (esperado — os `ganho` duplicados na base não tinham
`valor_ganho` preenchido; o teste real de dedup de valor fica pendente para
quando aparecer um caso com valor).

**Pendências desta investigação** (não bloqueiam nada, mas ficam
registradas para retomar):
- Entender por que existem dois contatos GHL com o mesmo nome/período de
  criação para a Marília, e reforçar com o time de CRM a orientação de não
  deletar/alterar esses registros manualmente.
- Se duplicidade de `lead` (não só `ganho`/`primeira_conversa`) aparecer no
  futuro, a coorte da `v_crm_funnel_daily` também duplicaria linha inteira
  — ainda não blindado, considerado caso raro por ora.
- Ajuste de copy na UI da aba Funil, avisando que números de janelas
  recentes (ex: 7 dias) refletem coorte "ainda em andamento" — não
  implementado em 09/07.

---

## 4.3 Gap de atribuição: leads de Form Nativo (Meta) sem `meta_ad_id` (09/07/2026)

**Sintoma:** dashboard de campanhas mostrava forte disparidade entre
"Conversões Meta" (dado da plataforma) e "Leads" (CRM) **apenas** em
campanhas de **Formulário Nativo do Meta** — campanhas de WhatsApp não
tinham esse problema. Exemplo real: campanha
`ROYAL_CONV_FORM_fb-LEAD_Formulario` com 133 conversões reportadas pelo
Meta, mas só 23 vinculadas no dashboard.

**Investigação (resumo):**
1. Confirmado que os ~132 leads de Form nativo da Royal **existem** no
   banco como evento `lead` (não são leads perdidos/não capturados) — mas
   100% deles vieram de `source_event_type =
   'clean_rebuild_from_ghl_contacts_export'`, ou seja, **backfill via
   export de contatos do GHL**, que nunca trouxe dado de atribuição
   (nenhum lead vindo desse backfill tem como recuperar atribuição por
   aqui).
2. Testado o fluxo **ao vivo**: usando audit logs do GHL, identificados 5
   leads de Form nativo criados no dia 09/07 via webhook real (não
   backfill). Comparando o payload bruto salvo (`events_normalized.payload
   -> body`) com o que foi gravado nas colunas: **a atribuição chega
   correta desde o primeiro evento (`lead`)**, dentro de
   `body.contact.attributionSource.adId` (e também em
   `.adSetId`/`.campaignId`) — mas a normalização estava lendo
   `body.customData.sourceId`, campo que só vem preenchido de forma
   inconsistente dependendo do workflow/estágio do GHL.
3. Confirmado via `pg_get_viewdef` que `v_crm_events_enriched.meta_ad_id`
   é **exatamente** `events_normalized.source_id` (sem transformação) —
   ou seja, corrigir `source_id` na tabela base propaga automaticamente
   para a view e para todo o resto do pipeline de relatórios (inclusive
   `v_meta_account_daily`/`v_meta_campaign_daily`, que fazem join por
   `meta_ad_id`).

**Causa raiz:** bug de normalização — o campo lido (`customData.sourceId`)
não é a fonte mais confiável; `contact.attributionSource.adId` está
presente em 100% dos casos testados e deveria ser a fonte primária.

**Ações tomadas em 09/07:**
- **Correção do fluxo ao vivo:** repassada ao responsável pelos workflows
  do n8n — trocar a leitura de `meta_ad_id` para usar, em cascata:
  `contact.attributionSource.adId` → `contact.lastAttributionSource.adId`
  → `body.sourceId` → `customData.sourceId` (comportamento atual, como
  último recurso). Documento de handoff:
  `Resumo_Gap_Atribuicao_Meta_Ads.md`. **Status: pendente de implementação
  pelo responsável do n8n.**
- **Patch retroativo #1 (eventos ao vivo já normalizados):** `UPDATE` em
  `events_normalized`, preenchendo `source_id` a partir do payload já
  salvo (mesmo fallback), apenas onde `source_id` estava nulo/vazio **e**
  havia dado de atribuição disponível. **Resultado: 5 linhas corrigidas**
  (Jade, Verbena, Natália, Coldplas, Jaine — os únicos casos ao vivo com
  atribuição recuperável no payload).
- **Patch retroativo #2 (backfill histórico via Meta Lead Center):** o
  usuário exportou do Lead Center do Meta Ads Manager o arquivo
  `Formulario_-_Royal_Leads_2026-04-23_2026-07-08.csv` (209 submissões,
  período 23/04–09/07, **209 telefones únicos, zero duplicidade**). Dados
  limpos (prefixos `p:`/`ag:`/`as:`/`c:` removidos, telefone normalizado
  para o mesmo formato do banco) e cruzados por telefone contra os eventos
  `lead` da Royal sem `source_id`. Script:
  `backfill_meta_leadcenter.sql` (staging table +
  diagnóstico + snapshot em `archive.pre_meta_leadcenter_backfill_20260709`
  + `UPDATE`). **Resultado: 86 linhas corrigidas.** Match validado como
  genuíno (cada contato recebeu `ad_id`/campanha específicos do seu
  payload real, não um valor fixo repetido).
- **Sugestão de evolução (não implementada):** capturar também
  `adSetId`/`campaignId` do mesmo objeto `attributionSource`, criando
  colunas `meta_campaign_id`/`meta_adset_id` — hoje só existe granularidade
  de anúncio (`meta_ad_id`).

**Resultado final (canal Form nativo, `lead_entrada = 'Form_FBAds'`):**
de 177 leads, **131 (74%) hoje com atribuição correta** — 91 corrigidos
pelos dois patches de hoje, ~40 que já estavam corretos antes de qualquer
ação (provavelmente eventos ao vivo anteriores à consolidação do bug, ou
casos em que `customData.sourceId` veio preenchido por acaso).

**Pendência (não bloqueia nada, fica registrada):** **46 leads seguem sem
`meta_ad_id`**, mesmo depois do cruzamento com o Lead Center. Checado que
**não é simplesmente "fora da janela de retenção do Meta"** — as datas
desses 46 vão de 22/04 a 25/06, a maioria **dentro** do período coberto
pelo próprio export (23/04–09/07), então deveriam ter batido e não
bateram. Causa ainda não investigada; hipóteses a testar quando retomar:
telefone salvo no banco diferente do usado na submissão do formulário
(pessoa preencheu com outro número), variação de formato não coberta pela
normalização atual (ex: número de 8 dígitos antigo sem o 9 inicial), ou
leads que entraram como orgânicos/duplicados e não aparecem no export
(que só lista `is_organic = false`). Sem solução até aqui — aceito como
perda residual por ora.

**Escopo:** achado validado só para a Royal até aqui. Mesmo padrão
(payload correto, normalização lendo campo errado) é estrutural do
pipeline — vale checar se outros clientes com campanhas de Form nativo
têm o mesmo gap assim que a correção do n8n for aplicada.

---

## 4.4 Extensão da lógica de coorte para views de mídia (13/07/2026)

**Como foi descoberto:** ao investigar por que a campanha
`ROYAL_CONV_FORM_fb-LEAD_Formulario` mostrava CPAg ~5x maior que campanhas
de WhatsApp equivalentes no período 01/07–12/07, cruzamento com export bruto
de contatos do GHL mostrou que os 2 "agendados" atribuídos à campanha no
período **não eram leads nascidos no período** — ambos viraram lead em
29-30/06 e só agendaram (evento `agendado`) dentro da janela de julho.
Confirmado via query: dos 25 leads de Form efetivamente nascidos em
01-12/07, **nenhum** tinha evento `agendado` em qualquer momento da história
— o número exibido vinha inteiramente de leads de outra safra.

**Causa raiz:** exatamente o mesmo problema estrutural corrigido na seção
4.1 (`v_crm_funnel_daily`, 09/07) — só que dessa vez nas views que cruzam
mídia paga com resultado de CRM. `v_meta_campaign_daily`,
`v_meta_account_daily` e `v_google_campaign_daily` contavam `crm_agendados`
pelo `event_date` **do próprio evento `agendado`**, dentro da janela — não
pela data de nascimento do lead. Um lead nascido em Junho que agenda em
Julho infla o `Agendam.` de Julho sem nunca ter contado como `Leads` de
Julho (que é filtrado corretamente pela data do evento `lead`) — o mesmo
descolamento estrutural de antes, agora em outra família de views.

**Decisão (confirmada com o usuário):** esse deve ser o **padrão de
metodologia para qualquer view que combine investimento de mídia com
resultado de CRM**, não uma correção pontual: uma pessoa pertence à coorte
do período em que **nasceu como lead**; qualquer avanço posterior dela
(`primeira_conversa`, `agendado`, `ganho`, `perdido`) é contado nessa
mesma coorte de origem, **sem trava de data** no evento seguinte.

**Views corrigidas** (`CREATE OR REPLACE VIEW`, mesmas colunas de saída,
sem mudança de frontend):
- **`v_meta_campaign_daily`** — CTE `crm` reescrita: isola primeiro a
  coorte de `lead`s por `campaign_id`+dia (via `ad_para_campanha`), depois
  verifica `crm_agendados` com `count(*) FILTER (WHERE EXISTS (...))` sem
  filtro de data no evento `agendado`.
- **`v_meta_account_daily`** — mesma lógica, granularidade de conta em vez
  de campanha.
- **`v_google_campaign_daily`** — mesma lógica; mais simples que as do Meta
  porque `google_campaign_id` já vem nativo nos dois lados (não precisa de
  CTE auxiliar tipo `ad_para_campanha`).

**Validado em produção:** query de teste em `v_meta_campaign_daily` para a
campanha de Form da Royal — os 2 agendados migraram para 29/06 e 30/06
(datas de nascimento reais), e **todo o período de 01-12/07 passou a
mostrar `crm_agendados = 0`**, batendo exatamente com o que o export bruto
do GHL confirmava (nenhum lead de julho havia avançado além de "Primeira
Conversa" até o momento da checagem).

**Views explicitamente avaliadas e não alteradas:**
- **`v_google_campaign_performance`** — agrega o período **inteiro** sem
  quebrar por dia; não existe "janela" para causar o descolamento (é
  vida-toda vs. vida-toda). Usa `v_crm_opportunities`, que tem a limitação
  conhecida da Royal (seção 4), mas isso é um problema à parte, já
  documentado, não relacionado a esta correção.
- **`v_google_ads_keywords_daily`** — não cruza com CRM, só performance
  nativa do Google por keyword; fora do escopo desse tipo de descolamento.

**Auditoria completa da pendência (13/07, mesmo dia):** as duas views
executivas foram checadas e **não precisaram de nenhuma correção** —
`v_client_performance_daily` e `v_channel_performance_daily` já herdam a
lógica de coorte de graça, porque fazem `sum()` diretamente em cima de
`v_crm_funnel_daily` (já corrigida em 09/07), não recalculam nada a partir
de `events_normalized`. `v_client_leads_by_stage` também já estava correta
por desenho desde a concepção — grão é 1 linha por contato,
`data_entrada = min(event_datetime)`, etapa = a mais avançada já atingida
(`bool_or`) — é coorte por construção, não por correção. **Conclusão: com
o fechamento desta auditoria, todo o dashboard segue hoje a mesma premissa
de coorte-por-nascimento-do-lead**, sem exceção pendente conhecida (exceto
`v_client_recent_events`, que é intencionalmente um feed cronológico bruto
— não deveria mesmo ter coorte, é sobre "o que aconteceu quando").

**Achado adicional, motivado por resistência saudável do usuário ao
resultado ("não bate com o que eu esperava"):** comparação lado a lado das
duas metodologias (coorte vs. evento-no-período) no canal Meta Ads da
Royal, 28/06–13/07, revelou que a divergência era **maior do que
"imaturidade de coorte" sozinha explicaria** — a metodologia antiga somava
**129 agendados** no período contra **40** da coorte (>3x). Picos
isolados e não-orgânicos apareceram em 07-09/07 (26, 25 e 11 agendados
num único dia, numa conta que tipicamente gera 0-5/dia), incluindo um dia
(13/07) com mais "agendados" (11) do que "leads" (2) — o mesmo padrão
estruturalmente impossível que originou a correção de 09/07.

**Causa raiz do pico:** cruzamento com `source_event_type` confirmou que
**225 dos 240 eventos** desses 3 dias vinham de
`clean_rebuild_from_ghl_contacts_export` — o mesmo backfill de 08/07 já
documentado nas seções 2.4 e 4.3. Mecanismo: o export de contatos do GHL
usado no backfill trazia a data real de criação do lead (`Created`,
confiável — por isso `leads_coorte` e `leads_evento` sempre bateram
igual), mas **não** trazia o histórico de quando cada mudança de estágio
aconteceu — só o estágio atual. O script de reprocessamento, sem outra
opção, carimbou os eventos de estágio avançado (`agendado`, `ganho`, etc.)
com a **data em que o backfill rodou**, não a data real histórica.

**Por que isso importa além do óbvio:** a metodologia evento-no-período não
era só "conceitualmente confusa" — ela é **estruturalmente vulnerável** a
qualquer reprocessamento/backfill futuro, que sempre vai inflar
artificialmente o dia em que rodou. A coorte é **imune por acidente
feliz**: não foi desenhada pensando nesse cenário, mas por não depender da
data do evento seguinte para decidir "quando isso conta", ela não herda a
data errada do backfill. Isso eleva a lógica de coorte de "mais correta
conceitualmente" para "também mais robusta operacionalmente" — argumento a
mais para nunca reverter essa decisão de metodologia.

**Pendência nova (13/07):** ideia de uma aba "Performance diária"
(Meta/Google Ads, granularidade de conta) para acompanhamento de ritmo —
ver discussão de design em `docs/DIARIO_PROJETO.md`. Não implementada
nesta rodada; views já existentes (`v_meta_account_daily`,
`v_google_campaign_daily`) já têm o grão certo (dia + conta) para
alimentá-la sem trabalho novo de banco.

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
- [x] `workflow_execution_logs` com RLS ativa, sem policy pra `anon`/`authenticated` — **criada 11/07**, mesmo padrão de `events_raw`.
- [x] `v_workflow_health_daily` sem vazamento cross-cliente — **resolvido 13/07** (seção 6.6).
- [ ] Teste formal de acesso `anon` sem sessão retornando vazio em todas as views — pendente.

---

### 6.6 ✅ Resolvido — `v_workflow_health_daily` protegida contra vazamento cross-cliente (13/07/2026)

**Achado:** a view foi desenhada de propósito **sem** filtro por `client_id`
(é uma visão agregada "todos os clientes" para uso interno da agência — ver
seção 2.5). Isso a deixava aberta para **qualquer** usuário autenticado
(inclusive o login de um cliente único, tipo o dono de uma clínica)
consultá-la direto via `supabase-js` e ver contagem de execuções/erros de
**outros** clientes. Como ela não é `security_invoker` (precisa driblar a
RLS-sem-política da `workflow_execution_logs` para funcionar entre
clientes), a única forma de restringir era escrever a regra de acesso
**dentro da própria view**, não via RLS convencional da tabela base.

**Correção aplicada** (`docs/sql/08_secure_workflow_health.sql`): a view foi
recriada com `CREATE OR REPLACE VIEW` (mesmas colunas de saída — nenhuma
mudança no que consome ela) adicionando uma trava "tudo ou nada" no `WHERE`:

```sql
WHERE (
  SELECT count(*) FROM public.client_users cu
  WHERE cu.user_id = auth.uid() AND cu.is_active = true
) > 1
```

Ou seja: só retorna linha nenhuma se o usuário logado tiver **mais de 1**
cliente ativo em `client_users` — o mesmo critério que o frontend já usa
para decidir "isso é alguém da agência" (ver `ARQUITETURA.md`). Um usuário
de cliente único recebe lista vazia, sem erro; o app trata isso normalmente.

**Validado em produção (13/07):** consulta em `client_users` confirmou
exatamente **2 usuários** hoje se qualificam como multi-cliente (3 clientes
ativos cada) — os únicos que agora enxergam a tela `/operacao` do dashboard
(seção 12 abaixo).

**Nota para o futuro:** se um dia existir uma role explícita de "equipe da
agência" (em vez do proxy "tem acesso a mais de 1 cliente"), essa é a
função que precisa mudar — o resto do sistema (frontend, view) não precisa
saber como o critério é calculado.

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
6. **`Primeira conversa` maior que `Leads` no funil** — respondido: era
   efeito de contar por evento-no-período em vez de coorte de leads.
   **Ação:** `v_crm_funnel_daily` recriada com lógica de coorte. Ver seção
   4.1.
7. **Existe duplicidade de eventos no CRM?** — respondido: sim, mas raro
   (4 casos em toda a base). Causa identificada como problema de origem no
   GHL (não no n8n/normalização). `receita` blindada com `DISTINCT ON` na
   view; investigação de causa raiz completa segue como pendência de baixa
   prioridade. Ver seção 4.2.
8. **Por que campanhas de Form nativo (Meta) mostram Conversões Meta muito
   maior que Leads no CRM?** — respondido: gap de normalização, não perda
   de dado nem problema de sincronização Meta→GHL. `meta_ad_id` (=
   `source_id`) lia campo errado do payload (`customData.sourceId`) em vez
   do campo sempre presente (`contact.attributionSource.adId`). Corrigido
   retroativamente via dois patches (5 pelo payload já salvo + 86 via
   cruzamento por telefone com export do Meta Lead Center) — resultado
   final: 131 de 177 leads de Form nativo (74%) com atribuição correta;
   46 seguem sem solução, causa não identificada. Correção do fluxo de
   captura ao vivo repassada ao responsável do n8n. Ver seção 4.3.
9. **Por que uma campanha (Form, Royal) mostra CPAg muito maior que outras
   no mesmo período?** — respondido: não é a campanha, é metodologia —
   `v_meta_campaign_daily`/`v_meta_account_daily`/`v_google_campaign_daily`
   contavam `crm_agendados` pelo evento em si, não pela coorte de
   nascimento do lead, gerando comparações injustas entre campanhas de
   idades diferentes. **Ação:** as 3 views recriadas com a mesma lógica de
   coorte da seção 4.1. Ver seção 4.4.

---

## 8. O pipeline que alimenta este banco (n8n) — visão resumida

Não é o foco deste documento (que é sobre o banco em si), mas é essencial
para entender **por que** os dados chegam do jeito que chegam.

> **Atualizado em 11/07/2026** — a versão abaixo reflete o inventário real,
> confirmado nos JSONs de produção (não mais o Mapa de Migração de 02/07,
> que ficou desatualizado). Detalhe completo, workflow a workflow, em
> `N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md`.

**9 workflows de produção** (eram 10 até 11/07 — os dois de backfill Meta
foram fundidos em um só), organizados em 3 camadas + eventos:
- **Onboarding** (`0.0`, `0.1`-fusão, `0.3`, `0.4`): `0.0` cadastra cliente em
  `clients_base` + contas de mídia e dispara em cascata `0.3` (conversion
  actions do Google), `0.1`-fusão (backfill Meta 6 meses — performance **e**
  criativos no mesmo fluxo, desde a fusão de 11/07) e `0.4` (backfill Google
  6 meses).
- **Eventos** (`1.1`-`1.3`): `1.1` recebe webhook do GHL em `/inbound-events`,
  grava em `events_raw`, normaliza para `events_normalized`, cria registro em
  `conversion_outbox`, dispara `1.2`/`1.3` (dispatch para Meta CAPI / Google
  Data Manager API).
- **Mídia diária** (`2.1`/`2.2`): rodam às 05h/05h15, sincronizam
  `meta_ads_daily`/`google_ads_daily` com lookback de alguns dias (para
  capturar atrasos de atribuição das plataformas).
- **Suporte** (`9.9`): workflow de captura de erro compartilhado — qualquer
  falha em qualquer um dos 9 acima fecha a linha correspondente em
  `workflow_execution_logs` como `status = 'error'`.

Todos os 9 workflows de produção agora escrevem em
`workflow_execution_logs` (seção 2.5) — abertura no início da execução (ou
por conta, nos dois de mídia diária), fechamento no fim ou via `9.9` em caso
de erro.

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

**Resultado visível em 09/07:** o schema `public` caiu de 16 para **10
tabelas físicas**, todas realmente em uso: `clients_base`, `client_users`,
`client_meta_ad_accounts`, `client_google_ads_accounts`, `events_normalized`,
`events_raw`, `conversion_outbox`, `meta_ads_daily`, `google_ads_daily`,
`google_ads_keywords_daily`.

**Atualização 11/07:** entrou a 11ª tabela, `workflow_execution_logs`
(seção 2.5) — mesma categoria técnica interna de `events_raw`/
`conversion_outbox`, criada para dar observabilidade ao pipeline n8n.

---

## 10. Cliente `[TEMPLATE]` — dado fictício para demonstração (11/07/2026)

**Contexto:** existe um cliente real cadastrado em `clients_base`
(`client_slug = 'template'`, `id = '1675286a-805f-4f90-88a2-cd0895700082'`,
`ghl_location_id = 'hmhaauorgOgyq3lRc0Q4'`) usado como ambiente de
demonstração do dashboard — não é um cliente de produção real. Antes desta
rodada, ele tinha só 6 eventos de teste manuais (contatos genéricos tipo
"Teste Form Meta Ads", "teste google") e nenhuma conta de mídia configurada
— por isso aparecia zerado em quase todas as abas.

**O que foi feito:** limpeza dos 6 eventos de teste antigos + inserção de um
cenário fictício completo ("Clínica Sorriso Perfeito"), cobrindo Junho/2026
como mês fechado, pra popular todas as abas do dashboard de forma coerente
entre si (mesmo dado de origem alimentando Visão Geral, Funil, Canais, Meta
Ads, Google Ads, Leads e Eventos).

**Dado inserido:**
- **Contas de mídia:** 1 conta Meta Ads (`client_meta_ad_accounts`) + 1
  conta Google Ads (`client_google_ads_accounts`), ambas fictícias.
- **`meta_ads_daily`:** 60 linhas — 2 campanhas (`SORRISO_CONV_FORM_fb-
  LEAD_Avaliacao`, Form nativo; `SORRISO_CONV_WPP_fb-WHATS_Implante`,
  WhatsApp) × 30 dias.
- **`google_ads_daily`:** 30 linhas — 1 campanha de Pesquisa
  (`SORRISO_SEARCH_Implantes_Brasilia`) × 30 dias.
- **`events_raw` + `events_normalized`:** 450 linhas em cada — 170 leads
  fictícios com funil completo (Lead → Primeira Conversa → Agendado →
  Ganho/Perdido), distribuídos por canal: 55 via Meta Form, 65 via Meta
  WhatsApp, 30 via Google, 20 orgânico (WhatsApp direto, sem custo de
  mídia). Resultado do funil: 170 leads, 125 primeira conversa, 80
  agendados, 30 ganhos, 45 perdidos — `valor_ganho` preenchido nos ganhos
  (receita fictícia ~R$ 55-65 mil no mês) para ROAS/CAC/ticket médio não
  ficarem zerados.

**Decisão de design (mês fixo, não janela móvel):** optou-se por Junho/2026
fixo (não "últimos 30 dias" recalculado) — mais previsível pra repetir a
demo em datas diferentes sem precisar regenerar dado. **Trade-off aceito:**
os atalhos rápidos do dashboard ("7 dias"/"30 dias") não mostram esse
dado, pois contam a partir da data atual — é necessário selecionar "Datas"
e escolher manualmente 01/06/2026 a 30/06/2026 toda vez que for demonstrar.

**Decisão de design (tudo dentro do mês):** todos os eventos de um mesmo
lead (da entrada até o estágio final) foram mantidos dentro de Junho —
nenhum evento vaza pra Julho — para que qualquer aba do dashboard que
filtre por `event_date` (não só a Funil, que já usa lógica de coorte
desde 09/07, seção 4.1) mostre números consistentes sob o mesmo filtro de
data.

**Como foi inserido:** script único (`INSERT`s simples, sem `TEMP TABLE` —
lição aprendida em 09/07 sobre problemas de sessão no SQL Editor), rodado
como uma execução inteira. Ordem: limpeza (via CTE `DELETE ... RETURNING`
encadeado, para apagar `events_normalized` e os `events_raw` associados
numa única instrução, respeitando a FK) → contas de mídia → performance
diária → funil de CRM. Contagem de colunas × valores validada
programaticamente antes da entrega, para não travar no meio de um `INSERT`
de centenas de linhas.

**Pendência/nota:** se o cenário fictício precisar ser regenerado ou
expandido (outro mês, outro volume, outro cliente-modelo), o gerador é um
script Python que monta o SQL por template — não um `INSERT` escrito à
mão — então ajustar volume/distribuição/datas é rápido se o pedido surgir
de novo.

---

## 11. Ver também

- `docs/README.md` e `docs/ARQUITETURA.md` — os conceitos e o mapa view→aba
  do dashboard (nível de aplicação).
- `docs/DIARIO_PROJETO.md` — histórico narrativo de bugs e decisões da
  construção do frontend.
- `docs/sql/` — scripts de migração já aplicados (01-04, camada de
  aplicação), de segurança/organização (05-06, camada de fundação: grants
  de `clients_base`/tabelas internas, e o schema `archive`), e o reforço
  mais recente (08, restrição de acesso da `v_workflow_health_daily`).
- Este documento (`docs/BANCO_DE_DADOS.md`) — a fundação: schema, RLS,
  funções e o pipeline que os alimenta.
- `N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md` — detalhe completo dos 9
  workflows de produção, workflow a workflow, e o desenho da instrumentação
  de `workflow_execution_logs` (seção 2.5 deste documento).
- `SUPABASE_WORKFLOW_LOGS_SCHEMA.sql` — DDL aplicado da tabela de logs e das
  duas views de saúde de workflow.
