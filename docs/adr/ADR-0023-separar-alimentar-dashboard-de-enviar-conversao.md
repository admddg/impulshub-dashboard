# ADR-0023 — Separar "alimentar o dashboard" de "enviar conversão"

- **Status:** proposta para a IMP-216
- **Data:** 21/09/2026
- **Decide:** Caio

## Contexto

`crm.emit_opportunity_stage_event` é o trigger `after insert or update of
current_stage_id` em `crm.opportunities`. Ele faz duas coisas na mesma transação
do movimento do card:

1. escreve em `public.events_raw` e `public.events_normalized` com
   `source_system = 'impuls_crm'`;
2. escreve em `public.conversion_outbox`.

Hoje **uma única flag** governa as duas: `clients_base.crm_emits_conversions`.
E a ponte exige `clients_base.ghl_location_id`, lançando exceção quando está
vazio (`IMP-205 ghl_location_id is required for tenant ...`).

Isso produziu uma armadilha para o cliente novo:

- `events_normalized` alimenta **todas** as abas de resultados — Visão geral,
  Funil, Canais, Meta, Google, Leads, Eventos e Diário;
- com a flag desligada, o cliente novo não escreve em `events_normalized` e fica
  com o **dashboard vazio**;
- com a flag ligada e sem `ghl_location_id`, ele **não consegue mover card** — o
  trigger lança exceção.

Ou seja, as duas coisas que a flag juntou são independentes na natureza, mas
foram amarradas por conveniência: **escrever no dashboard** é requisito do
cliente novo sem GHL desde o primeiro dia; **enviar conversão** para Meta/Google
é decisão posterior, irreversível e que só o Caio liga.

Há ainda dois acoplamentos indesejados herdados da ponte original:

- a ponte usa `client_id` e `ghl_location_id` como se fossem a mesma chave —
  `ghl_location_id` aparece em `events_raw.location_id`, em
  `events_normalized.ghl_location_id`/`location_id` e em
  `conversion_outbox.ghl_location_id`;
- a ponte **copia `event_name` e `funnel_step` do evento mais recente do GHL de
  qualquer cliente** (`where source_system = 'ghl' order by event_datetime desc
  limit 1`), ou seja, a nomenclatura do cliente novo depende do histórico de
  outros clientes.

## Decisão

**Separar duas coisas que hoje são a mesma flag.**

### 1. Alimentar o dashboard — nova flag, ligada por padrão sem GHL

A escrita em `events_normalized` (o dashboard) passa a ser governada por uma
flag própria, separada de `crm_emits_conversions`:

- **ligada por padrão** para o cliente **sem GHL**;
- **continua desligada** para os três clientes com GHL — **Royal, Central e
  QuickClean** — porque o GHL já escreve em `events_normalized` para eles, e
  ligar duplicaria o evento.

### 2. Enviar conversão — continua atrás de `crm_emits_conversions`

A escrita em `conversion_outbox` **continua atrás de `crm_emits_conversions`**.
Só o Caio liga, e só depois de IMP-215 a IMP-219. Esta ADR não liga nada.

### 3. `client_id` é a chave canônica; `ghl_location_id` vira opcional

O evento passa a ser identificado por `client_id` (o `tenant_id`). A exigência de
`ghl_location_id` deixa de existir para o caminho de dashboard: cliente sem GHL
escreve com `ghl_location_id` nulo e não pode falhar ao mover card. Onde
`ghl_location_id` existir (clientes com GHL), ele continua sendo gravado como
hoje, sem reescrever histórico.

### 4. Mapa CRM → evento, versionado e independente do GHL de outros clientes

A tradução de etapa CRM para `event_code`, `event_name` e `funnel_step` deixa de
ser copiada do histórico do GHL de outros clientes. Passa a um **mapa versionado
no banco**, próprio do CRM, que não lê `events_normalized` de terceiros nem muda
quando outro cliente altera o vocabulário dele.

### 5. A origem entra no evento — Meta e Google

O evento carrega a origem do card, incluindo os cards criados por **formulário
do site** (IMP-230):

- **Meta:** `ctwa_clid`, `conversion_source`, `meta_ad_id`;
- **Google:** `gclid`, `gbraid`, `wbraid` e UTMs.

Sem isso, o card de formulário (Google) se perde e o dashboard mostra a origem
como orgânica.

## Motivo

O que faz o cliente novo entrar é **ter dashboard, funil e canais sem GHL**.
Isso exige escrever em `events_normalized` desde o primeiro card. Enviar
conversão é outra coisa: é irreversível (evento aceito pela Conversions API não
volta) e é o que a ADR-0017 protegeu ao deixar a ponte inerte. Amarrar as duas
na mesma flag obriga o cliente novo a escolher entre dashboard vazio e card que
não move.

Separar a chave (`client_id`) e o mapa (versionado, próprio do CRM) tira do
cliente novo a dependência de um GHL que ele nunca terá, e tira do vocabulário
dele a influência do histórico de Royal, Central e QuickClean.

## Consequências

- O cliente novo sem GHL passa a ter dashboard alimentado sem `ghl_location_id`
  e sem `crm_emits_conversions`. **Variação zero** em `events_normalized` e em
  `conversion_outbox` para Royal, Central e QuickClean — os três seguem
  exatamente como estão.
- `crm_emits_conversions` deixa de ser a única chave: passa a haver **duas**
  flags com significados distintos. Ninguém liga `crm_emits_conversions` — as
  512 linhas pendentes de agosto/setembro continuam fora de alcance.
- Religa `events_normalized` para `impuls_crm`: o índice
  `events_normalized_crm_opportunity_idx` (dedupe por `opportunity_id` e
  `event_code`) continua sendo o mecanismo de no-op de reentrada.
- O manifesto de objetos tocados pela implementação é de banco: PR vai ao **Head
  antes de qualquer aplicação**, e só o Caio aplica o `APLICAR-*.sql`.

## Fora de escopo

Ligar qualquer flag; o consumidor da `conversion_outbox` (IMP-215); valor e
motivo no ganho/perdido (IMP-217); matriz evento × plataforma (IMP-218);
consumo da origem Google pelo formulário é a IMP-230, que depende desta;
reescrever histórico já gravado em `events_normalized`; alterar a nomenclatura
do GHL dos três clientes existentes.
