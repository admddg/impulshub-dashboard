# ImpulsHub — Histórico e lições

> A parte mais valiosa do projeto. Cada bug aqui custou tempo real de
> investigação. Consultar antes de decisões arquiteturais e ao investigar
> comportamento estranho.

---

## Linha do tempo

**Fase 1 — Fundação.** Views SQL do zero, RLS multi-tenant validada com
teste real de vazamento. Login Supabase Auth ponta a ponta.

**Fase 2 — Frontend v1→v9.** Dashboard Next.js com 7 abas, construído
iterativamente.

**Fase 3 — Refinamento (v3→v9).** Ajustes após uso real: seletor de datas
customizado, canais reorganizados, mix conversões-plataforma-vs-CRM,
tabela de keywords.

**Fase 4 — Deploy.** Vercel + domínio próprio.

**Fase 5 — V10 multi-cliente.** Migração de cliente hardcoded para rotas
por slug com validação via RLS.

**Fase 6 — Caça aos bugs de truncamento (09–15/07).** Quatro ocorrências
do mesmo bug. Mudança de metodologia do funil para coorte. Painel
`/operacao` criado. Ver seção "O bug que apareceu 4 vezes" abaixo.

**Fase 7 — Revisão conceitual V2 do banco (15/07).** Feita pelo time de
banco: grãos explícitos, `event_code` como fato, pessoa ≠ oportunidade,
`NULL` ≠ zero, atribuição técnica, coorte vs. diário formalizados. 17 views
V2 criadas. Performance otimizada (94,2% de redução na RPC Meta).

**Fase 8 — Migração frontend V2 (16–17/07).** Dashboard inteiro portado
para as fontes canônicas. v24 publicada.

---

## O bug que apareceu 4 vezes: truncamento silencioso

**A classe de bug mais cara do projeto.** Vale entender profundamente.

### O mecanismo

O PostgREST (camada REST do Supabase) tem um **limite padrão de ~1.000
linhas por resposta**. Quando estoura, ele **corta silenciosamente** — sem
erro, sem aviso, sem nada no console. O código recebe uma resposta válida,
só que incompleta.

**Sintoma:** números errados, dias sumindo, contas desaparecendo. Sem
padrão aparente, porque a ordem em que as linhas são cortadas não é
necessariamente cronológica.

**Assinatura:** um número redondo demais na tela. Ver "1000" exato foi o
que denunciou a quarta ocorrência.

### As quatro ocorrências

| # | Onde | Causa | Correção |
|---|---|---|---|
| 1 | Aba Diário | Buscava eventos crus (100+/dia) para agregar no navegador | View `v_client_daily_pulse` agregando no banco |
| 2 | Aba Canais | Mesmo padrão — eventos crus para bucketizar | View `v_client_lead_channel_daily` |
| 3 | Meta (Contas/Campanhas/Criativos) | 2.169 linhas em 90 dias, × 2 (buscava período anterior à toa) | 3 RPCs com agregação no banco |
| 4 | Aba Leads | `fetchAll` buscava **toda** a tabela (2.164 contatos) sem filtro, e só depois filtrava no navegador | Filtro de data na query + paginação server-side 50/página |

**A quarta foi a pior** porque não dependia do período selecionado — a
tabela inteira já estourava o limite sempre, independente do filtro.

### A regra que nasceu disso

> **Nunca buscar linhas cruas para o navegador quando o volume pode
> crescer.** Sempre agregar no banco (view ou RPC) ou paginar
> explicitamente com `.range()`.

E o corolário: **desconfiar de números redondos**. 1000 exato quase nunca
é dado real.

---

## Bugs de metodologia

### Régua divergente entre banco e frontend (o erro mais caro)

**O que aconteceu:** ao criar RPCs para resolver o bug de truncamento no
Meta, reconstruí a lógica de coorte **de memória**, sem verificar como ela
estava implementada nas views existentes. Criei uma versão que contava por
data real do evento (régua B) quando as views oficiais contavam por safra
de lead (régua A).

**Resultado:** duas metodologias divergentes no mesmo dashboard. Uma
investigação longa comparando os números (diferença de ~2%) que nunca
fechou — descartamos as duas hipóteses testadas e o trabalho inteiro foi
abandonado quando o banco foi reescrito na V2.

**A lição:** quando existe lógica de negócio no banco, **ler o SQL real**
antes de replicar. `pg_get_functiondef()` e `information_schema.views` são
seus amigos. Nunca reconstruir de memória.

**A lição maior:** a causa raiz não foi o erro pontual — foi ter a mesma
regra em dois lugares que não conversam. Regra de negócio deve morar num
lugar só (banco), e o frontend consome.

### CPA/ROAS tecnicamente corretos mas enganosos

**O que aconteceu:** implementei CPA e ROAS por conta/campanha no Meta. Os
números apareceram absurdos (CPA de R$ 22.547) e a maioria vazia.

**Investigação:** os cálculos estavam **certos**. O problema era a base:
só 3 de ~30 ganhos tinham `meta_ad_id` rastreável até o anúncio. Dividir
o investimento total por 1-2 ganhos rastreáveis dá números estratosféricos.

**Decisão:** remover as métricas até a atribuição melhorar. Um número
correto que comunica algo falso é pior que não ter o número.

### Proxy de campo errado

**O que aconteceu:** usei `acquisition_buying_contacts` como proxy para
"Ganhos" porque a função de overview não retornava `crm_ganhos`.

**Por que estava errado:** são conceitos diferentes. "Ganhos" é jornada por
contato; "compradores de aquisição" é métrica comercial. Na Royal:
`crm_ganhos = 33` vs `acquisition_buying_contacts = 0`.

**Correção:** o time de banco adicionou `crm_ganhos` à RPC. A lição: quando
um campo não existe, **pedir** em vez de aproximar com outro.

---

## Bugs de dado e integração

### Seletor de data sem efeito no Meta Criativos

A view usada agregava todo o período numa linha por criativo, sem coluna
de `date` — não havia o que filtrar. Correção: view com grão diário.

### Imagens de criativos quebradas (403 / ícone quebrado)

**Duas causas diferentes, em momentos diferentes:**

1. **Editar URL assinada** — tentei aumentar a resolução modificando
   parâmetros da URL do CDN. As URLs do Meta são assinadas; qualquer
   alteração invalida a assinatura. Lição: nunca editar URLs assinadas de
   CDN de terceiros.

2. **URL expirada** — as URLs do CDN do Meta têm validade de ~7 dias
   (parâmetro `oe=` no final, em hex). Se o sync de mídia não roda, as
   URLs expiram e as imagens quebram. **Não é bug de frontend nem de
   banco** — é frequência de sync do n8n. Diagnóstico: comparar o `oe=`
   entre clientes que funcionam e que não funcionam.

### Vazamento cross-cliente na view de workflows

`v_workflow_health_daily` foi criada de propósito sem filtro por
`client_id` (visão agregada da agência), mas isso a deixava aberta para
qualquer usuário autenticado consultar via `supabase-js`.

**Complicação:** não era `security_invoker`, então RLS convencional não
resolvia. **Correção:** trava dentro da própria view — `WHERE` com subquery
contando clientes ativos do usuário > 1.

### Colunas assumidas que não existiam

- `video_id` em `v_meta_ads_v2` — copiei da tabela antiga, a view nova não
  tem
- `event_datetime` em `v_crm_events_enriched` — nome diferente do assumido

**Lição:** `information_schema.columns` antes de escrever query.

---

## Armadilhas do ambiente

### CSV truncado no SQL Editor

Pedi colunas de 8 views de uma vez. O resultado veio com exatamente 100
linhas — o limite de exibição. Duas views vieram incompletas
(`v_crm_events_feed_v2` tinha 63 colunas, recebi 35).

**Prática que resolveu:** sempre confirmar com `count(*)` agrupado por
tabela antes de trabalhar em cima do resultado. Se bater com o esperado,
o dado está completo.

### Anexos vazios

Ocasionalmente anexos chegam sem conteúdo. Quando acontecer, pedir texto
colado. CSVs e prints funcionam normalmente.

### Chamadas duplicadas em desenvolvimento

React StrictMode monta componentes duas vezes em dev — chamadas duplicadas
que **não** acontecem em produção. Para medir performance real:
`npm run build && npm run start`, nunca `npm run dev`.

Mas atenção: tive um caso de duplicação **real** (dois `useEffect`
disparando o mesmo `loadDim`). A guarda por status resolveu, mas o correto
foi consolidar em um único effect.

---

## Decisões conscientes (não são pendências)

| Decisão | Motivo |
|---|---|
| Keywords = termo configurado, não search term | Sync não traz o relatório de search terms; cliente optou por não abrir esse fluxo |
| Conversões da plataforma (Meta/Google) fora das tabelas | O que importa são as conversões do CRM |
| Cruzamento Entrada × Origem removido | Complexidade visual sem ganho decisório. Pode voltar via `v_client_leads_by_stage_v2` se necessário |
| Ticket médio fora da Visão Geral | Não vinha pronto do banco; evitar recalcular no frontend |
| Backfill Clinicorp não liberado | 25 ganhos sem `opportunity_id` — misturaria grãos. Plano: data de corte + import único quando a operação estabilizar |

---

## Pendências conhecidas (backlog)

**De dado (não bloqueiam):**
- WhatsApp não aparece em "Entrada" — `lead_entrada` nulo para a maioria
  dos leads da Royal. Automação do GHL não configurada
- Conversões Google só como total, sem quebra por `conversion_action`
- Atribuição de ganho incompleta — poucos ganhos com `meta_ad_id`
- "Revisar" como valor de canal — pedido ao time para unificar com "Não
  informado" (frontend omite por enquanto)

**De estrutura:**
- Onboarding/senha ainda manual via SQL
- Remoção formal das views antigas depreciadas
- Consolidar as 4 views de qualidade em fonte única
- Google: consulta direta a `v_google_ads_v2` sem paginação explícita
  (volume baixo hoje, mas sem proteção se crescer)

---

## O padrão de investigação que funciona

Estabelecido depois de vários ciclos. Quando aparece um número estranho:

1. **Hipótese explícita** — o que eu acho que está acontecendo e por quê
2. **Query que confirma ou descarta** — nunca ir direto ao código
3. **Interpretar o resultado honestamente** — inclusive quando derruba a
   hipótese (aconteceu várias vezes)
4. **Só então corrigir**

E quando a investigação trava depois de 2-3 hipóteses descartadas: parar,
avaliar se vale continuar, e considerar que o problema pode estar numa
camada diferente da que estamos olhando.
