# ADR-0026 — Consumidor da `conversion_outbox` (IMP-215)

- **Status:** proposta para a IMP-215
- **Data:** 22/09/2026
- **Decide:** Caio

## Contexto

`public.conversion_outbox` é a fila de envio de conversões server-side para a
Meta (Conversions API) e o Google (Data Manager API). `BANCO_DE_DADOS.md` §2.2
a descreve como "fila", mas o que existe em produção é um **registro**: as
linhas nascem e, quando muito, são entregues **na mesma execução** que as criou.

Dois caminhos escrevem nela hoje:

1. **n8n `1.1`** (`/inbound-events`) grava a linha para os clientes que vêm do
   GHL e, na mesma execução, chama `1.2` (dispatch Meta) e `1.3` (dispatch
   Google). `1.2`/`1.3` recebem **a linha que o `1.1` lhes entrega** ("Get
   Single Meta/Google Outbox"), montam a request e atualizam o `status` de
   volta para `sent`/`skipped`/`failed`. É **empurrão (push), não varredura
   (pull)**.
2. **`crm.emit_opportunity_stage_event`** (a ponte do CRM, IMP-205/216/218)
   grava a linha **de dentro de um trigger de banco**, na transação do
   movimento do card. De banco nasce a linha; **nada chama `1.2`/`1.3` para
   ela.** Esse caminho está inerte: `crm_emits_conversions = false` nos 6
   clientes.

**Estado medido em produção (`mtxnwtqwfagjzkvgsncs`), leitura pura, 22/09/2026:**

| medição | valor |
|---|---|
| `conversion_outbox` por status | `sent` 2328 · `skipped` 1296 · `pending` 512 · `failed` 43 |
| por plataforma | `meta` 3555 · `google_ads` 624 |
| `pending` | 326 `google_ads` (desde 24/08) + 186 `meta` (desde 10/09) |
| `failed` | 41 `meta` + 2 `google_ads` (nada os retenta) |
| coluna `source_system`/`client_id` na outbox | **não existe** (a origem só se sabe pelo `events_normalized` ligado) |
| crons no banco | 2: `crm-stevo-parser` (1 min) e a retenção da IMP-231 (03:15). **Nenhum consome a outbox** |
| `events_normalized` com `source_system='impuls_crm'` | **0 linhas** (a ponte do CRM nunca emitiu) |

Colunas de controle presentes: `status`, `attempts`, `next_attempt_at`,
`last_error`, `sent_at`, `response`, `external_job_id`, `http_status`,
`error_code`/`error_subcode`/`error_details`, `match_keys`, `dispatch_method`,
`destination_config`. Índices: `idx_conversion_outbox_platform_status_next`
(`platform`,`status`,`next_attempt_at`) e `idx_conversion_outbox_status_created`
(`status`,`created_at desc`) — desenhados para varredura; e um índice único
vivo **`conversion_outbox_event_platform_uidx`** (`normalized_event_id`,
`platform`) que garante uma linha por evento × plataforma.

Ou seja: **o desenho de fila está pronto (colunas e índices de varredura e de
idempotência existem), mas o consumidor que varre a fila nunca foi construído.**
Hoje quem "consome" é um empurrão síncrono do `1.1`, que não alcança as linhas
criadas pelo CRM nem as 512 `pending` + 43 `failed` paradas.

`ADR-0017` já nomeia isso ("a outbox é um registro, não uma fila") e a
`ROADMAP` §5 fecha: **"Pronto quando: mover um card na Impuls faz o evento
aparecer no Gerenciador de Eventos da Meta, e o runbook de ativação (IMP-219)
existe."** A IMP-215 é o consumidor que falta; a IMP-219 é o runbook.

## Decisão (proposta — Caio decide)

**A resposta mais provável é a opção (c): combinação.** Reusar a **lógica de
request** do `1.2`/`1.3` (não reescrever as chamadas à CAPI / Data Manager), mas
o que falta **não é ajustar o `1.2`/`1.3` — é construir o consumidor que hoje
não existe**: um varredor que pega linhas elegíveis e as entrega ao dispatcher
por plataforma.

Por que **não** (a) ("é só o mesmo `1.2`/`1.3` filtrando por `source_system`"):

- o `1.2`/`1.3` **não filtra nada**: ele recebe uma linha já escolhida pelo
  `1.1`. Não há nó de varredura nele para "ajustar";
- a outbox **não tem `source_system`** (medido). "Pegar linhas
  `source_system='impuls_crm'`" nem é expressável direto na tabela — exigiria
  join com `events_normalized`;
- a linha do CRM nasce de **trigger de banco**, não do `1.1`. Não há quem chame
  o `1.2`/`1.3` para ela.

Por que **não** (b) ("dispatcher novo do zero"): jogaria fora a lógica de
request e de atualização de status que já está **ao vivo e correta** para 2.328
`sent`. Reescrever a chamada à Meta/Google é onde mora o risco irreversível.

Por que **(c)** é o caminho: **um consumidor novo (varredor) + a lógica de
envio existente**. Onde o consumidor mora (n8n agendado ou banco) **é decisão do
Caio** — ver "Precisa do Caio/Coordenador".

### O que a IMP-215 precisa entregar, em qualquer das opções

1. **Varredura segura:** selecionar linhas elegíveis **por plataforma**, com
   *claim* atômico (`SELECT … FOR UPDATE SKIP LOCKED` ou transição de status
   `pending → sending`) para que duas execuções concorrentes não enviem a mesma
   linha duas vezes.
2. **Reuso do envio existente:** reaproveitar a montagem de request e o
   mapeamento de status do `1.2`/`1.3`, não reimplementar.
3. **Corte que impede o desastre (ADR-0017):** **as 512 `pending` (e 43
   `failed`) de julho–setembro NÃO podem ser enviadas.** Corte explícito por
   `created_at` (e/ou por escopo de origem). Sem isso, a primeira varredura
   despeja eventos de agosto no Gerenciador de Eventos — irreversível.
4. **Retry e DLQ:** usar `attempts`/`next_attempt_at` com backoff e limite;
   declarar quem observa `failed` (hoje ninguém — 43 linhas paradas provam).
5. **Observabilidade:** a outbox já alimenta superfícies de saúde de tracking em
   produção; o consumidor precisa deixar rastro verificável (não depender só de
   `workflow_execution_logs`).

## Motivo

Ligar `crm_emits_conversions` para o cliente novo (o objetivo do projeto) só faz
sentido quando existir **ponta a ponta**: o card move → a linha nasce →
**alguém entrega** → o evento aparece na plataforma. Sem a IMP-215, ligar a flag
produz exatamente o estado que a `ROADMAP` §5 reprova: linhas `pending` que
nunca saem, e a leitura errada "liguei e não chegou".

E a IMP-215 é o ponto **irreversível** da etapa: evento aceito pela Conversions
API não volta. Por isso ela é o item de maior risco do bloco IMP-215…219 — muito
mais risco operacional do que volume de SQL.

## Consequências

- A IMP-215 provavelmente **não é uma tarefa de banco** como as vizinhas
  (IMP-216/217/218). É **n8n + banco**, com a maior parte da superfície em
  **n8n de produção, que não tem staging** — o teste tem de ser desenhado, não
  assumido.
- Se o consumidor for um workflow n8n novo, ele toca a superfície que o
  `AGENTS.md` marca como "não tocar sem tarefa explícita". A IMP-215 **é** essa
  tarefa, mas qual workflow e se pode ser um novo **é decisão do Caio**.
- A ponte do CRM (IMP-216/218) pode ser aplicada sem risco: ela **só cria
  linha**; não entrega. A ordem natural é o consumidor (215) existir antes de a
  flag ligar.
- As 512 `pending` + 43 `failed` antigas permanecem paradas por decisão:
  **nunca enviar**. O consumidor nasce com corte.
- Duas flags e dois caminhos (GHL pelo `1.1`, CRM pelo consumidor novo) passam a
  coexistir. Se o consumidor varrer por `status` sem escopo de origem, ele pode
  reprocessar linhas do GHL que já foram entregues — daí o *claim* e o corte.
- Detalhe medido que **reconcilia uma premissa da IMP-218**: em produção,
  `ghl_location_id`, `route` e `meta_event_name` estão **`NULL`-áveis** (o dump
  em `supabase/staging/production-schema.sql` mostra `NOT NULL`, ou seja, o dump
  está atrás da produção). O bloqueio "cliente sem GHL não consegue linha na
  outbox" (IMP-218, decisões 9 e 10) **pode já estar resolvido em produção** —
  o Head deve confirmar antes de tratar como bloqueio.

## Fora de escopo

- Ligar qualquer flag (`crm_emits_conversions`) — é a IMP-219 + Caio.
- Valor/moeda e motivo (IMP-217) e a matriz evento × plataforma (IMP-218).
- Reescrever o `1.1`/`1.2`/`1.3` além do necessário para virar o consumidor.
- Enviar as linhas antigas (`pending`/`failed` de julho–setembro).
- Migrar o n8n para "Central Impuls" própria (roadmap sem execução).

## Precisa do Caio (antes de implementar)

Ver a lista completa na tarefa: `docs/task-files/TASK-IMP-215.md`, seções
"Decisões em aberto/`PENDENTE`" e "Precisa do Caio/Coordenador ANTES de
implementar". As três decisões de topo são: **(1)** confirmar a opção (c) e
onde mora o consumidor (n8n agendado vs banco); **(2)** a política de corte e
retry; **(3)** acesso/leitura dos JSONs do `1.2`/`1.3` para reaproveitar a
lógica de envio sem confirmar no escuro.
