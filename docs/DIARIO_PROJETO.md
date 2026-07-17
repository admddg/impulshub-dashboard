# ImpulsHub — Diário do Projeto

> Arquivo único de contexto. Se você está lendo isso numa conversa nova (com o
> Claude ou com qualquer pessoa), este documento sozinho deve ser suficiente
> para entender o projeto inteiro e continuar de onde parou.

**Última atualização:** 17/07/2026 — migração frontend V2 concluída e publicada.

---

## 1. O que é o projeto

Dashboard próprio (ImpulsHub) para uma agência de marketing odontológico mostrar
resultados reais aos clientes: mídia paga (Meta Ads, Google Ads) cruzada com CRM
(GoHighLevel), com marca própria, multi-cliente, seguro por RLS.

**Stack:** Next.js 14 (App Router, TypeScript) + Supabase (Postgres/Auth/RLS) +
Recharts, deploy na Vercel. Pipeline de dados via n8n.

**No ar:** `painel.impulshub.com.br` (o `app.impulshub.com.br` ficou reservado
para o GHL branco). Repositório: `github.com/admddg/impulshub-dashboard`.

**Cliente piloto:** Royal Odontologia (`client_slug = royal_odontologia`).

---

## 2. Os 5 conceitos que guiam todas as decisões

1. **"Tabela guarda, view explica"** — tabelas físicas só recebem dado cru do
   pipeline (n8n). Toda leitura do dashboard passa por *views*. Criar tabela
   nova é exceção.
2. **"CRM vence plataforma"** — resultado real (lead, agendado, ganho, receita)
   vem sempre do CRM. Meta/Google entram como investimento e "conversões da
   plataforma", para comparar — nunca para substituir a verdade do funil.
3. **Evento x Oportunidade** — nem todo lead vira oportunidade formal no CRM
   (no piloto, ~1.165 contatos vs. ~32 oportunidades formais). Contagens de
   funil e listagens usam os **eventos por contato**, não a tabela de
   oportunidades.
4. **Data do evento, não do insert** — sempre `event_datetime`, nunca
   `received_at`. Evita amontoar histórico de backfill no dia da importação.
5. **RLS em duas camadas** — a RLS do Postgres é a dona da segurança (só
   mostra linhas de clientes permitidos via `client_users`). O filtro
   explícito por `client_id` no código escolhe **qual** desses clientes
   mostrar. RLS protege, filtro seleciona — nunca o contrário.

---

## 3. Linha do tempo (fases da construção)

**Fase 1 — Fundação de dados.** Views SQL do zero, RLS multi-tenant validada
com teste real de vazamento (outro cliente = zero linhas). Login Supabase Auth
funcionando ponta-a-ponta.

**Fase 2 — Frontend v1→v9.** Dashboard Next.js com 7 abas construído
iterativamente: Visão geral, Funil, Canais, Meta Ads, Google Ads, Leads,
Eventos. Ver seção 5 para o estado final de cada aba.

**Fase 3 — Rodadas de refinamento (v3→v9).** Ajustes pedidos após uso real:
seletor de datas customizado, canais reorganizados (Entrada x Origem), mix
Conversões-Plataforma-vs-CRM no Meta, tabela de keywords do Google, várias
correções de bugs de dado (ver seção 6 — é a parte mais valiosa deste
documento).

**Fase 4 — Deploy e domínio.** App publicado na Vercel, domínio próprio
configurado (`painel.impulshub.com.br`).

**Fase 5 — V10: multi-cliente.** Migração de cliente único/hardcoded para
rotas por slug (`/clientes/[client_slug]/dashboard`), com validação de acesso
via RLS. Publicada em produção com sucesso.

**Fase 6 — Correções de dado + caça de bugs de truncamento (09–15/07).**
Investigações com dado real da Royal: mudança de metodologia do funil para
**coorte de leads**, investigação forense de duplicidade, gap de atribuição
Meta (Form Nativo sem `meta_ad_id`). Quatro ocorrências do mesmo bug
encontradas e corrigidas: o PostgREST cortava respostas >1.000 linhas
silenciosamente — resolvido criando views de agregação no banco (nunca
buscar eventos crus pro navegador). Abas Diário (v14), Canais, Meta e Leads
todas corrigidas. Painel `/operacao` criado para saúde dos workflows n8n.

**Fase 7 — Revisão conceitual V2 do banco (15/07).** Outro colaborador
conduziu uma revisão completa da metodologia analítica: grãos explícitos,
`event_code` como fato oficial, pessoa ≠ oportunidade, `NULL` ≠ zero,
atribuição estritamente técnica, coorte vs. diário formalizados, uma view
canônica por canal de mídia. 17 views V2 criadas e validadas com Template
e Royal. Funções `get_client_overview_v2`, `get_meta_ads_summary_v2` e
`get_google_ads_summary_v2` criadas e auditadas. Performance otimizada
(94,2% de redução no tempo da RPC Meta — de 2.350ms para 137ms).
Backfill Clinicorp da Royal removido com backup em `private.backfill_archive`.

**Fase 8 — Migração frontend V2 (16–17/07).** Dashboard inteiro portado
para as fontes canônicas V2. Processo com múltiplas rodadas de revisão com
o time de banco antes de cada alteração. Principais mudanças: carregamento
sob demanda no Meta (uma chamada por sub-aba, não 4 simultâneas), estado de
erro com retry, paleta de cores Impuls, hierarquia correta de nome do
criativo (`ad_name` → `creative_name` → `creative_id`). v24 publicada.

**Onde estamos agora:** dashboard V2 publicado em produção, todas as 8 abas
consumindo fontes canônicas V2, performance validada.

---

## 4. Bugs reais encontrados — causa raiz e correção (a parte mais valiosa)

Esta seção existe porque cada um desses bugs consumiu tempo real de
diagnóstico. Documentar a causa raiz evita repetir a investigação.

### 4.1 — URL do Supabase com `/rest/v1` duplicado
**Sintoma:** `supabaseUrl is required` ou erros 404 estranhos em login.
**Causa:** a variável `NEXT_PUBLIC_SUPABASE_URL` no `.env.local` foi colada
com `/rest/v1` no final (copiado da tela errada do Supabase).
**Correção:** a URL deve terminar exatamente em `.supabase.co`, nada depois.
**Recorrência:** aconteceu mais de uma vez ao recriar `.env.local` — é o
primeiro lugar a checar sempre que login ou fetch falha de forma estranha.

### 4.2 — RLS ativada sem política = bloqueio silencioso
**Sintoma:** SELECT funciona perfeitamente como admin no SQL Editor, mas o
app (usuário `authenticated`) recebe sempre `[]`, **sem erro nenhum**.
**Causa:** a tabela base tinha `ROW LEVEL SECURITY` ativada mas **nenhuma
política** criada. Postgres, nesse caso, bloqueia tudo por padrão — e não
lança erro, só retorna vazio.
**Correção:** `CREATE POLICY ... USING (private.user_can_access_client(client_id))`
igual ao padrão das tabelas que já funcionavam.
**Como diagnosticar rápido:**
```sql
select c.relname
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname='public' and c.relkind='r' and c.relrowsecurity=true
  and not exists (select 1 from pg_policies p where p.tablename = c.relname);
```
Isso lista toda tabela "armadilha" de uma vez. Já foi usado para varrer o
banco inteiro depois do primeiro caso (`google_ads_keywords_daily`).

### 4.3 — `security_invoker` ausente = view não herda RLS do usuário real
Views sem `WITH (security_invoker = true)` rodam com a permissão do dono da
view, não do usuário logado — quebra o isolamento por cliente. Toda view do
projeto usa esse parâmetro por convenção agora.

### 4.4 — `CREATE OR REPLACE VIEW` não permite mudar colunas
Postgres recusa `REPLACE` se a lista de colunas mudou (erro `42P16: cannot
drop columns from view`). Correção: `DROP VIEW IF EXISTS` antes do
`CREATE`, sempre reaplicando os `GRANT`s depois (o DROP os remove).

### 4.5 — Funil com "primeira conversa" sempre zerada
**Causa:** `v_crm_funnel_daily` contava primeira_conversa/agendado/ganho a
partir de `v_crm_opportunities` (só ~32 linhas no piloto, com datas de etapa
raramente preenchidas), mas os eventos reais (354 primeiras conversas)
viviam em `v_crm_events_enriched`.
**Correção:** reescrever a view para contar tudo a partir dos eventos
(`event_code`), mesma fonte usada para leads. Ver `docs/sql/04_fix_funnel.sql`.
**Resultado:** de "Leads 1193, Primeira conversa 0, Agendados 32, Ganhos 0"
para "Leads 1193, PC 354, Agendados 150, Ganhos 2, Perdidos 127" — números
reais e coerentes com a aba Leads.

### 4.6 — Imagens de criativos Meta quebradas (403) ao tentar melhorar resolução
**Tentativa 1 (errada):** remover o parâmetro `_p64x64` da URL do fbcdn via
regex, achando que isso "destravaria" a resolução.
**Por que falhou:** essas URLs são **assinadas** — o parâmetro `oh=` é um
hash que cobre o `stp=` (onde mora o `_p64x64`). Qualquer edição no path
invalida a assinatura → 403 Forbidden. Confirmado com teste direto no
navegador.
**Correção real:** reverter para usar a URL **intacta** (sem editar nada).
A melhoria de resolução de verdade só vem do **sync trazer uma URL maior já
assinada** — resolvido no backend chamando `/adcreatives` em vez de `/ads`,
com `thumbnail_width=600, thumbnail_height=1067` (formato 9:16, melhor para
Reels/Stories). Lição: nunca editar URLs assinadas de CDN de terceiros.

### 4.7 — Tabela de keywords do Google sempre vazia no app
**Descartado por diagnóstico, em ordem:** não era erro de coluna (SELECT
direto funcionava), não era filtro de data (testado com range amplo), não
aparecia erro nenhum no console do navegador.
**Causa real:** igual ao 4.2 — `google_ads_keywords_daily` tinha RLS ativada
sem política. Confirmado comparando `pg_policies` dela (vazio) com a de
`google_ads_daily` (que tinha e funcionava).
**Licença:** ausência de erro no console + SELECT funcionando como admin é
a assinatura clássica de "RLS sem política". Ver 4.2 para o diagnóstico
padrão.

### 4.8 — Atribuição de canal Meta (join evento→campanha)
Leads do CRM só têm `meta_ad_id`; para agregar por campanha/conta, junta-se
via `meta_ads_daily` (mapa distinct `ad_id → campaign_id/account_id`).
Confirmado por auditoria: 125 eventos com `meta_ad_id`, todos os 125 casam
com a mídia (100% de match) — a maioria dos leads não tem `meta_ad_id`
porque entram por WhatsApp direto/formulário, sem o clique-to-whatsapp do
anúncio. Isso é esperado, não é bug.

---

## 5. Estado atual do frontend (V24 — V2)

**Rotas:**
```
/login
/dashboard                              redirecionador: 1 cliente → direto; vários → /clientes
/clientes                               seletor (lista clientes permitidos)
/clientes/[client_slug]/dashboard       dashboard real, 8 abas
/operacao                               painel agência-wide (só multi-cliente)
```

**As 8 abas:**
- **Visão Geral** → `get_client_overview_v2()`. KPIs: Investimento (destaque), Leads, Agendamentos, Receita + Ganhos, CPL, CAC, ROAS.
- **Funil** → `v_crm_funnel_daily_v2`. Total agregado, coorte.
- **Canais** → `v_crm_channels_daily_v2`. 3 seções: Atribuição técnica / Entrada informada / Origem informada.
- **Meta Ads** → `get_meta_ads_summary_v2()`. Contas / Campanhas / Anúncios / Criativos. Carregamento sob demanda.
- **Google Ads** → `get_google_ads_summary_v2()` + `v_google_ads_v2` + `v_google_keywords_v2`.
- **Leads** → `v_client_leads_by_stage_v2`. Paginação 50/página server-side.
- **Eventos** → `v_crm_events_feed_v2`. Feed limpo, 50 eventos.
- **Diário** → `v_crm_events_daily_v2` + `v_client_performance_daily_v2`.

---

## 6. Estado atual do banco (V2)

Ver `docs/BANCO_DE_DADOS.md` seções 12-16. Fontes canônicas: 9 views CRM V2,
`v_meta_ads_v2`, `v_google_ads_v2`, `v_google_keywords_v2`,
`v_client_performance_daily_v2`, `get_client_overview_v2()`,
`get_meta_ads_summary_v2()`, `get_google_ads_summary_v2()`.
Views antigas congeladas/depreciadas — não usar em código novo.

---

## 7. Pendências conhecidas (backlog)



- **WhatsApp não aparece em "Entrada"** — `lead_entrada` vem nulo para a
  maioria dos leads da Royal (1079 de 1190). Causa: automação do GHL que
  deveria gravar "WhatsApp" não está rodando/configurada. Ajuste do lado
  do CRM, não do dashboard.
- **Conversões Google só como total** — sem quebra por tipo de conversão
  (`conversions`/`all_conversions` agregados).排 no roadmap ajustar o sync
  para trazer por `conversion_action`. O gráfico de colunas por dia foi a
  solução interina.
- **Termo de pesquisa (search term) do Google** — decisão consciente de
  **não** perseguir agora; mantido "palavra-chave configurada"
  (`keyword_text`) porque o sync não traz o relatório de search terms e o
  cliente optou por não abrir esse fluxo novo por ora.
- **Onboarding/definir senha** — ainda manual via SQL (criar usuário +
  `client_users`). Aceitável para poucos clientes; vira bloqueador para
  escalar self-service.
- **Blindagem completa de RLS/GRANTs** — revisão profunda de todas as
  tabelas fica para depois de multi-cliente estar 100% estável (mas já foi
  feita uma varredura geral com a query da seção 4.2, e as tabelas sem
  política restantes foram confirmadas como internas/não expostas ao app).
- **Vídeos de criativos Meta** — dependem do sync trazer thumbnail em
  resolução maior (ver 4.6); dashboard já está pronto para exibir assim
  que a URL vier correta.

---

## 8. Notas operacionais (como trabalhar neste projeto)

- **Sempre banco primeiro, frontend depois.** Confirmar schema/colunas reais
  via SELECT antes de escrever qualquer query nova — evita "funciona no SQL,
  vazio no app".
- **Diagnóstico de tela vazia, nesta ordem:** (1) a view retorna dado como
  admin no SQL Editor? (2) tabela base tem GRANT para `authenticated`? (3)
  tabela base tem RLS ativa **e** política? (4) view tem
  `security_invoker=true`? (5) só então investigar o código do frontend
  (filtro de data, nome de coluna).
- **Ao empacotar o app:** `rm -rf node_modules/.cache .next tsconfig.tsbuildinfo`
  antes de zipar; sempre `npm run build` (com env vars fake se preciso) antes
  de entregar, para pegar erro de TypeScript/build cedo.
- **Deploy:** push na branch `main` do GitHub dispara deploy automático na
  Vercel (webhook já configurado). Variáveis de ambiente
  (`NEXT_PUBLIC_SUPABASE_URL` sem `/rest/v1`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`)
  configuradas no painel da Vercel.
- **Teste de segurança obrigatório após mudança de acesso:** tentar acessar
  `/clientes/slug-que-nao-existe/dashboard` — deve bloquear com "acesso não
  autorizado", nunca vazar dado.

---

## 9. Como retomar este projeto numa conversa nova

Se você (Claude ou humano) está começando do zero com este arquivo:

1. O código-fonte completo está em `github.com/admddg/impulshub-dashboard`,
   branch `main` — é a fonte da verdade, sempre mais atual que qualquer
   resumo.
2. `docs/README.md` e `docs/ARQUITETURA.md` no próprio repositório têm a
   versão "viva" desses conceitos — comece por eles.
3. `docs/sql/` tem os scripts de migração já aplicados, na ordem certa.
4. Este arquivo (`DIARIO_PROJETO.md`) é o histórico narrativo — para
   entender *por que* as coisas são como são, não só o que são.
5. Ao investigar qualquer bug novo, seguir o método da seção 8 antes de
   escrever código.
