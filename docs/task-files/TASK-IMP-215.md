# IMP-215 — Consumidor da `conversion_outbox` (quem entrega as linhas `pending` ao Meta CAPI e ao Google)

**Tarefa MISTA (n8n + banco): executor---plataforma + revisão do Head antes de
qualquer aplicação.** Este arquivo foi escrito por `executor-plataforma-2`
(documentação, barato) e **não implementa SQL nem workflow n8n algum**.

ADR de referência: `docs/adr/ADR-0026-consumidor-conversion-outbox.md` (leia
inteira; a análise (a)/(b)/(c) está lá). Nada aqui inventa requisito — onde não
há decisão tomada está escrito **PENDENTE** e listado no bloco "Precisa do
Caio/Coordenador ANTES de implementar".

REFS lidas para escrever isto: `docs/adr/ADR-0017-...` (contexto completo da
fila pendente: "a outbox é um registro, não uma fila"; as 512 `pending` **não
podem ser enviadas**), `docs/adr/ADR-0023-...` (separar "alimentar o dashboard"
de "enviar conversão"; `client_id` como chave canônica), `docs/adr/ADR-0026-...`
(a análise (a)/(b)/(c)), `docs/ROADMAP.md` §5 (estado medido e "pronto quando"),
`docs/BANCO_DE_DADOS.md` §2.2 (colunas de controle: `status`, `attempts`,
`next_attempt_at`, `last_error`) e §8 (pipeline n8n, matriz de dispatch),
`docs/N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md` §3/§4/§5 (fluxo `1.1` →
`IF Should Dispatch Meta → 1.2` / `IF Should Dispatch Google → 1.3`; `1.2`/`1.3`
recebem **uma** linha e atualizam `status`), `docs/task-files/TASK-IMP-218.md`
(decisões 4, 9, 10, 12 sobre `route`/`meta_event_name`/`ghl_location_id`) e a
**definição viva** de `public.conversion_outbox` em produção
(`mtxnwtqwfagjzkvgsncs`, somente leitura, 22/09/2026).

---

> **Objetivo real deste documento:** dar ao Head e ao Caio o **tamanho da
> entrega** antes de decidir começar. As estimativas e riscos abaixo valem mais
> que o detalhe de SQL.

**Estimativa de tamanho (para o Caio decidir se começa): MÉDIO–ALTO** — a maior
do bloco IMP-215…219, e a **mais arriscada**, não a maior em linhas de código.

| Bloco de trabalho | Tamanho | Observação |
|---|---|---|
| Consumidor/varredor (claim + orquestração + reuso do envio) | **M** | lógica nova |
| Ajuste/novo workflow n8n `1.2`/`1.3` | **M** | superfície n8n de **produção** |
| Corte (não enviar antigas) + retry/DLQ + observabilidade | **S–M** | é aqui que mora o risco |
| Teste sem n8n de staging | **M–L** | risco; ver "Testes obrigatórios" |
| Banco (se algo for no banco) | **S** | índices/colunas já existem |

Comparável à IMP-218 em esforço, **superior em risco**: mistura n8n (sem
staging), banco e uma ação **irreversível** (evento aceito não volta).

---

**Objetivo (1 frase):** construir o consumidor que hoje não existe — quem pega
as linhas `pending` de `public.conversion_outbox` (nascidas do CRM quando
`crm_emits_conversions` for ligado, e as que o `1.1` não entregou na hora) e as
entrega à Meta (CAPI) e ao Google (Data Manager API), marcando `sent`/`skipped`/
`failed` com retry — sem nunca enviar as linhas antigas de julho–setembro.

**Decisões já tomadas (não reabrir):**

1. **A ponte do CRM só cria a linha; quem entrega é o consumidor.** A
   IMP-216/217/218 **não** entregam (TASK-IMP-218, decisão 4). A IMP-215 é o
   consumidor que falta (ADR-0017, ordem de correção #3; ROADMAP §5).
2. **Nada aqui liga flag.** `crm_emits_conversions` continua `false` nos 6
   registros. Ligar é IMP-219 + Caio (ROADMAP, "Regras que não se quebram").
3. **As 512 `pending` (326 `google_ads` desde 24/08 + 186 `meta` desde 10/09) e
   as 43 `failed` antigas NÃO podem ser enviadas** (ADR-0017). Qualquer
   varredura precisa de corte por data e/ou escopo de origem. Isto é requisito,
   não recomendação.
4. **A matriz evento × plataforma é a da IMP-218** (`N8N_...` §5 /
   `BANCO_DE_DADOS.md` §8). O consumidor **consome exatamente o que a 218
   produz** e não redefine a matriz. `primeira_conversa` e `perdido` não são
   elegíveis.
5. **Uma linha por (evento, plataforma) já é garantida no banco:** o índice
   único vivo `conversion_outbox_event_platform_uidx`
   (`normalized_event_id`, `platform`) existe em produção. O consumidor não
   pode violá-lo nem criar linha nova; ele **atualiza** a existente.
6. **A outbox não tem `source_system` nem `client_id`** (medido em produção). A
   origem/cliente de uma linha só se sabe via `normalized_event_id` →
   `events_normalized` (`source_system`, `client_id`) → `clients_base`. Nada de
   inventar coluna sem decisão do Head (tabela compartilhada com o n8n).
7. **Reuso da lógica de envio, não reescrita.** `1.2`/`1.3` já entregam Meta e
   Google corretamente ao vivo (2.328 `sent`). Reescrever a request é onde mora
   o erro irreversível — ver ADR-0026.
8. **`1.2`/`1.3` não são um varredor.** Eles recebem **uma** linha do `1.1` e
   devolvem o `status` (N8N_... §4: "Get Single Meta/Google Outbox"). Não há nó
   de varredura a "ajustar".
9. **PENDENTE — onde mora o consumidor.** (i) **workflow n8n agendado** (novo,
   ou extensão do `1.1`/`1.2`/`1.3`) que varre a outbox; ou (ii) **banco**
   (`pg_cron` + função que dá claim e chama as APIs — o que exigiria `pg_net`,
   **dependência nova, proibida sem "sim" do Caio**, AGENTS.md regra 5). **Não
   decidir sozinho.**
10. **PENDENTE — o corte exato.** Qual predicado impede o envio das antigas:
    `created_at >= <data>` (qual?), e/ou `join events_normalized where
    source_system='impuls_crm'`, e/ou `execution/flag-on` marker. Precisa do
    Caio/Coordenador — é a linha que separa "funciona" de "despeja agosto na
    Meta".
11. **PENDENTE — `failed`: retentar ou não?** 43 linhas `failed` existem
    (41 `meta`, 2 `google_ads`) e nada as retenta hoje. Definir se o consumidor
    retenta `failed` recentes (backoff em `next_attempt_at`) e se toca as
    antigas (provável: **não**). E **quem observa `failed`** depois de esgotar
    tentativas (DLQ).
12. **PENDENTE — claim concorrente.** Como o consumidor marca "estou enviando"
    para duas execuções não enviarem a mesma linha (transição
    `pending → sending` com guarda, `SELECT … FOR UPDATE SKIP LOCKED`, ou
    `attempts` incrementado antes do envio). Sem isso, risco de conversão
    duplicada.
13. **PENDENTE — `route`/`meta_event_name` `NOT NULL` (herança da IMP-218,
    decisões 9/10).** **Reconciliação medida:** em produção as três colunas
    (`ghl_location_id`, `route`, `meta_event_name`) estão **`NULL`-áveis** hoje;
    o dump `supabase/staging/production-schema.sql` as mostra `NOT NULL` (dump
    atrás da produção). Se a produção for a verdade, o bloqueio da IMP-218 pode
    já estar resolvido — **o Head confirma** antes de tratar como bloqueio.
14. **PENDENTE — acesso aos JSONs do `1.2`/`1.3`.** Reaproveitar a lógica de
    envio exige ler os workflows reais (como leem a linha, mapeamento de status,
    retry). Este documento descreve por documentação; **a confirmação direta
    depende de acesso n8n que o Executor não tem** (não há credencial n8n no
    repositório). Confirmar com o Coordenador/Head.

**Escopo (o que fazer):**

- **Construir o consumidor** (forma decidida na decisão 9):
  - **varredura elegível:** linhas da outbox `pending` (e, conforme decisão 11,
    `failed` recentes) por plataforma, respeitando **o corte** (decisão 10);
  - **claim atômico** (decisão 12) antes de enviar;
  - **entrega reusando o envio do `1.2`/`1.3`** (decisão 7): montar a request a
    partir das colunas da linha (`platform_event_name`,
    `platform_conversion_action`, `platform_account_id`,
    `platform_manager_account_id`, `dispatch_method`, `destination_config`,
    `payload`, `match_keys`) — **o payload Google não é o payload Meta**;
  - **atualização de status** com `sent_at`, `response`, `http_status`,
    `error_code`/`error_subcode`/`error_details`, `external_job_id`,
    `external_request_id`, `last_error` — no mesmo vocabulário que o `1.2`/`1.3`
    já gravam (`sent`/`skipped`/`failed`);
  - **retry com backoff**: `attempts`, `next_attempt_at`, limite de tentativas,
    e DLQ/observação de `failed` (decisão 11);
  - **corte que nunca envia as antigas** (decisão 3/10) — com teste que **prova**
    que a varredura deixa as 512 + 43 intactas;
  - **observabilidade** de saúde da fila (o que já existe: as superfícies de
    tracking em produção somam a outbox por status/plataforma).
- **Banco, se houver:** migration + rollback + `APLICAR-*` + gate só se o
  consumidor exigir objeto novo (índice de claim, marca de origem, etc.).
  **Coluna nova na outbox exige Head** (tabela compartilhada com o n8n).
- **Testes** com prova de idempotência/claim (nunca enviar duas vezes a mesma
  linha) e prova do corte.

**Fora de escopo (o que NÃO fazer):**

- ligar `crm_emits_conversions`/`crm_feeds_dashboard` (IMP-219 + Caio);
- valor/moeda e motivo no ganho/perdido (IMP-217) e a matriz evento × plataforma
  (IMP-218) — esta tarefa **consome** o que a 218 produz, não redefine;
- alterar a ponte do CRM (`crm.emit_opportunity_stage_event`) além do que a
  IMP-216/217/218 deixarem;
- reescrever o `1.1` além do necessário; mexer no parser do Stevo ou nos
  workflows de mídia (`2.1`/`2.2`, `0.1`/`0.3`/`0.4`) — **proibido sem tarefa
  explícita** (AGENTS.md);
- **enviar** as linhas antigas `pending`/`failed` de julho–setembro;
- migrar o n8n para uma "Central Impuls" própria (roadmap sem execução);
- front (`app/`, `components/`, `lib/`);
- aplicar em produção sem autorização do Caio (produto de escrita **e** o envio
  em si, que é irreversível).

**Base em produção a ler antes (objetos, funções, políticas) — SOMENTE LEITURA:**

Leitura pura (`SELECT`) antes de escrever qualquer linha. **A definição viva
manda; nunca arquivo antigo.** Medido em `mtxnwtqwfagjzkvgsncs` em 22/09/2026:

- `information_schema.columns` de `public.conversion_outbox` — 31 colunas;
  nulabilidade de `ghl_location_id`/`route`/`meta_event_name` (**`NULL`-áveis em
  produção** — decisão 13); **não existe** `source_system`/`client_id`
  (decisão 6); valores distintos de `platform` já gravados (`meta`,
  `google_ads` — decisão 12 da IMP-218 confirma o literal `google_ads`).
- `pg_constraint`/`pg_indexes` de `public.conversion_outbox` — em especial
  `conversion_outbox_event_platform_uidx` (único por evento×plataforma),
  `conversion_outbox_normalized_event_id_platform_route_meta_e_key` e
  `conversion_outbox_unique_event`, e os índices de varredura
  `idx_conversion_outbox_platform_status_next` e
  `idx_conversion_outbox_status_created`.
- Contagens de partida (sem número fixo no script): `conversion_outbox` por
  `status` × `platform` e por faixa de `created_at`; e o join com
  `events_normalized` por `source_system`/`client_id`.
- **Como o `1.2`/`1.3` leem a linha e mapeiam o status** — documentação (§4) e,
  se houver acesso n8n, os JSONs reais (decisão 14). **Se não der para confirmar,
  escalar antes de codificar** (ver "Escalar ao Head se").
- ACL/`pg_policies` de `conversion_outbox` para `anon`/`authenticated`/
  `service_role` (a tabela é interna; `authenticated`/`anon` não escrevem).
- Superfícies de observabilidade que já leem a outbox (o consumidor não deve
  quebrá-las nem depender só de `workflow_execution_logs`).

**Arquivos previstos (a forma depende da decisão 9):**

Se **n8n**: os JSONs dos workflows (novo consumidor e/ou ajuste do
`1.2`/`1.3`), no diretório de workflows do projeto, com o padrão de log em
`workflow_execution_logs`.

Se **banco**: `supabase/migrations/20261005000000_imp215_outbox_consumer.sql` +
`.rollback.sql` + `supabase/acceptance/APLICAR-imp215.sql` +
`imp215-acceptance.sql` + `imp215-isolation-claim.sql`.

O timestamp segue a sequência depois de `20261004000000` (IMP-218). **Nomes de
arquivo são a única coisa maleável aqui.**

**Critérios de aceite (verificáveis, com número):**

1. **O consumidor entrega uma linha elegível.** Com uma linha de teste
   (`platform='meta'`, `status='pending'`, dentro do corte) e a plataforma
   respondendo sucesso ⇒ a linha vira `sent` com `sent_at` não nulo e
   `attempts` incrementado — **exatamente 1** requisição enviada (medida por
   `http_status`/`response`).
2. **Nenhuma linha antiga é enviada.** Após rodar a varredura completa, o
   conjunto `{pending, failed}` com `created_at < <corte>` tem **delta 0**:
   as **512 `pending` + 43 `failed`** continuam exatamente como estavam.
3. **Idempotência / sem envio duplo.** Duas execuções concorrentes sobre a mesma
   linha ⇒ **1 envio** (o *claim* impede o segundo); repetir a varredura em
   cima de linha já `sent` ⇒ **delta 0** de envios.
4. **Falha tratada com retry.** Plataforma devolvendo erro transitório ⇒
   `status='failed'` (ou o estado intermediário decidido), `attempts` +1,
   `next_attempt_at` no futuro (backoff) e `last_error` preenchido; após N
   tentativas, a linha **para** e fica visível como falha (DLQ) — número de
   tentativas medido, igual ao decidido.
5. **Plataforma por plataforma.** Linha `meta` vai pela CAPI e linha
   `google_ads` pela Data Manager API, com `platform_event_name` /
   `platform_conversion_action` da linha (não um payload Meta renomeado) — prova
   literal dos campos enviados.
6. **Variação ZERO para os clientes com GHL na fatia já entregue.** A varredura
   **não** reprocessa linhas de GHL já `sent`/`skipped`: contagem `sent` por
   `(platform, status)` antes/depois, diferença **exatamente 0** para as linhas
   fora do corte.
7. **Isolamento entre clientes:** o consumidor não mistura dados de clientes
   (a linha resolve `client_id` via `events_normalized`); o teste de isolamento
   no modelo de `supabase/acceptance/imp213-isolation.sql` continua devolvendo
   **só** o `client_id` do próprio usuário (atendente Central
   `bb04435c-fabb-4ba8-b5b5-e0175d9ca17d`, gestor Royal
   `7c3296f4-13c7-42d1-89eb-72aecec905ba`).
8. **Rollback provado** (se houver migration): devolve função/índice/ACL ao
   estado atual; declara o que se perde (linhas entregues **não** voltam).
9. **Gate final** (`do $gate$`, se houver migration) falha se faltar: o índice
   de *claim*, o corte, e
   `has_function_privilege('anon', <função nova>, 'EXECUTE') = false`.
10. **Observabilidade:** uma linha entregue (e uma falhada) ficam visíveis como
    evento em `workflow_execution_logs` (ou na superfície equivalente da forma
    escolhida) — prova do rastro, não da intenção.

**Testes obrigatórios:** (inclui isolamento entre clientes)

- `git diff --check`;
- `npx tsc --noEmit` e `node --test lib/*.test.mjs` (Node ≥ 22.18) — só se o
  front mudar (**não deve**); se não rodar no ambiente do Executor, **registrar
  no PR em vez de pular em silêncio**;
- `scripts/db-prova.py --dry-run` (leitura pura) com a saída colada no relatório
  **antes** de qualquer escrita; ou `scripts/staging-run.py` para provar em
  **staging** (`nfratueiutxnypbxfnmi`) o que for de banco;
- **prova do corte** (critério 2): medir o estado das 512 `pending` + 43
  `failed` antes e depois — delta 0. **Obrigatório.**
- **prova de idempotência/claim** (critério 3): duas execuções concorrentes ⇒ 1
  envio;
- **teste de isolamento entre clientes** (critério 7);
- prova de rollback (critério 8), se houver migration;
- **plano de teste do lado n8n — PENDENTE:** o n8n **não tem staging** (regra do
  AGENTS.md). Definir com o Coordenador como provar o `1.2`/`1.3` sem disparar
  envio real (ex.: `IF Should Send` falso / destino de teste), **antes** de
  tocar o workflow de produção.

**Riscos conhecidos:**

- **Irreversível acima de tudo:** evento aceito pela CAPI/Data Manager **não
  volta**. Toda a valiosa do projeto (ADR-0017) existe para não repetir esse
  erro. O consumidor é o ponto exato onde ele pode acontecer — varredura sem
  corte, claim mal feito, ou reprocessar linhas de GHL já entregues.
- **Varrer por `status='pending'` sem escopo envia as 512 antigas.** É o risco
  número 1 do bloco. O corte é requisito, não otimização.
- **n8n de produção sem staging:** o teste do lado n8n é o maior custo oculto e
  a maior incerteza da estimativa (linha "Teste sem n8n de staging" = M–L).
- **Não há acesso n8n hoje:** reaproveitar `1.2`/`1.3` "no escuro" é caminho
  para erro silencioso no dispatch (mesmo risco que a IMP-218 sinalizou).
  Confirmar via Coordenador ou escalar.
- **Dependência nova:** se o consumidor for no banco, `pg_net`/HTTP é serviço
  novo — **proibido sem "sim" do Caio** (AGENTS.md regra 5). Empurra para a
  forma n8n.
- **Duplicação com o caminho GHL:** o caminho do `1.1` continua existindo; um
  consumidor que varrer sem escopo pode reprocessar linhas de GHL. Separar por
  origem/corte e testar.
- **Contradição de premissa (decisão 13):** o dump local mostra `NOT NULL` e a
  produção mostra `NULL`-ável. Se o Executor se basear no arquivo errado,
  escreve um plano sobre premissa falsa. **Produção manda; o Head reconcilia.**
- **Fila que vira registro de novo:** se o consumidor for só "chamado pelo
  `1.1`", continua sem varredura e o CRM não entrega. O ponto é **varredura**.
- Detalhes herdados que já custaram caro: `set constraints all immediate` após
  `ALTER TABLE` no mesmo `UPDATE`; `psql` não substitui variável dentro de `$$`;
  função escalar `setof uuid` sempre com alias (`from f() as m` — ADR-0020);
  recriar função devolve privilégios ao `anon` sem o `revoke`.

**Entrega:** PR draft, relatório em 3 blocos (verificado rodando com o número
medido / correto por construção não testado / não bateu e por quê), e — se
houver banco — migration + rollback + `APLICAR-*.sql` + gate + aceite + teste de
isolamento entre clientes. O PR registra, em uma linha cada: a forma escolhida
(n8n vs banco), o corte, a política de retry e que **nada é enviado até a flag
ligar (IMP-219)**.

**Escalar ao Head se:**

- o desenho exigir **coluna/objeto novo em `conversion_outbox`** (tabela
  compartilhada com o n8n) — **sempre** escala;
- o consumidor tiver de ser no **banco com HTTP** (dependência nova) — sem "sim"
  do Caio, **parar**;
- **não for possível confirmar como o `1.2`/`1.3` lê a linha e mapeia status**
  (decisão 14) — criar consumidor "no escuro" é o caminho para erro silencioso;
- o corte não puder ser definido sem risco de pegar linha antiga;
- a produção divergir do dump (caso da decisão 13) e a premissa mudar o desenho;
- dúvida de autorização (tocar workflow n8n de produção, escrita em banco, prova
  transacional) — **parar** e perguntar, nunca improvisar;
- duas tentativas falhas na mesma etapa.

**Precisa do Caio/Coordenador ANTES de implementar:**

1. **Confirmação da forma (opção (c))** e **onde mora o consumidor**: (i) novo
   workflow n8n agendado; (ii) extensão do `1.1`/`1.2`/`1.3`; ou (iii) banco com
   `pg_cron`+`pg_net` (dependência nova, exige "sim"). A recomendação deste
   documento é **(c) com n8n agendado**.
2. **Decisão 10 — o corte:** qual predicado/data impede o envio das 512
   `pending` + 43 `failed` antigas.
3. **Decisão 11 — política de retry/DLQ** e **quem observa `failed`**.
4. **Decisão 12 — mecanismo de *claim*** (anti-envio-duplo).
5. **Decisão 14 — acesso aos JSONs do `1.2`/`1.3`** (ou autorização para o Head
   confirmar por nós) para reaproveitar a lógica de envio.
6. **Decisão 13 — reconciliação** das premissas `NOT NULL` (IMP-218, decisões
   9/10) contra a produção, que hoje as mostra `NULL`-áveis.
7. **Autorização explícita para tocar workflow n8n de produção** (o AGENTS.md
   proíbe tocar n8n sem tarefa explícita; esta tarefa é a tarefa, mas **qual**
   workflow e se pode ser um novo é decisão do Caio).
8. **Autorização de escrita/prova transacional em produção**, se a prova não
   puder ser feita só em staging — e ciência de que **o envio real é
   irreversível** (o Caio decide se/quando o piloto dispara).
9. **Ordem no bloco:** a IMP-215 depende do que a IMP-217 e a IMP-218 deixarem
   (valor/moeda no `ganho`; matriz evento × plataforma). Confirmar a sequência
   (sugerida pela ROADMAP: 217 → 218 antes de 215) para não construir o
   consumidor sobre um payload que vai mudar.
