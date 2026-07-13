# ImpulsHub — Diário do Projeto

> Arquivo único de contexto. Se você está lendo isso numa conversa nova (com o
> Claude ou com qualquer pessoa), este documento sozinho deve ser suficiente
> para entender o projeto inteiro e continuar de onde parou.

**Última atualização:** 13/07/2026 — coorte de leads estendida a Funil e
mídia paga, seletor de período 15/30/90d, página `/operacao` (saúde de
workflows) no ar.

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
via RLS. Publicada em produção com sucesso, testada (inclusive teste de
segurança com slug inválido → bloqueado corretamente).

**Fase 6 — Correções de dado pós-lançamento (09-13/07).** Fora desta
conversa (com apoio de outro colaborador), uma sequência de investigações
reais: mudança de metodologia do funil para **coorte de leads** (uma pessoa
conta no período em que nasceu, não em que avançou — corrige o "124% de
conversão" impossível que aparecia em janelas curtas), investigação forense
de duplicidade de eventos, e um gap de atribuição Meta (leads de Formulário
Nativo sem `meta_ad_id`) resolvido com backfill real via export do Meta
Lead Center. A mesma lógica de coorte foi depois estendida às views de
mídia paga (`v_meta_campaign_daily`, `v_meta_account_daily`,
`v_google_campaign_daily`). Detalhe técnico completo, com queries e
números reais, em `docs/BANCO_DE_DADOS.md` seções 4.1 a 4.4 — não
duplicado aqui de propósito, para não haver duas fontes da verdade.
Também nesse intervalo: correção do seletor de datas não funcionar nas
abas Meta Criativos/Anúncios (view sem coluna de data — resolvido com
`v_meta_creative_daily`, grão diário, ver seção 4 abaixo), e criação da
observabilidade do pipeline n8n (`workflow_execution_logs` + 2 views de
saúde), documentada em `N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md`.

**Fase 7 — Coorte na UI + painel de Operação (13/07).** Nesta conversa:
seletor de período trocado de 7/30/Datas para **15/30/90 dias/Datas**
(remove o "7 dias", que deixava o CPA de agendamento enganosamente ruim
por falta de tempo de maturação da coorte); banner explicativo retrátil
sobre a lógica de coorte adicionado nas abas Funil, Meta Ads e Google Ads
(`components/CohortNote.tsx`); e nova página **`/operacao`**, primeira
tela agência-wide do dashboard (fora do padrão `/clientes/[slug]/...`),
mostrando saúde dos workflows n8n. Antes de expor essa tela, foi
encontrado e corrigido um vazamento cross-cliente real: a
`v_workflow_health_daily` não tinha nenhuma restrição de acesso — corrigido
direto no banco (não no frontend), ver seção 4 abaixo e
`docs/BANCO_DE_DADOS.md` seção 6.6.

**Onde estamos agora:** produção estável, multi-cliente funcionando, RLS
validada, coorte aplicada em todo o dashboard, observabilidade de pipeline
no ar. Documentação (`docs/README.md`, `docs/ARQUITETURA.md`,
`docs/BANCO_DE_DADOS.md`, `docs/sql/`) mantida no repositório.

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

### 4.9 — Seletor de datas sem efeito nas abas Meta Criativos/Anúncios
**Sintoma:** trocar o período (7/30/Datas) não mudava nada nas abas
Criativos e Anúncios do Meta — sempre mostravam o mesmo total.
**Causa:** a view usada (`v_meta_creative_performance`) agrega **todo** o
período do sync numa linha por criativo, sem coluna de `date` — não havia
o que filtrar.
**Correção:** criada `v_meta_creative_daily` (grão diário, cruzada com CRM
por `meta_ad_id`, mesmas colunas de saída). O frontend passou a usar
`fetchWindowed` em vez de `fetchAll`, agregando por `ad_id` dentro do
período selecionado no client-side (nome/imagem sempre do registro mais
recente da janela). `v_meta_creative_performance` continua existindo no
banco (não foi removida), mas não é mais consumida pelo app.

### 4.10 — Vazamento cross-cliente na `v_workflow_health_daily`
**Contexto:** view criada de propósito sem filtro por `client_id` (é uma
visão agregada "todos os clientes" para a agência). Isso a deixava aberta
para qualquer usuário autenticado — inclusive o login de um cliente único
— consultá-la direto via `supabase-js` e ver dados de outros clientes.
**Por que não dava pra usar RLS convencional:** a view não é
`security_invoker` (precisa contornar a RLS-sem-política da tabela base
`workflow_execution_logs` para conseguir agregar entre clientes).
**Correção:** a regra de acesso foi escrita **dentro da própria view**
(`docs/sql/08_secure_workflow_health.sql`): `WHERE` com subquery contando
quantos clientes ativos o usuário logado (`auth.uid()`) tem em
`client_users` — só retorna linha se for mais de 1. Mesmas colunas de
saída, `CREATE OR REPLACE` sem quebrar nada. Validado: só 2 usuários no
banco se qualificam hoje como multi-cliente, e são exatamente os únicos
que devem enxergar a tela `/operacao`.

---

## 5. Estado atual do frontend (V10)

**Rotas:**
```
/login
/dashboard                              redirecionador: 1 cliente → direto;
                                         vários → /clientes
/clientes                               seletor (lista clientes permitidos)
/clientes/[client_slug]/dashboard       dashboard real, 7 abas
/operacao                               painel agência-wide (saúde dos
                                         workflows n8n) — só multi-cliente
```

**Seletor de período (padrão em Visão geral/Funil/Canais/Meta/Google/Leads):**
15 dias / 30 dias / 90 dias / Datas personalizado. Padrão ao abrir: 30 dias.
("7 dias" existiu até 13/07 — removido por deixar métricas de coorte, como
CPA de agendamento, artificialmente ruins em janelas tão curtas.)

**As 7 abas do cliente e o que cada uma mostra:**
- **Visão geral** — KPIs executivos + comparativo vs. período anterior +
  gráfico de evolução de Leads e CPL por dia.
- **Funil** — barras do funil (lead→conversa→agendado→ganho) + taxas de
  conversão com comparativo vs. período anterior. Banner explicando a
  lógica de coorte (retrátil).
- **Canais** — Leads por Entrada (WhatsApp/Site/Formulário/Outros) e por
  Origem (Meta/Google/Orgânico — buckets simplificados), + tabela cruzada
  Entrada×Origem.
- **Meta Ads** — sub-abas **Contas → Campanhas → Anúncios → Criativos**.
  Mix de colunas: Investido | Conversões Meta (plataforma) | Leads | CPL |
  Agendamentos | CPag (CRM) — todas com coorte de leads desde 13/07.
  Seletor de conta em todas. Anúncios: tabela com CTR/CPC/CPL/CPag por
  criativo. Criativos: grid visual, imagem clicável (zoom), ordenável por
  Investimento/Leads/Agendam./Receita, título (ad_name + headline) abaixo
  da imagem — agora com seletor de período funcionando de verdade (ver
  bug 4.9). Banner de coorte no topo da aba.
- **Google Ads** — gráfico de impressões/cliques/leads por dia + gráfico de
  colunas de evolução de Conversões Google por dia (substituiu uma pizza
  que dependia de dado por tipo que não existe ainda) + tabela de campanhas
  (coorte desde 13/07) + tabela de palavras-chave (keyword configurada, não
  termo de pesquisa — decisão consciente, ver seção 7). Banner de coorte.
- **Leads** — pessoas do funil (nome, telefone, entrada, origem, etapa),
  pills filtráveis por etapa, seletor de datas por **data de entrada**
  (importante para clientes que só têm acesso ao dashboard, sem CRM).
- **Eventos** — feed dos últimos 50 eventos do CRM, com entrada/origem,
  atualiza sob demanda (botão, não é realtime).

**A página `/operacao` (agência, não client-facing):** primeira tela do
dashboard que não segue o padrão por cliente. Dois blocos: tabela "Saúde
por workflow" (14 dias, agregada por workflow+cliente, execuções/sucesso/
erro/parcial/duração média, ordenada por erro primeiro) e feed "Últimas
execuções" (50 mais recentes, todos os clientes, bolinha colorida por
status). Só acessível — de verdade, pelo banco, não só escondida na UI —
para usuários com mais de 1 cliente ativo (ver bug 4.10).

**Segurança multi-cliente:**
- `lib/access.ts` — `getMyClients()` e `resolveClient(slug)`, ambos apoiados
  na RLS de `v_client_profile_safe`.
- `lib/data.ts` — `fetchWindowed`/`fetchAll` exigem `clientId` e sempre
  filtram `.eq('client_id', clientId)`.
- `components/DashboardClient.tsx` — resolve slug → valida → renderiza,
  passando `clientId` (não slug) para as 7 abas.
- Link "Trocar cliente" só aparece se o usuário tiver mais de 1 cliente
  ativo em `client_users` (a maioria dos usuários reais de cliente não vê
  esse link).

---

## 6. Estado atual do banco (views principais)

Ver `docs/ARQUITETURA.md` no repositório para o mapa completo view→aba.
Resumo das views-chave:

- `v_crm_events_enriched` — evento a evento, com canal resolvido.
- `v_crm_opportunities` — 1 linha/oportunidade, atribuição first-touch +
  receita deduplicada + etapa mais avançada (uso limitado — poucos
  registros no piloto).
- `v_crm_funnel_daily`, `v_client_performance_daily`, `v_channel_performance_daily`
  — todas contam a partir de eventos, não de oportunidades.
- `v_meta_account_daily`, `v_meta_campaign_daily` — mix conversões
  plataforma + CRM, com `security_invoker=true`.
- `v_meta_creative_performance` — dados de criativo (imagem, headline,
  métricas), sem coluna de data (agregado no total do período do sync).
- `v_google_campaign_daily`, `v_google_ads_keywords_daily` — idem para
  Google.
- `v_client_leads_by_stage`, `v_client_recent_events` — expõem dado pessoal
  mínimo (nome/telefone), protegidas por RLS.
- `v_client_profile_safe` — nome/slug do cliente sem dado sensível; é a
  view usada para resolver acesso multi-cliente.

Convenção: toda view nova leva `security_invoker = true` + `GRANT SELECT TO
authenticated` no mesmo script, e — se alterar colunas de view existente —
`DROP VIEW IF EXISTS` antes do `CREATE`.

---

## 7. Pendências conhecidas (backlog, não bloqueiam produção)

- **WhatsApp não aparece em "Entrada"** — `lead_entrada` vem nulo para a
  maioria dos leads da Royal (1079 de 1190). Causa: automação do GHL que
  deveria gravar "WhatsApp" não está rodando/configurada. Ajuste do lado
  do CRM, não do dashboard.
- **Conversões Google só como total** — sem quebra por tipo de conversão
  (`conversions`/`all_conversions` agregados). Fica no roadmap ajustar o sync
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
- **46 leads de Form Nativo Meta sem atribuição** — mesmo após backfill via
  Meta Lead Center, 46 de 177 leads seguem sem `meta_ad_id` recuperável;
  causa não identificada (hipóteses: telefone divergente, formatação de
  número antiga). Detalhe em `BANCO_DE_DADOS.md` seção 4.3.
- **Aba "Performance diária"** (Meta/Google, granularidade de conta) para
  acompanhamento de ritmo dia a dia — ideia registrada em 13/07, não
  implementada. As views já existentes (`v_meta_account_daily`,
  `v_google_campaign_daily`) já têm o grão certo para alimentá-la sem
  trabalho novo de banco.
- **Teste formal de acesso `anon` sem sessão** em todas as views
  client-facing, confirmando retorno vazio — ainda pendente, não
  bloqueador (ver `BANCO_DE_DADOS.md` seção 6.4).

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
