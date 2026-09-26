# IMP-219 — Runbook de ativação canário

**Tarefa de DOCUMENTAÇÃO/PROCESSO, não de banco.** Este arquivo foi escrito por
um agente de plataforma e **não implementa SQL, migration nem workflow n8n
algum**. O entregável desta tarefa é o próprio runbook
(`docs/RUNBOOK-IMP-219-ATIVACAO-CANARIO.md`), não código.

REFS lidas para escrever isto: `AGENTS.md` (regra 5 — número que comunica algo
falso é pior que número nenhum; regra 8 — produção é leitura por padrão),
`docs/ROADMAP.md` §5 (Conversões e tracking — "pronto quando: mover um card na
Impuls faz o evento aparecer no Gerenciador de Eventos da Meta, e o runbook de
ativação (IMP-219) existe"), `docs/adr/ADR-0017-entregar-crm-com-conversoes-desligadas.md`
(a flag nasce `false`; ligar depois sem replay produz funil que começa no
meio — decisão explicitamente adiada para esta tarefa), `docs/adr/ADR-0026-consumidor-conversion-outbox.md`
(IMP-215, contrato de claim/dispatch, estado do consumidor), `docs/task-files/TASK-IMP-215.md`,
`TASK-IMP-217.md`, `TASK-IMP-218.md` (estilo e decisões PENDENTE herdadas),
`docs/IMP-215-CLAIM-DISPATCH-CONTRACT.md`, `docs/N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md`
§3/§4/§5, `docs/STATUS-OPERACIONAL.md` (estado real do consumidor: ciclo 17057
com `candidate_count=0`, nunca exercitado ponta a ponta) e leitura direta em
produção (`mtxnwtqwfagjzkvgsncs`, somente `SELECT`, 25/09/2026) de
`clients_base`, `conversion_outbox`, `events_normalized` e
`workflow_execution_logs`.

> **Nada aqui inventa requisito.** Onde não há decisão tomada, está escrito
> **PENDENTE** e listado no bloco "Precisa do Caio antes de aplicar".

---

**Objetivo (1 frase):** existir um runbook executável, seguível por uma pessoa
não-desenvolvedora com apoio de um agente/DBA, que descreva com segurança como
ligar `clients_base.crm_emits_conversions` para um cliente — comando auditado,
checagem de GHL parado, decisão de replay/ignorar, protocolo de canário,
critérios de abortar e reconciliação pós-canário.

**Decisões já tomadas (não reabrir):**

1. **A flag nasce `false` para todo cliente** (ADR-0017) e isso está certo —
   esta tarefa não muda esse default nem liga a flag para ninguém novo.
2. **O mecanismo de auditoria reaproveita `public.workflow_execution_logs`.**
   Confirmado por leitura de schema que a tabela já existe, tem `client_id`,
   `metadata jsonb` e é lida pelas views de observabilidade
   (`v_workflow_health_daily`). `clients_base` não tem coluna de
   quem/quando mudou uma flag, e criar uma não foi necessário: a tabela
   genérica já serve. **Nenhuma migration de schema nesta tarefa.**
3. **Nenhuma flag foi ligada, desligada ou alterada por esta tarefa.** O
   estado de `clients_base.crm_emits_conversions = true` para a Impuls já
   existia antes desta tarefa começar (25/09/2026 20:54 UTC) e foi
   confirmado como autorizado pelo Caio — esta tarefa **documenta** esse
   estado como ponto de partida real, não o cria nem o reverte.
4. **A política de replay vs. ignorar do histórico acumulado não é decidida
   por esta tarefa.** O runbook apresenta as duas opções com prós/contras e
   registra a pergunta explícita ao Caio, por cliente — nunca escolhe
   sozinho (ver seção 4 do runbook).
5. **Regra que não muda:** nenhum cliente com GHL ativo tem a flag ligada. O
   runbook exige, antes de qualquer ativação futura, uma checagem de leitura
   (`events_normalized` com `source_system='ghl'` nos últimos 7 dias = 0)
   mais confirmação operacional fora do banco.
6. **As 2 linhas `failed` da Impuls (24/09/2026, evento `agendado`,
   `platform` meta e google_ads, erro
   `n8n_expression_parse_failed_before_http; no_external_request_made`) são
   documentadas como achado técnico a considerar, não como bloqueio nem como
   erro resolvido.** O commit `3a51e80` ("fix: harden IMP-215 n8n claim
   dispatch contract") endurece o mesmo tipo de bug de sintaxe n8n, mas esta
   tarefa **não confirma nem afirma** que ele já resolve essas 2 linhas
   específicas — isso é PENDENTE, listado explicitamente no runbook e nesta
   task file.
7. **O consumidor do IMP-215 nunca foi exercitado ponta a ponta com
   candidato real.** A única execução observada (`17057`, lida em
   `STATUS-OPERACIONAL.md`) teve `candidate_count=0`. O runbook documenta
   isso como lacuna de evidência conhecida, não a esconde nem finge que o
   consumidor já está provado.

**PENDENTE — decisão do Caio, listada no runbook, não respondida aqui:**

1. Replay vs. ignorar do histórico acumulado, por cliente (opções A/B com
   prós/contras no runbook §4).
2. Reprocessar ou não as 2 linhas `failed` conhecidas da Impuls.
3. Duração exata da janela do canário (o runbook propõe 4-8h úteis).
4. Quem é a pessoa de referência para checar o Gerenciador de Eventos da Meta
   durante a janela.
5. Qual é o próximo cliente candidato ao canário depois da Impuls, e se ele
   já tem o GHL comprovadamente parado.

**Escopo (o que foi feito):**

- Ler toda a base indicada (`AGENTS.md`, `ROADMAP.md` §5, ADR-0017, ADR-0026,
  TASK-IMP-215/217/218, os quatro documentos `IMP-215-*.md`,
  `N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md`).
- Confirmar por `SELECT` em produção (`mtxnwtqwfagjzkvgsncs`): schema de
  `clients_base` (sem coluna de auditoria de flag), schema de
  `conversion_outbox` (`ghl_location_id`/`route`/`meta_event_name`
  `NULL`-áveis, confirma o que a IMP-215 já tinha reconciliado), schema de
  `workflow_execution_logs` (serve para auditoria sem migration), estado
  atual de `clients_base` para todos os clientes, as 2 linhas `failed` da
  Impuls, e contagem de eventos GHL por cliente nos últimos 7 dias (Royal
  436, Central 345, QuickClean 210, Impuls 0).
- Escrever `docs/RUNBOOK-IMP-219-ATIVACAO-CANARIO.md` cobrindo os 8 blocos
  pedidos: pré-condições, comando de ativação auditado, checagem de GHL,
  decisão de replay (como PENDENTE), protocolo de canário, critérios de
  abortar, reconciliação pós-canário, checklist de expansão.
- Escrever este arquivo (`TASK-IMP-219.md`).
- Abrir PR draft contra `main`.

**Fora de escopo (o que NÃO foi feito, propositalmente):**

- Ligar, desligar ou alterar `crm_emits_conversions` para qualquer cliente —
  a flag da Impuls já estava no estado atual antes desta tarefa e permanece
  inalterada por ela.
- Criar migration, tabela ou coluna nova — confirmado que
  `workflow_execution_logs` já serve.
- Decidir a política de replay/ignorar — fica PENDENTE, é decisão do Caio.
- Reprocessar, reenviar ou corrigir as 2 linhas `failed` da Impuls.
- Tocar qualquer workflow n8n (`1.1`/`1.2`/`1.3`/consumidor do IMP-215).
- Qualquer escrita em produção além do próprio commit de documentação no
  repositório (todas as leituras de banco foram `SELECT`).
- Fazer merge ou push para `main`.

**Base em produção lida antes de escrever (SOMENTE LEITURA):**

Leitura pura (`SELECT`) em `mtxnwtqwfagjzkvgsncs`, 25/09/2026:

- `information_schema.columns` de `public.clients_base` (94 colunas; sem
  coluna de auditoria de mudança de flag).
- `information_schema.columns` de `public.workflow_execution_logs` (confirma
  `client_id`, `metadata jsonb`, `stages jsonb`, `status`, `stage` — serve
  para o registro de auditoria proposto sem migration).
- `information_schema.columns` de `public.internal_onboarding_audit`
  (existe, mas é presa a `onboarding_id` — não serve para este caso, por
  isso não foi reaproveitada).
- `information_schema.columns` de `public.conversion_outbox` para
  `ghl_location_id`/`route`/`meta_event_name`/`platform`/`normalized_event_id`
  — confirma `NULL`-áveis (reconcilia o que a IMP-215 já tinha medido em
  22/09; não é achado novo desta tarefa).
- `public.clients_base` completa (10 registros): só a Impuls tem
  `crm_emits_conversions = true`; todos os demais `false`.
- `public.conversion_outbox` join `events_normalized` para
  `client_id = '3ec294db-...'`: 17 linhas totais, incluindo as 2 `failed`
  documentadas na seção 0 do runbook.
- `public.events_normalized` agregada por `client_id`/`source_system` com
  contagem de eventos nos últimos 7 dias: confirma 0 eventos GHL para a
  Impuls (consistente com ela já não depender do GHL) e volume real e vivo
  em Royal/Central/QuickClean via GHL.

**Arquivos produzidos:**

- `docs/RUNBOOK-IMP-219-ATIVACAO-CANARIO.md`
- `docs/task-files/TASK-IMP-219.md` (este arquivo)

Nenhum arquivo de migration, rollback, `APLICAR-*.sql` ou workflow n8n é
produzido por esta tarefa — não há schema novo nem código executável.

**Critérios de aceite (verificáveis):**

1. O runbook cobre, com passo a passo executável, os 8 itens pedidos:
   pré-condições, comando de ativação auditado (com SQL literal), checagem
   de GHL (com SQL literal), decisão de replay documentada como PENDENTE com
   prós/contras e sem escolha, protocolo de canário com o que conferir no
   Gerenciador de Eventos, critérios de abortar, reconciliação pós-canário, e
   checklist de expansão.
2. O comando de ativação proposto usa uma tabela **já existente**
   (`workflow_execution_logs`), confirmado por leitura de schema antes de
   propor — não uma tabela nova sem necessidade comprovada.
3. O estado atual da Impuls (`crm_emits_conversions=true` desde 25/09/2026
   20:54 UTC, autorizado pelo Caio) está documentado como fato de partida,
   não como incidente nem como bloqueio, e o runbook **não propõe revertê-lo**.
4. As 2 linhas `failed` da Impuls estão documentadas com o erro exato
   (`n8n_expression_parse_failed_before_http; no_external_request_made`) e o
   commit candidato a resolvê-las (`3a51e80`) citado como **não confirmado**,
   nunca como "resolvido".
5. Nenhuma flag foi alterada em produção durante a execução desta tarefa —
   verificável comparando o `updated_at` de `clients_base` para a Impuls
   antes e depois (deve continuar `2026-09-25 20:54:37.408153+00`).
6. Nenhuma migration, arquivo SQL de schema ou workflow n8n foi criado.
7. PR aberto como **draft** contra `main`, nunca mergeado nem com push para
   `main`.

**Riscos conhecidos:**

- **O maior risco desta tarefa é decidir por conta própria** algo que o card
  original explicitamente deixa para o Caio (replay/ignorar). O runbook foi
  escrito para apresentar opções, nunca escolher.
- **Confundir o estado atual da Impuls com um bug a corrigir.** O card e o
  contexto de negócio deixam claro que é autorizado; o runbook trata como
  ponto de partida, não como algo a reverter — reverter sem instrução seria
  uma escrita em produção não autorizada.
- **Tratar as 2 linhas `failed` como resolvidas sem prova.** A tentação é
  citar o commit `3a51e80` e dar o assunto como encerrado; o runbook e esta
  task file marcam explicitamente como PENDENTE de confirmação.
- **O consumidor do IMP-215 nunca foi provado com candidato real** (ciclo
  vazio, `candidate_count=0`). Isso significa que o canário do próximo
  cliente pode ser, na prática, o primeiro teste real ponta a ponta do
  consumidor — o runbook declara isso explicitamente em vez de presumir que
  o consumidor já está validado.
- **Auditoria em `workflow_execution_logs` é convenção, não constraint.**
  Nada no banco impede alguém de rodar `update clients_base set
  crm_emits_conversions = true` sem passar pelo comando auditado do runbook.
  O controle é de processo (só quem segue o runbook, com autorização do
  Caio), não de schema. Se isso se mostrar insuficiente, uma trigger de
  auditoria seria o próximo passo — fora do escopo desta tarefa por não ser
  comprovadamente necessária ainda.

**Escalar ao Head se:**

- alguém propuser ligar a flag para um cliente com GHL ainda ativo — nunca
  seguir adiante, é a regra que não se quebra;
- a decisão de replay for tomada sem registro explícito do Caio;
- o mecanismo de auditoria proposto (`workflow_execution_logs`) se mostrar
  insuficiente na prática (por exemplo, precisar de trava a nível de banco,
  não só de processo) — decidir se cria trigger/constraint é mudança de
  superfície e exige revisão;
- duas tentativas falhas na mesma etapa.

**Precisa do Caio antes de aplicar (ou seja, antes de qualquer próxima
ativação usando este runbook):**

1. Replay vs. ignorar, por cliente — o runbook não decide.
2. Reprocessar ou não as 2 linhas `failed` da Impuls.
3. Confirmar a janela do canário (4-8h úteis, proposta do runbook).
4. Indicar quem confere o Gerenciador de Eventos da Meta durante a janela.
5. Indicar o próximo cliente candidato ao canário e confirmar que o GHL dele
   já está parado.

**Entrega:** PR draft com os dois arquivos markdown, relatório separando o
que foi **verificado lendo produção** (com número), o que é **proposta ainda
não decidida**, e o que ficou **PENDENTE de decisão do Caio**. Nenhuma
escrita em produção além das leituras `SELECT` usadas para confirmar fatos.
