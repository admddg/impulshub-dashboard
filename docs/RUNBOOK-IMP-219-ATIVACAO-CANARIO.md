# Runbook IMP-219 — Ativação canário de `crm_emits_conversions`

**Para quem é este documento:** o Caio (não-dev), com apoio de um agente/DBA
executando os comandos SQL de leitura e o comando de ativação. Cada passo diz
o que rodar, o que olhar e quando parar.

**O que esta flag faz:** `public.clients_base.crm_emits_conversions` controla
se o CRM (via `crm.emit_opportunity_stage_event`) grava linhas em
`public.conversion_outbox` para um cliente. Essas linhas são varridas pelo
consumidor do IMP-215 (workflow n8n `AHT6ltpnxdC29QCC` + filhos `1.2`/`1.3`) e
entregues à Meta Conversions API e ao Google Data Manager API. **A entrega é
irreversível**: evento aceito por essas APIs não volta.

**O que esta flag NÃO faz:** não desliga o GHL do cliente, não apaga histórico,
não faz replay de eventos antigos. É só a chave de "o CRM pode gravar na fila".

---

## 0. Estado de partida (confirmado em produção, leitura em 25/09/2026)

Estas linhas são **fato medido**, não hipótese, e o runbook parte delas:

| Item | Estado medido |
|---|---|
| Cliente ImpulsHub (`3ec294db-a64a-4420-9b4a-0d917f65d399`) | `crm_emits_conversions = true` desde **25/09/2026 20:54 UTC** |
| Autorização | Confirmada pelo Caio — uso legítimo da própria conta da Impuls para teste interno. **Não é incidente, não precisa ser revertido.** |
| Linhas na `conversion_outbox` para a Impuls via `impuls_crm` | 2 linhas, evento `agendado`, `platform='meta'` e `platform='google_ads'`, `status='failed'`, `attempts=3`, `last_error='n8n_expression_parse_failed_before_http; no_external_request_made'`, criadas em 24/09/2026 19:11 UTC |
| Diagnóstico dessas 2 falhas | **PENDENTE de confirmação.** O erro é do mesmo tipo (parse de expressão n8n antes do HTTP) que o commit `3a51e80` ("fix: harden IMP-215 n8n claim dispatch contract") endureceu. Não está confirmado que o fix já cobre este caso nem que as linhas foram reprocessadas. **Não afirmar resolvido sem reexecutar e medir.** |
| GHL da Impuls | Último evento `source_system='ghl'` em `events_normalized` foi em **27/08/2026** — 0 eventos GHL nos últimos 7 dias (medido em 25/09/2026). Consistente com a Impuls já ter saído do fluxo GHL. |
| Royal, Central, QuickClean | Continuam só no GHL. Nos últimos 7 dias (medido em 25/09/2026): Royal 436 eventos, Central 345, QuickClean 210 — volume real e vivo, todos com `crm_emits_conversions = false`. |
| Outros clientes (`template`, `teste*`) | Todos `crm_emits_conversions = false`; nenhum tem GHL ativo com volume — não são alvo deste runbook ainda. |

**Regra que este runbook nunca quebra:** nenhum cliente com GHL ativo tem a
flag ligada. A Impuls já não tem GHL ativo — por isso o estado atual dela não
viola a regra, mas **qualquer próximo cliente com GHL precisa ter esse GHL
comprovadamente parado antes de a flag ligar** (passo 3).

---

## 1. Pré-condições — tudo isto precisa ser verdade antes de considerar ligar a flag para um cliente NOVO

Marque cada item com a query de leitura correspondente antes de prosseguir.
Se qualquer um falhar, **pare** — não ligue a flag.

1. **IMP-215, 216, 217 e 218 aplicadas em produção.** Confirmar lendo
   `docs/STATUS-OPERACIONAL.md` e, se houver dúvida, `pg_get_functiondef` de
   `crm.emit_opportunity_stage_event` para ver se já grava por plataforma
   (IMP-218) e com valor/motivo (IMP-217).
2. **O consumidor do IMP-215 está ativo e testado num ciclo real**, não só num
   ciclo vazio. Hoje (25/09/2026) o único ciclo observado (execução `17057`)
   teve `candidate_count=0` — nunca houve claim, HTTP nem closure exercitados
   de verdade. **Isto é uma lacuna de evidência conhecida, não deste runbook:
   documentar no canário (passo 5) que a primeira prova real do consumidor
   pode acontecer durante o próprio canário.**
3. **O cliente candidato tem `ghl_location_id` resolvido ou é comprovadamente
   sem GHL** (como a Impuls). Ver passo 3 abaixo para a checagem de emissão.
4. **A decisão de replay vs. ignorar do histórico acumulado está tomada**
   (passo 4) — nunca ligar a flag sem essa resposta explícita para aquele
   cliente específico.
5. **Meta Ads Manager (Gerenciador de Eventos) acessível** para o cliente
   candidato, com o pixel/dataset certo identificado, para o passo 5.

---

## 2. Comando de ativação auditado

### Mecanismo (proposta, reaproveitando o que já existe — sem tabela nova)

`clients_base` não tem coluna de auditoria de quem/quando mudou uma flag, e
criar uma não é necessário: o projeto já tem `public.workflow_execution_logs`
— tabela genérica, `metadata jsonb`, sem `client_id` obrigatório amarrado a
onboarding (diferente de `internal_onboarding_audit`, que é presa a
`onboarding_id` e não serve aqui). Nenhuma migration é necessária.

**Comando de ativação, em uma única transação**, sempre executado por um
agente/DBA em nome do Caio, nunca direto por alguém sem revisão:

```sql
begin;

-- 1. registra a intenção ANTES de mudar o dado, com quem/quando/para quem/porquê
insert into public.workflow_execution_logs (
  id, workflow_key, workflow_name, workflow_category,
  client_id, client_slug, client_name,
  status, stage, started_at, finished_at, metadata
) values (
  gen_random_uuid(),
  'manual-imp219-canary-activation',
  'IMP-219 - Ativação manual de crm_emits_conversions',
  'ops',
  '<client_id>', '<client_slug>', '<client_name>',
  'success', 'flag_enabled', now(), now(),
  jsonb_build_object(
    'actor', '<nome de quem autorizou/executou — ex: Caio via agente-plataforma>',
    'flag', 'crm_emits_conversions',
    'from', false,
    'to', true,
    'motivo', '<1 frase: por que este cliente, agora>',
    'ghl_check_ref', '<referência da query do passo 3, com o resultado colado>',
    'replay_decision_ref', '<qual opção do passo 4 foi escolhida para este cliente>'
  )
);

-- 2. muda a flag de fato
update public.clients_base
set crm_emits_conversions = true,
    updated_at = now()
where id = '<client_id>'
  and crm_emits_conversions = false; -- trava: não reativa quem já está ligado sem querer

commit;
```

**Por que uma linha em `workflow_execution_logs` e não uma tabela nova:** a
coluna `metadata jsonb` comporta ator, motivo e referências sem alterar
schema; a tabela já é lida pelas views de observabilidade existentes
(`v_workflow_health_daily`), então o registro fica visível no mesmo lugar que
o resto da operação, sem superfície nova para manter. Se no futuro isso se
mostrar insuficiente (por exemplo, quiser reverter automaticamente por
trigger), reavaliar — mas hoje é a opção mais simples que resolve.

**Quem pode aplicar:** só com autorização explícita do Caio para aquele
cliente, naquele momento — nunca em lote, nunca "aproveitando que já estou
aqui". Escrita em produção fora de leitura exige aprovação (`AGENTS.md` regra
8).

---

## 3. Checagem de que o GHL não emite mais para aquele cliente

Rodar **antes** do comando de ativação, com o resultado colado no `metadata`
acima (`ghl_check_ref`). Duas leituras complementares:

**3.1 — Eventos GHL recentes chegando pelo `1.1`:**

```sql
select count(*) as eventos_ghl_ultimos_7_dias
from public.events_normalized
where client_id = '<client_id>'
  and source_system = 'ghl'
  and created_at >= now() - interval '7 days';
```

Critério: **precisa ser 0.** Se for maior que 0, **não ligue a flag** — o
cliente ainda está recebendo/gerando eventos pelo GHL e ligar o CRM em
paralelo duplica conversão na Meta (irreversível).

**3.2 — Confirmação operacional fora do banco:** perguntar diretamente à
clínica ou à agência se a subconta GHL foi desativada/desconectada do fluxo
de conversão (webhook, automação, ou o que quer que hoje empurre eventos para
o `1.1`). O banco só prova ausência de eventos que **já chegaram**; não prova
que a fonte foi desligada — só que não mandou nada nos últimos 7 dias. Para
um cliente novo saindo do GHL agora, confirmar com quem fez o desligamento.

**Referência de exemplo, medida em 25/09/2026:** a Impuls teve 0 eventos
`source_system='ghl'` nos últimos 7 dias (último evento GHL dela foi
27/08/2026) — é o padrão que qualquer cliente novo precisa repetir antes de
a flag ligar.

---

## 4. Replay vs. ignorar o histórico acumulado — PENDENTE, decisão do Caio

**Este runbook não decide isso.** Enquanto a flag estava `false`, o cliente
pode ter passado por etapas do funil (lead, agendado) sem gerar evento de
conversão. Ligar a flag tarde, sem tratar isso, produz um funil que **começa
no meio** (ex.: primeiro evento que a Meta vê é `agendado`, sem o `lead` que
vino antes) — a otimização da campanha perde sinal.

### Opção A — Ignorar (não fazer replay)

- **Prós:** simples, zero risco de duplicar evento, zero trabalho extra.
- **Contras:** o funil na Meta/Google começa no meio; oportunidades que já
  avançaram etapas antes da ativação nunca geram o evento de etapas
  anteriores; a otimização de campanha fica com sinal incompleto para essas
  oportunidades específicas (as novas, criadas depois da ativação, não são
  afetadas).

### Opção B — Replay (reconstruir e enviar eventos retroativos)

- **Prós:** funil completo desde o começo para oportunidades já em andamento;
  melhor sinal de otimização.
- **Contras:** exige construir um caminho de emissão retroativa que hoje **não
  existe** (é trabalho novo, fora do escopo do IMP-215 a 218); risco de
  duplicar se qualquer evento já tiver saído por outro caminho (ex.: GHL, se
  o desligamento não foi limpo); eventos com timestamp antigo podem ser
  tratados de forma diferente pela Meta (atribuição de janela); é a opção com
  mais superfície de erro **e o erro é irreversível**.

### O que este runbook exige, independentemente da opção escolhida

- A decisão é **por cliente**, registrada no `metadata` do comando de
  ativação (`replay_decision_ref`), nunca assumida em silêncio.
- Se a opção for B, ela **não pode ser feita como parte deste runbook** — é
  uma tarefa separada, com plano próprio, escopo próprio e teste de
  duplicação próprio, revisada antes de qualquer envio retroativo.
- Enquanto não houver decisão, a flag não liga para aquele cliente.

**Pergunta explícita para o Caio, por cliente, antes da ativação: opção A ou
B — e se B, quem escreve o plano de replay antes de a flag ligar?**

---

## 5. Protocolo do canário

**Escopo: um cliente por vez, nunca mais de um em paralelo.** A primeira
aplicação real ao vivo é a própria Impuls (já ligada e autorizada) — trate-a
como o canário em curso, não como "já passou".

### 5.1 Antes de ligar (ou, no caso da Impuls, antes de expandir a mais alguém)

1. Rodar as contagens de partida por plataforma para o cliente:
   ```sql
   select platform, status, count(*)
   from public.conversion_outbox co
   join public.events_normalized en on en.id = co.normalized_event_id
   where en.client_id = '<client_id>'
   group by 1, 2
   order by 1, 2;
   ```
   Guardar esse resultado — é o "antes" da comparação do passo 5.3.
2. Confirmar no Gerenciador de Eventos da Meta (Events Manager) a contagem de
   eventos recebidos para o pixel/dataset do cliente nas últimas 24-48h,
   antes da ativação — é a linha de base "sem CRM".

### 5.2 Janela do canário

- **Duração:** poucas horas (o card sugere isso; não uma semana). Um
  intervalo prático é 4 a 8 horas úteis, cobrindo pelo menos um ciclo em que
  cards realmente se movem no CRM daquele cliente.
- **Durante a janela**, mover cards normalmente (nenhuma alteração de
  processo é pedida da clínica) e observar sem intervir, a menos que um
  critério de abortar (passo 6) dispare.

### 5.3 O que conferir no Gerenciador de Eventos da Meta

- **Contagem de eventos recebidos** para o pixel/dataset do cliente, no
  intervalo do canário, comparada à contagem esperada (número de cards que
  mudaram de etapa elegível no CRM no mesmo intervalo — consultar
  `events_normalized` com `source_system='impuls_crm'`).
- **Qualidade de correspondência (match quality)** não deve cair de forma
  abrupta em relação à média recente do cliente.
- **Nenhum evento duplicado óbvio** (mesmo `event_id`/`fbp`/telefone com
  dois eventos do mesmo tipo no mesmo momento) — o Gerenciador de Eventos
  mostra deduplicação quando o `event_id` é reconhecido.
- **Erros/avisos na aba de diagnóstico** do pixel/dataset — parâmetros
  ausentes, erros de correspondência, ou avisos novos que não existiam antes
  da ativação.
- Em paralelo, no banco:
  ```sql
  select platform, status, count(*)
  from public.conversion_outbox co
  join public.events_normalized en on en.id = co.normalized_event_id
  where en.client_id = '<client_id>'
    and co.created_at >= '<início do canário>'
  group by 1, 2
  order by 1, 2;
  ```
  Comparar contra a contagem esperada de movimentos de card no mesmo período.

---

## 6. Critérios explícitos de abortar

Desligar a flag imediatamente (`update ... set crm_emits_conversions = false`,
com o mesmo padrão de log auditado do passo 2, registrando o motivo do
abort) se qualquer um destes ocorrer durante o canário:

1. **Qualquer evento GHL aparecer para o mesmo cliente** durante a janela do
   canário (`source_system='ghl'` em `events_normalized` com
   `created_at` dentro da janela) — sinal de que o GHL não estava
   realmente desligado; duplicação de conversão já pode ter ocorrido.
2. **Linha `failed` na `conversion_outbox`** para o cliente, com
   `attempts` esgotando o limite (hoje 4) sem nunca ter enviado — como já
   aconteceu com as 2 linhas de 24/09 da própria Impuls. Um `failed`
   isolado que já foi diagnosticado como bug conhecido não exige abortar
   sozinho, mas **qualquer `failed` novo e não diagnosticado durante o
   canário, exige abortar e investigar antes de continuar.**
3. **Contagem de eventos no Gerenciador de Eventos muito acima do esperado**
   (mais eventos recebidos do que cards movidos no CRM no mesmo intervalo) —
   sinal de possível duplicação ou de o consumidor reprocessando linha já
   enviada.
4. **Contagem de eventos no Gerenciador de Eventos muito abaixo do esperado**
   por período prolongado (mais que 1-2 horas de defasagem sem explicação) —
   sinal de que o consumidor não está entregando (ex.: mesmo bug de parse de
   expressão n8n das 2 linhas conhecidas, agora em escala).
5. **Erro novo e não visto antes** na aba de diagnóstico do pixel/dataset do
   cliente no Events Manager.
6. **Dúvida sobre se algum evento pode ter duplicado** — na dúvida, abortar
   primeiro e investigar depois. Não é possível desfazer um evento aceito;
   o único controle que resta é parar de gerar mais.

---

## 7. Reconciliação pós-canário (se houver duplicidade)

A duplicidade na Meta/Google **não pode ser desfeita** — evento aceito pela
Conversions API/Data Manager fica lá. O trabalho de reconciliação é **medir e
documentar**, não apagar:

1. **Identificar o alcance:** para a janela do canário, listar todas as
   linhas de `conversion_outbox` com `status='sent'` para o cliente,
   cruzando com `events_normalized` para achar duplicatas por
   `opportunity_id` + `event_code` vindas de dois `source_system` diferentes
   (`ghl` e `impuls_crm`) no mesmo intervalo.
   ```sql
   select opportunity_id, event_code, source_system, created_at
   from public.events_normalized
   where client_id = '<client_id>'
     and created_at >= '<início do canário>'
   order by opportunity_id, event_code, created_at;
   ```
   Duas linhas com o mesmo `opportunity_id`+`event_code` de fontes diferentes
   no mesmo intervalo são candidatas a duplicidade.
2. **Registrar no `workflow_execution_logs`** (mesmo padrão do passo 2) uma
   linha com `workflow_key='manual-imp219-post-canary-reconciliation'`,
   `metadata` contendo: quantas duplicidades foram encontradas, quais
   `opportunity_id`, e a decisão tomada (aceitar o impacto na atribuição,
   avisar a agência que administra a campanha, ou qualquer outra ação
   operacional fora do banco).
3. **Comunicar** à pessoa que gerencia as campanhas Meta/Google do cliente
   que houve sobreposição, para que ela saiba interpretar picos de conversão
   no relatório de campanha do período — isso é operação de mídia, não algo
   que o banco resolve.
4. **Não reverter dado histórico.** As linhas de `events_normalized` e
   `conversion_outbox` do intervalo permanecem como estão; a reconciliação é
   documentação e comunicação, não DML de correção.

---

## 8. Checklist final — seguro para expandir a mais clientes

Só considerar ligar a flag para o **próximo** cliente depois de:

- [ ] Canário do cliente atual rodou pela janela completa sem disparar
      nenhum critério de abortar (seção 6).
- [ ] Contagem de eventos no Gerenciador de Eventos da Meta bateu com a
      contagem esperada de movimentos de card (dentro de uma margem
      explicada, não "parece que bateu").
- [ ] As linhas `failed` conhecidas (se existirem) foram diagnosticadas —
      não necessariamente corrigidas, mas **entendidas**, com causa raiz
      escrita, não hipótese.
- [ ] Nenhuma duplicidade encontrada, ou, se encontrada, documentada
      conforme a seção 7 e comunicada a quem administra a campanha.
- [ ] A decisão de replay vs. ignorar (seção 4) está registrada para o
      cliente que acabou de passar pelo canário — não fica pendente depois
      do fato.
- [ ] O comando de ativação do próximo cliente já tem a checagem do passo 3
      (GHL parado) feita e colada no registro de auditoria antes de rodar.
- [ ] O Caio autorizou explicitamente o próximo cliente, um de cada vez —
      nunca em lote.

---

## Perguntas explícitas para o Caio (não decidir sozinho)

1. **Replay vs. ignorar (seção 4):** para a Impuls (já ligada) e para cada
   próximo cliente, qual opção — A (ignorar) ou B (replay)? Se B, quem
   escreve o plano de replay antes de qualquer envio retroativo?
2. **As 2 linhas `failed` da Impuls (24/09, `n8n_expression_parse_failed_before_http`):**
   autoriza reexecutar/reprocessar essas 2 linhas específicas para confirmar
   se o fix do commit `3a51e80` já resolve, ou prefere deixá-las como
   `failed` (histórico) e só observar daqui para frente?
3. **Janela exata do canário** (o runbook sugere 4-8 horas úteis) — confirma
   esse intervalo ou prefere outro?
4. **Quem é a pessoa de referência para checar o Gerenciador de Eventos da
   Meta** durante a janela do canário (o próprio Caio, alguém da agência,
   ou um agente com acesso)?
5. **Próximo cliente candidato ao canário** depois da Impuls — qual é, e ele
   já tem o GHL comprovadamente parado (seção 3)?
