# IMP-218 — Matriz evento × plataforma: Meta e Google na ponte do CRM

**Tarefa de BANCO: executor---plataforma (padrão) e revisão do Head antes de
qualquer aplicação.** Este arquivo foi escrito por `executor-plataforma-2`
(documentação, barato) e **não implementa SQL algum**.

REFS lidas para escrever isto: `docs/ROADMAP.md` §5 ("**Só cria job Meta;
Google nunca recebe**"; "**Meta é o primeiro canário.** O Google não pode sumir
em silêncio: antes de encerrar a etapa, a IMP-218 precisa de decisão explícita —
entra junto ou é adiada com motivo escrito"), `docs/adr/ADR-0017-...` (item 3 do
contexto e a ordem de correção, #6), `docs/BANCO_DE_DADOS.md` §8 (matriz de
dispatch) e §8.4, `docs/N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md` §3/§4/§5
(fluxo `1.1` → `IF Should Dispatch Meta → 1.2` / `IF Should Dispatch Google →
1.3` e a tabela de roteamento), `HANDOFF-ImpulsHub-2026-09-21.md` §1 ("o
cliente novo usa Google Ads ⇒ o Google entra junto na conversão (IMP-218)"),
`AGENTS.md`, `docs/tarefas/IMP-230.md` (estilo) e a definição viva da ponte
depois de IMP-216 (`20260930000000`) e IMP-230 (`20261001000000`).

> **Nada aqui inventa requisito.** Onde não há decisão tomada, está escrito
> **PENDENTE** e listado no bloco "Precisa do Caio/Coordenador antes de
> implementar".

---

**Objetivo (1 frase):** a ponte do CRM passa a criar **uma linha de
`public.conversion_outbox` por plataforma elegível** segundo a matriz vigente
de `event_code` × plataforma (**Meta e Google**), em vez de criar só
`platform='meta'` — deixando o Google de existir para o cliente que não tem
GHL.

**Decisões já tomadas (não reabrir):**

1. **A matriz vigente é a da §5 do `N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md` e
   da §8 do `BANCO_DE_DADOS.md`** (as duas concordam):

   | `event_code` | Meta | Google | Elegível |
   |---|---|---|---|
   | `lead` | `Lead` (ou `LeadSubmitted` via rota WhatsApp BM) | `Lead` | Sim |
   | `agendado` | `Schedule` (ou `QualifiedLead` via rota WhatsApp BM) | `Agendou` | Sim |
   | `ganho` | `Purchase` | `Compra` | Sim, **com valor/moeda** (depende do IMP-217) |
   | `primeira_conversa` | — | — | **Não** |
   | `perdido` | — | — | **Não** |

2. **Google entra junto, não é adiado** — decisão de 21/09 (handoff §1: o
   cliente novo usa Google Ads). **Mas a ROADMAP exige que a decisão esteja
   escrita**: o Executor registra no PR, com link para esta tarefa e para a
   resposta do Caio, e **não implementa a linha Google sem essa confirmação**.
3. **A configuração Google já existe em `public.clients_base`** e é a fonte:
   `enable_google_tracking`, `google_ads_customer_id`,
   `google_manager_customer_id`, `google_conversion_action_lead`,
   `google_conversion_action_agendado`, `google_conversion_action_ganho`,
   `google_ads_dispatch_method` (default `data_manager_api`),
   `google_data_manager_destination_id`. **Nada de credencial nova, nada de
   tabela de configuração nova.**
4. **A ponte só cria a linha.** Quem entrega é o n8n `1.2`/`1.3`. **Esta tarefa
   não toca nenhum workflow n8n** (`AGENTS.md`: tocar neles sem tarefa
   explícita é fora de escopo). E, hoje, **ninguém consome linha `pending`
   criada fora da execução do `1.1`** — o consumidor é o **IMP-215**. Sem o
   IMP-215, esta tarefa **cria a linha e nada sai**; isso é esperado e precisa
   estar escrito no PR para ninguém achar que a conversão "ligou".
5. **Nada aqui liga flag.** `crm_emits_conversions` continua `false` nos 6
   registros. A matriz é preparação; a ativação é IMP-219 (runbook) + decisão
   do Caio.
6. **Uma linha por (evento normalizado, plataforma).** Idempotência explícita:
   repetir o movimento **não** cria segunda linha para a mesma plataforma.
7. **A matriz vive no banco, num lugar só.** A IMP-216 criou `crm.event_map`
   (6 linhas, `event_code`/`stage_code`/`event_name`/`funnel_step`). A tradução
   plataforma × evento deve ser derivada daí (coluna nova por linha ou tabela
   irmã — **escolha da implementação, registrada no PR**); **não** espalhar
   `case` duplicado na função e no doc.
8. **A rota Meta não muda:** `route = 'whatsapp_bm'` quando há `ctwa_clid` ou
   `conversion_source in ('FB_Ads','FB_Post')`, senão `'standard'` — igual ao
   que está em produção desde a IMP-216.
9. **PENDENTE — `conversion_outbox.ghl_location_id` é `NOT NULL`** no schema
   observado. Cliente sem GHL (ImpulsHub, o primeiro cliente real do sistema
   novo) **não consegue ter linha na outbox** com a coluna como está. Relaxar
   para `NULL` é mudança em tabela **compartilhada com o n8n `1.2`/`1.3`** e
   exige o Head. **Não decidir sozinho.**
10. **PENDENTE — colunas `NOT NULL` de linha Meta em linha Google:**
    `conversion_outbox.route` e `conversion_outbox.meta_event_name` são
    `NOT NULL`. Numa linha `platform='google_ads'`, preencher
    `meta_event_name` com o nome do evento **do Google** é semanticamente
    errado, e relaxar as colunas é mudança na tabela compartilhada. **Escolha
    explícita e registrada no PR**, com uma das duas opções (preencher com o
    nome do Google + comentário, ou relaxar nulabilidade com aval do Head).
11. **PENDENTE — cliente com Google ligado mas sem
    `google_conversion_action_*` preenchido:** criar a linha assim mesmo (e
    deixar o `1.3` decidir) ou **não criar** (evita fila com linha que não pode
    ser enviada). Recomendação desta tarefa: **não criar** e registrar a decisão
    no PR — **confirmar com o Caio/Coordenador antes de implementar.**
12. **PENDENTE — valor do literal de `platform`:** as linhas existentes de
    Google na outbox (326 `pending` desde 24/08) usam **o literal que o `1.1`
    escreve**; o Executor **lê as linhas existentes** para descobrir o valor
    vigente (`'google_ads'` ou outro) e **não inventa**.

**Escopo (o que fazer):**

- alterar `crm.emit_opportunity_stage_event` para montar **os jobs por
  plataforma** a partir da matriz (hoje: um único `insert` com
  `platform='meta'`), mantendo:
  - a escrita em `events_raw`/`events_normalized` **exatamente** como está
    (esta tarefa não muda o dashboard);
  - o gate de flag de conversão (`crm_emits_conversions`) — **nenhuma** linha de
    outbox quando `false`;
  - a rota Meta (decisão 8) e o dedupe de reentrada;
- preencher, por plataforma, `platform`, `platform_event_name`,
  `platform_conversion_action` (Google: a conversion action configurada para a
  etapa), `platform_account_id`/`platform_manager_account_id` (Google:
  `google_ads_customer_id`/`google_manager_customer_id`) e `payload` próprio —
  o payload Google **não** é o payload Meta com outro nome;
- definir a matriz no banco (decisão 7) e usá-la na função;
- garantir a idempotência por (evento, plataforma) (decisão 6) — se precisar de
  índice único novo, ele entra no gate;
- rollback que restaura **o estado atual, ACL incluídas**, e declara o que se
  perde (linhas de `conversion_outbox`/`events_normalized` de `impuls_crm`
  gravadas no intervalo permanecem; eventos já aceitos por plataforma não
  voltam);
- `APLICAR-imp218.sql` autocontido (sem `\ir`), com registro no ledger
  `supabase_migrations.schema_migrations`; **gate final** (`do $gate$`); aceite
  transacional terminando em `ROLLBACK`; **teste de isolamento entre clientes**.

**Fora de escopo (o que NÃO fazer):**

- valor/moeda e motivo no ganho/perdido (**IMP-217**) — esta tarefa assume o
  que o 217 deixar; se o 217 não estiver aplicado, o `ganho` continua saindo
  sem valor e isso se declara no PR;
- consumidor da `conversion_outbox` (**IMP-215**) e runbook de ativação
  (**IMP-219**);
- ligar qualquer flag (`crm_emits_conversions`/`crm_feeds_dashboard`);
- tocar workflows n8n `1.1`/`1.2`/`1.3` (ver decisão 4);
- enviar de fato para Meta CAPI ou Google Data Manager (isso é o n8n);
- reescrever histórico de `events_normalized` ou as 512 linhas `pending` de
  agosto/setembro (**nunca enviar** — ADR-0017);
- front, parser do Stevo, workflows de mídia;
- aplicar em produção (só o Caio aplica).

**Base em produção a ler antes (objetos, funções, políticas) — SOMENTE LEITURA:**

Leitura pura (`SELECT`) antes de escrever SQL. **A definição viva manda.**

- `pg_get_functiondef('crm.emit_opportunity_stage_event'::regprocedure)` — a
  versão viva (pós-216/230) é a base da recriação.
- `information_schema.columns` de `public.conversion_outbox` — **conferir
  nulabilidade** de `ghl_location_id`, `route`, `meta_event_name`, `platform`,
  `platform_event_name`, `platform_conversion_action`, `platform_account_id`,
  `platform_manager_account_id`, `dispatch_method`, `destination_config`,
  `payload`; e **os valores distintos de `platform` já gravados** (decisão 12).
- `information_schema.columns` de `public.clients_base` — as colunas Google da
  decisão 3 (existência e tipo) e `crm_emits_conversions`.
- `crm.event_map` inteira (6 linhas) e `crm.global_pipeline_stages`.
- `crm.opportunities` — as colunas de origem (`ctwa_clid`,
  `conversion_source`, `meta_ad_id`, `gclid`, `gbraid`, `wbraid`, UTM), que já
  existem desde a IMP-230.
- ACL/`pg_policies` de `conversion_outbox`, `events_normalized`, `events_raw`
  para `anon`, `authenticated`, `service_role`;
  `has_function_privilege('anon', 'crm.emit_opportunity_stage_event()',
  'EXECUTE')` tem de ser `false`.
- **Como o `1.3` lê a linha** (quais colunas ele usa para montar a request
  Google) — leitura de documentação **e**, se o Coordenador tiver acesso ao
  workflow, confirmação direta. Se não der para confirmar, **escalar antes de
  codificar** (ver "Escalar ao Head se").
- Contagens de partida como `postgres` (sem número fixo no script):
  `conversion_outbox` por `platform` e por `client_id`, e `events_normalized`
  com `source_system='impuls_crm'` por `client_id`, para Royal, Central,
  QuickClean e ImpulsHub.

**Arquivos previstos:**

- `supabase/migrations/20261004000000_imp218_event_platform_matrix.sql`
- `supabase/migrations/20261004000000_imp218_event_platform_matrix.rollback.sql`
- `supabase/acceptance/APLICAR-imp218.sql`
- `supabase/acceptance/imp218-acceptance.sql`
- `supabase/acceptance/imp218-isolation.sql`

O timestamp segue a sequência depois de `20261003000000` (IMP-217). Nomes de
arquivo são a única coisa maleável aqui.

**Critérios de aceite (verificáveis, com número):**

1. **Um evento elegível cria uma linha por plataforma elegível.** No cliente de
   teste (ImpulsHub, fixture do staging/produção de teste), mover um card para
   `atendimento`/`agendado` cria **exatamente 2** linhas novas na outbox
   para aquele evento normalizado — **1** com `platform='meta'` e **1** com o
   literal Google vigente — e **0** para `primeira_conversa` e `perdido`.
2. **Os nomes de evento conferem com a matriz:** para o mesmo movimento, o
   conjunto de `platform_event_name` por plataforma é exatamente o da decisão 1
   (`lead` → Meta `Lead`/`LeadSubmitted` conforme a rota e Google `Lead`;
   `agendado` → Meta `Schedule`/`QualifiedLead` e Google `Agendou`; `ganho` →
   Meta `Purchase` e Google `Compra`). Medir a lista, não conferir "de olho".
3. **Idempotência:** repetir o mesmo movimento ⇒ **delta 0** por plataforma
   (nenhuma segunda linha para o mesmo `normalized_event_id` + plataforma).
4. **Cliente com Google desligado** (`enable_google_tracking = false`, ou sem
   `google_conversion_action_*` para a etapa, conforme a decisão 11): **0**
   linhas Google e **1** linha Meta para o evento elegível — o número medido é
   o que a decisão 11 determinar, declarado no PR.
5. **Nenhuma linha quando a flag de conversão está `false`:** card movido em
   cliente com `crm_emits_conversions = false` ⇒ **delta 0** na outbox e
   **delta ≥ 0** apenas em `events_normalized` conforme a flag de dashboard.
6. **Variação ZERO para Royal, Central e QuickClean** em `events_normalized` e
   `conversion_outbox`: contagem por `client_id` antes e depois, diferença
   **exatamente 0** nas duas tabelas.
7. **Isolamento entre clientes:** o modelo de
   `supabase/acceptance/imp213-isolation.sql` (atendente da Central
   `bb04435c-fabb-4ba8-b5b5-e0175d9ca17d`, gestor Royal
   `7c3296f4-13c7-42d1-89eb-72aecec905ba`) devolve **só** o `client_id` do
   próprio usuário em todo objeto tocado; RPC chamada com o id de outro cliente
   devolve **0 linhas** ou `42501`.
8. **Rollback provado:** devolve função, triggers, matriz, índices e ACL ao
   estado atual; declara que linhas de outbox do intervalo permanecem.
9. **Gate final** (`do $gate$`) falha a migration se faltar: a matriz completa
   (toda etapa com plataforma elegível definida), o índice de idempotência, o
   `revoke` de `anon` e
   `has_function_privilege('anon','crm.emit_opportunity_stage_event()',
   'EXECUTE') = false`.
10. **ACL:** `revoke all ... from public, anon` **depois de todo `CREATE`** de
    função/view; `grant` explícito só ao que precisa.

**Testes obrigatórios:** (inclui isolamento entre clientes)

- `npx tsc --noEmit` e `node --test lib/*.test.mjs` (Node ≥ 22.18) — a mudança
  é de banco e o front **não** deve mudar; se não rodar no ambiente do
  Executor, **registrar no PR em vez de pular em silêncio**;
- `git diff --check`;
- `scripts/db-prova.py --dry-run` (leitura pura, sem escrita) com a saída colada
  no relatório, **antes** de qualquer escrita em banco; ou
  `scripts/staging-run.py` para provar em **staging** (projeto
  `nfratueiutxnypbxfnmi`) antes de pedir revisão;
- aceite transacional terminando em `ROLLBACK` (roda o Coordenador ou o Head,
  com autorização escrita do Caio para **aquela** execução);
- **teste de isolamento entre clientes** (critério 7);
- prova de rollback (critério 8);
- medição de **variação zero** para os três clientes com GHL (critério 6).

**Riscos conhecidos:**

- **Enviar conversão duas vezes é irreversível** — evento aceito pela CAPI/Data
  Manager não volta. Um `insert` por plataforma mal feito (loop duplicado,
  falta de idempotência) é exatamente o erro que a ADR-0017 protegeu. Teste de
  reentrada explícito.
- **Linha Google sem `platform_conversion_action`** vira lixo na fila ou erro
  no `1.3` — daí a decisão 11.
- **`conversion_outbox.ghl_location_id` `NOT NULL`** (decisão 9): sem resolver
  isso, o cliente sem GHL — o primeiro cliente real — não emite conversão. É o
  ponto em que esta tarefa encosta no objetivo do projeto; **decisão do Caio.**
- **`route`/`meta_event_name` `NOT NULL`** (decisão 10): linha Google exige
  escolha semântica ou mudança em tabela compartilhada com o n8n.
- **Divergência silenciosa entre a matriz do banco e a do n8n:** a verdade
  hoje está em `docs/N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md` §5 e no
  `BANCO_DE_DADOS.md` §8. Se o n8n mudar, o banco continua criando linha com o
  nome antigo. Registrar como limitação conhecida no PR (esta tarefa não cria
  vigia).
- **Sem IMP-215 nada sai da fila** — risco de leitura errada do resultado
  ("liguei e não chegou"). O PR precisa dizer isso em uma linha.
- Detalhes herdados que já custaram caro: `ALTER TABLE` depois de `UPDATE` na
  mesma transação exige `set constraints all immediate`; `psql` não substitui
  variável dentro de `$$` (arrays inline no aceite); função escalar `setof
  uuid` **sempre com alias** (`from f() as m` — ADR-0020); recriar função
  devolve privilégios ao `anon` sem o `revoke`.

**Entrega:** PR draft, relatório em 3 blocos (verificado rodando com o número
medido / correto por construção não testado / não bateu e por quê),
migration + rollback + `APLICAR-imp218.sql` + gate + aceite + teste de
isolamento entre clientes. O PR registra, em uma linha cada: a decisão sobre o
Google (item 2), as decisões 9 a 12, e que **nada é enviado** até o IMP-215.

**Escalar ao Head se:**

- a implementação exigir **mudança em `conversion_outbox`** (nulabilidade de
  `ghl_location_id`, `route`, `meta_event_name` ou coluna nova) — tabela
  compartilhada com o n8n; **sempre** escala;
- não for possível confirmar **como o `1.3` lê a linha** (quais colunas usa) —
  criar linha "no escuro" é o caminho para erro silencioso no dispatch;
- a matriz do doc divergir do que o n8n realmente faz;
- a definição viva de `crm.emit_opportunity_stage_event` divergir do que a
  IMP-216/230 deixou;
- o IMP-217 não estiver aplicado e a matriz do `ganho` ficar sem valor/moeda;
- dúvida de autorização (escrita em produção, prova transacional, ligar flag) —
  **parar** e perguntar, nunca improvisar;
- duas tentativas falhas na mesma etapa.

**Precisa do Caio/Coordenador ANTES de implementar:**

1. **Confirmação escrita de que o Google entra junto** na conversão pelo CRM
   (é o que a ROADMAP §5 exige: "entra junto ou é adiada com motivo escrito").
2. **Decisão 9** — o que fazer com `conversion_outbox.ghl_location_id`
   `NOT NULL` para cliente sem GHL: relaxar a nulabilidade (mudança em tabela
   compartilhada, com o Head) ou aceitar que cliente sem GHL ainda não emite
   conversão nesta tarefa.
3. **Decisão 10** — qual conteúdo entra em `route`/`meta_event_name` numa linha
   Google, ou se essas colunas serão relaxadas.
4. **Decisão 11** — cliente com Google ligado e sem conversion action: cria
   linha ou não cria.
5. **Confirmação da ordem** — esta tarefa toca a **mesma função** da IMP-217
   (`crm.emit_opportunity_stage_event`). As duas **não podem** rodar em
   paralelo no mesmo worktree/tabela: definir a ordem (217 → 218, como a
   ROADMAP sugere) e, se forem dois Executores, worktrees distintos e sem
   sobreposição de arquivos.
6. **Autorização da prova transacional em produção** (uma execução,
   `begin…rollback`), se a prova não puder ser feita só em staging.