# IMP-217 — Ganho e Perdido no evento: valor, moeda e motivo (Purchase só com valor)

**Tarefa de BANCO: executor---plataforma (padrão) e revisão do Head antes de
qualquer aplicação.** Este arquivo foi escrito por `executor-plataforma-2`
(documentação, barato) e **não implementa SQL algum**.

REFS lidas para escrever isto: `docs/adr/ADR-0017-entregar-crm-com-conversoes-desligadas.md`
(itens 3 e a ordem de correção, #5), `docs/adr/ADR-0019-pipeline-fixo-frases-e-rotulos-configuraveis.md`
(última consequência: "o ponto sobre emitir `Purchase` enquanto o valor está
pendente continua no IMP-217, para decisão quando aquela tarefa começar"),
`docs/ROADMAP.md` §5 ("Ganho é emitido **antes de valor e moeda serem
gravados**"; "Purchase quando o valor está pendente: decisão em aberto no
IMP-217"), `docs/CONTRATO-TELA-CRM.md` §4.3/§5, `docs/BANCO_DE_DADOS.md` §8
(matriz de dispatch, linha `ganho` = "Sim, com valor/moeda"), `AGENTS.md`,
`docs/tarefas/IMP-230.md` (estilo) e a definição viva da ponte depois de
IMP-216 (`20260930000000`) e IMP-230 (`20261001000000`).

> **Nada aqui inventa requisito.** Onde não há decisão tomada, está escrito
> **PENDENTE** e listado no bloco "Precisa do Caio/Coordenador antes de
> implementar".

---

**Objetivo (1 frase):** o evento de `ganho` passa a chegar em
`public.events_normalized` **com valor, moeda e status de valor já gravados**
(e o de `perdido` com o **motivo canônico**), e a linha de
`public.conversion_outbox` do `ganho` carrega valor e moeda no payload — o
`Purchase` nunca nasce antes de o valor existir.

**Decisões já tomadas (não reabrir):**

1. **Valor ausente permanece pendente, nunca zero.** `crm.commercial_outcomes`
   já impõe isso (`value_status='pending'` ⇒ `value is null and currency is
   null`; `value_status='valid'` ⇒ `value > 0 and currency` não vazio) e a RPC
   `crm_register_won` recusa `p_value <= 0` com `CRM_INVALID_VALUE`. Nenhum
   caminho desta tarefa pode produzir `valor = 0`.
2. **Perdido não tem valor.** `commercial_outcomes_check2` obriga
   `value_status='pending'` em `outcome='lost'`. O evento de `perdido` leva
   **motivo**, não valor.
3. **Perdido exige um dos 9 motivos canônicos** (`crm.canonical_loss_reasons`),
   e só `outro` exige observação (`requires_note = true`). O motivo já está no
   banco — esta tarefa só o **transporta** para o evento.
4. **Ganho e Perdido são terminais** e o histórico é append-only. Nada aqui
   reabre card nem reescreve histórico.
5. **Elegibilidade por plataforma não muda nesta tarefa.** `perdido` e
   `primeira_conversa` continuam **não elegíveis** para dispatch (matriz da
   §8 do `BANCO_DE_DADOS.md`); quem trata plataforma × evento é o IMP-218.
6. **Esta tarefa não liga flag nenhuma.** `crm_emits_conversions` continua
   `false` nos 6 registros; `crm_feeds_dashboard` continua como a IMP-216
   deixou (ligado para cliente sem GHL, desligado para Royal, Central e
   QuickClean).
7. **As colunas do dashboard são as que já existem.** Não criar coluna nova em
   `events_normalized` sem necessidade comprovada; conferir antes de escrever
   (`valor_ganho`, `closed_value`, `budget_value`, `loss_reason_category`,
   `loss_reason_detail`, `motivo_perda_categoria`, `motivo_perda_detalhe`) —
   as funções de receita do painel somam **`e.valor_ganho`**
   (`get_meta_account_summary`, `get_meta_campaign_summary`,
   `get_meta_creative_summary`, e `v_client_performance_daily_v2` consumida por
   `get_client_overview_v2`). **Escolher a coluna vigente é parte de ler
   produção antes, não um chute.**
8. **PENDENTE — decisão do Caio, antes de o Executor implementar:** *"Purchase
   quando o valor está pendente"*. As opções registradas são (a) **não emitir**
   linha Meta/`Purchase` enquanto `value_status='pending'` — o ganho alimenta o
   dashboard e a conversão fica pendente até o valor existir; (b) emitir
   `Purchase` sem valor (comportamento atual, que a ADR-0017 aponta como
   defeito); (c) emitir só na primeira vez em que o valor existir, incluindo
   quando o valor for preenchido **depois** do ganho. **O Executor não escolhe
   sozinho** — a resposta escolhida entra no PR e no gate.
9. **PENDENTE — se o valor puder ser preenchido depois do ganho** (correção do
   valor numa venda já ganha), esta tarefa precisa de um segundo caminho de
   emissão; hoje só existe o trigger de mudança de etapa. Se a resposta for
   "não existe preenchimento posterior", esse caminho **fica fora de escopo**
   e isso é declarado no PR.
10. **PENDENTE — moeda:** o evento precisa carregar a moeda junto do valor
    (`commercial_outcomes.currency`, hoje `'BRL'` por padrão da RPC). Se a
    coluna de moeda do evento não existir, **parar e escalar** — não inventar
    coluna nem inferir `'BRL'` em silêncio.

**Escopo (o que fazer):**

- **Corrigir a ordem de emissão.** Hoje o trigger
  `opportunities_emit_stage_event` é `after insert or update of
  current_stage_id` em `crm.opportunities`, e em `crm_register_won` o `update`
  da oportunidade (passo 6 do contrato §4.3) acontece **antes** do `insert` em
  `crm.commercial_outcomes` (passo 7). Resultado: o evento de `ganho` nasce sem
  valor. A emissão precisa enxergar o outcome corrente — **a escolha do
  mecanismo é da implementação** (ler o outcome ao emitir, ou emitir a partir
  do outcome), desde que:
  - **não duplique evento** (o no-op de reentrada é o índice
    `events_normalized_crm_opportunity_idx`, por `client_id`,
    `opportunity_id`, `event_code` com `source_system='impuls_crm'`);
  - **não altere** o comportamento para `primeira_conversa` e `perdido` além do
    motivo;
  - **não toque** em histórico append-only.
- Carregar **valor** (e moeda, conforme a decisão 10) no evento de `ganho`.
- Carregar **motivo** (`loss_reason_category`/`loss_reason_detail` ou
  `motivo_perda_*` — a coluna vigente) no evento de `perdido`, a partir de
  `crm.canonical_loss_reasons.code` e da nota de `commercial_outcomes.evidence`
  quando houver.
- Conforme a decisão 8: incluir `value`/`currency` em
  `conversion_outbox.payload->'custom_data'` **apenas** quando
  `value_status='valid'`, ou **não criar a linha** enquanto pendente — a
  escolha da implementação segue a resposta do Caio.
- Rollback que restaura **o estado atual, ACL incluídas**, e declara o que se
  perde (linhas de `events_normalized`/`conversion_outbox` de `impuls_crm`
  gravadas entre aplicação e rollback **não** são apagadas).
- `APLICAR-imp217.sql` autocontido (sem `\ir`, colável no SQL Editor) com
  registro no ledger `supabase_migrations.schema_migrations`; **gate final**
  (`do $gate$`); aceite transacional terminando em `ROLLBACK`; **teste de
  isolamento entre clientes**.

**Fora de escopo (o que NÃO fazer):**

- matriz evento × plataforma e o Google (IMP-218);
- consumidor da `conversion_outbox` (IMP-215) e runbook de ativação (IMP-219);
- ligar `crm_emits_conversions` ou `crm_feeds_dashboard` para qualquer cliente;
- reabrir card terminal, reescrever histórico, migrar eventos já gravados;
- mexer em n8n (os workflows `1.1`/`1.2`/`1.3` são de outra tarefa — ver
  `AGENTS.md`: tocar neles sem tarefa explícita é fora de escopo);
- front (`app/`, `components/`, `lib/`) — esta tarefa é de banco; se o painel
  precisar mudar, **parar e reportar**;
- parser do Stevo e workflows de mídia;
- aplicar em produção (só o Caio aplica).

**Base em produção a ler antes (objetos, funções, políticas) — SOMENTE LEITURA:**

Leitura pura (`SELECT`) antes de escrever qualquer linha de SQL. **A definição
viva manda; nunca arquivo antigo.**

- `pg_get_functiondef` de: `crm.emit_opportunity_stage_event` (versão viva,
  pós-IMP-216 **e** pós-IMP-230 — ela já carrega as colunas Google),
  `public.crm_register_won`, `public.crm_register_lost`,
  `crm.validate_commercial_outcome`, `crm.validate_opportunity`,
  `crm.validate_stage_history`.
- `pg_get_triggerdef` de `opportunities_emit_stage_event` em `crm.opportunities`
  (evento, `for each row`) e a lista completa de triggers de
  `crm.commercial_outcomes` (inclusive `restrict_outcome_revision` e
  `reject_append_only_mutation`) — a emissão pode ter de virar trigger nesta
  tabela, e isso muda o desenho.
- `information_schema.columns` de: `crm.commercial_outcomes`
  (`value`, `value_status`, `currency`, `loss_reason_id`, `evidence`,
  `is_current`, `occurred_at`), `public.events_normalized` (quais colunas de
  valor/motivo existem **hoje** e são consumidas), `public.conversion_outbox`
  (nulabilidade de `ghl_location_id`, `platform`, `platform_event_name`,
  `platform_conversion_action`, `payload`), `public.clients_base`
  (`crm_emits_conversions`, `crm_feeds_dashboard`), `crm.opportunities`
  (`conversion_source`, `ctwa_clid`, `meta_ad_id`, `gclid`, `gbraid`,
  `wbraid`, UTM).
- `crm.canonical_loss_reasons` (9 linhas; só `outro` com `requires_note`).
- Views/funções que somam receita — conferir **qual** coluna é lida:
  `grep -n "valor_ganho" supabase/staging/production-schema.sql` e
  `get_client_overview_v2` / `v_client_performance_daily_v2`.
- ACL e `pg_policies` de `events_normalized`, `conversion_outbox`,
  `events_raw` para `anon`, `authenticated`, `service_role`; e
  `has_function_privilege('anon', 'crm.emit_opportunity_stage_event()',
  'EXECUTE')` — precisa ser `false` no fim.
- Contagens de partida (calculadas como `postgres`, **antes** de trocar de
  papel, sem número fixo no script): `count(*)` de `events_normalized` e
  `conversion_outbox` por `client_id` para Royal, Central, QuickClean e
  ImpulsHub.
- Estado do `conversion_outbox.ghl_location_id`: é **`NOT NULL`** no schema
  observado. Se a implementação exigir linha sem GHL, **isso é bloqueio
  herdado: parar e escalar** (ver Riscos).

**Arquivos previstos:**

- `supabase/migrations/20261003000000_imp217_outcome_value_reason.sql`
- `supabase/migrations/20261003000000_imp217_outcome_value_reason.rollback.sql`
- `supabase/acceptance/APLICAR-imp217.sql`
- `supabase/acceptance/imp217-acceptance.sql`
- `supabase/acceptance/imp217-isolation.sql`

O timestamp segue a sequência depois de `20261002000000` (IMP-231). Nomes de
arquivo são a única coisa maleável aqui.

**Critérios de aceite (verificáveis, com número):**

1. **Ganho com valor:** mover um card de teste até `ganho` com `p_value = X`
   (> 0) e `p_currency='BRL'` faz `events_normalized` ganhar **exatamente 1**
   linha de `ganho` para aquele `opportunity_id`, com a coluna de valor
   **exatamente `X`** e a moeda exatamente `BRL`. Repetir o mesmo movimento
   (reentrada) ⇒ **delta 0**.
2. **Dashboard passa a ver a receita:** `get_client_overview_v2` (ou a view de
   receita vigente) para o cliente de teste devolve receita que **aumenta
   exatamente `X`** em relação à medição antes do movimento — e **era 0**
   antes da migration, para o mesmo card. Número medido antes/depois, colado no
   relatório.
3. **Ganho sem valor:** card movido a `ganho` com `p_value is null` ⇒
   `value_status='pending'`, evento com valor **nulo** (nunca `0`), e o número
   de linhas criadas em `conversion_outbox` para aquele evento é **exatamente o
   que a decisão 8 determinar** (0 se a opção (a) vencer; 1 se a opção (b)).
   O relatório declara qual opção está sendo provada.
4. **Payload do dispatch:** quando `value_status='valid'`,
   `payload->'custom_data'->>'value'` = valor informado e
   `payload->'custom_data'->>'currency'` = `BRL`; quando `pending`, o campo
   **não existe** (`jsonb_strip_nulls` mantido) — medição literal do campo.
5. **Perdido com motivo:** card movido a `perdido` com o motivo `outro` e nota
   ⇒ o evento de `perdido` carrega exatamente o `code` do motivo e a nota onde
   a coluna vigente manda; com um motivo que não exige nota, o evento carrega o
   `code` e a nota vazia/nula. **`perdido` continua com 0 linhas em
   `conversion_outbox`.**
6. **Variação ZERO para Royal, Central e QuickClean** em `events_normalized` e
   `conversion_outbox` (`crm_feeds_dashboard = false` e
   `crm_emits_conversions = false` nos três): contagem por `client_id` antes e
   depois, diferença **exatamente 0** nas duas tabelas.
7. **Isolamento entre clientes:** o modelo de
   `supabase/acceptance/imp213-isolation.sql` (atendente da Central
   `bb04435c-fabb-4ba8-b5b5-e0175d9ca17d`, gestor Royal
   `7c3296f4-13c7-42d1-89eb-72aecec905ba`) devolve **só** o `client_id` do
   próprio usuário em todo objeto tocado; RPC chamada com o id de outro cliente
   devolve **0 linhas** ou `42501`.
8. **Rollback provado:** devolve função/triggers, ACL e comportamento ao estado
   atual; declara que eventos já gravados no intervalo permanecem.
9. **Gate final** (`do $gate$`) falha a migration se faltar: a coluna de valor
   vigente populada no caminho de `ganho`, o motivo no caminho de `perdido`,
   o índice de dedupe presente, e
   `has_function_privilege('anon', 'crm.emit_opportunity_stage_event()',
   'EXECUTE') = false`.
10. **ACL:** `revoke all ... from public, anon` **depois de todo `CREATE`** de
    função; `grant` explícito a `authenticated`/`service_role` conforme o caso.

**Testes obrigatórios:** (inclui isolamento entre clientes)

- `npx tsc --noEmit` e `node --test lib/*.test.mjs` (Node ≥ 22.18) — a mudança
  é de banco e o front **não** deve mudar; se não rodar no ambiente do
  Executor, **registrar no PR em vez de pular em silêncio**;
- `git diff --check`;
- `scripts/db-prova.py --dry-run` (leitura pura, sem escrita) com a saída colada
  no relatório, **antes** de qualquer escrita em banco; ou
  `scripts/staging-run.py` para provar a migration em **staging**
  (projeto `nfratueiutxnypbxfnmi`) antes de pedir revisão;
- aceite transacional terminando em `ROLLBACK` (roda o Coordenador ou o Head,
  com autorização escrita do Caio para **aquela** execução);
- **teste de isolamento entre clientes** (critério 7);
- prova de rollback (critério 8);
- medição de **variação zero** para os três clientes com GHL (critério 6).

**Riscos conhecidos:**

- **Duplicar o `Purchase` é o erro mais caro do projeto** — evento aceito pela
  Conversions API não volta. Qualquer caminho novo de emissão tem de passar
  pelo dedupe de `events_normalized_crm_opportunity_idx` e por um teste de
  reentrada explícito (critério 1).
- **`conversion_outbox.ghl_location_id` é `NOT NULL`.** Cliente sem GHL
  (ImpulsHub) não tem como receber linha na outbox hoje. Isso é **bloqueio
  herdado**: se a tarefa exigir a linha, **parar e escalar** (relaxar a
  nulabilidade é mudança em tabela compartilhada com o n8n `1.2`/`1.3` e exige
  o Head).
- **Emitir a partir de `crm.commercial_outcomes`** faz a emissão depender de
  tabela com triggers de revisão (`restrict_outcome_revision`) e append-only:
  um trigger `after insert` nela convive com regras já existentes — **validar
  o desenho com o Head antes de codificar**, é mudança de superfície sensível.
- **Coluna de moeda no evento pode não existir.** Não inferir `'BRL'`.
- **Duplicação de evento para cliente com GHL** se a flag de dashboard for
  tocada por engano — não é para tocar.
- Detalhes herdados que já custaram caro: `ALTER TABLE` depois de `UPDATE` na
  mesma transação exige `set constraints all immediate`; `psql` não substitui
  variável dentro de `$$` (arrays inline no aceite); função escalar `setof
  uuid` **sempre com alias** (`from f() as m`, comparar com `m` — ADR-0020);
  recriar função devolve privilégios ao `anon` sem o `revoke`.

**Entrega:** PR draft, relatório em 3 blocos (verificado rodando com o número
medido / correto por construção não testado / não bateu e por quê),
migration + rollback + `APLICAR-imp217.sql` + gate + aceite + teste de
isolamento entre clientes.

**Escalar ao Head se:**

- a definição viva de `crm.emit_opportunity_stage_event` (ou de
  `crm_register_won`/`crm_register_lost`) divergir do que a IMP-216/230 deixou;
- a coluna de valor ou de motivo que o painel soma não existir, ou existir mais
  de uma candidata e não der para escolher sem decisão;
- o desenho exigir trigger em `crm.commercial_outcomes` (superfície sensível)
  ou mexer em `conversion_outbox` (tabela compartilhada com o n8n);
- a decisão 8 (Purchase com valor pendente) não estiver respondida pelo Caio;
- dúvida de autorização (escrita em produção, prova transacional, ligar flag) —
  **parar** e perguntar, nunca improvisar;
- duas tentativas falhas na mesma etapa.

**Precisa do Caio/Coordenador ANTES de implementar:**

1. **Decisão 8** — "Purchase quando o valor está pendente": (a) não emitir
   `Purchase` enquanto pendente, (b) emitir sem valor (comportamento atual), ou
   (c) emitir quando o valor existir, inclusive depois do ganho.
2. **Decisão 9** — existe preenchimento de valor **depois** do ganho? (Define se
   há um segundo caminho de emissão ou se ele fica fora de escopo.)
3. **Decisão 10** — moeda: qual coluna do evento carrega a moeda; se nenhuma
   existe, autoriza criar (o que muda o gate) ou o valor vai sem moeda no
   evento?
4. **Autorização da prova transacional em produção** (uma execução,
   `begin…rollback`), se a prova não puder ser feita só em staging.