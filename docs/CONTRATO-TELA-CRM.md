# Contrato — camada `public` para a aba CRM (IMP-206 / IMP-207)

> **Para quem implementa o banco.** Este documento é a especificação do que
> precisa existir em `public` para a aba CRM ser construída. Nada aqui é
> frontend: são 8 views e 4 funções, mais uma correção de dado.
>
> Escrito em 18/09/2026, contra o estado real de `Clients_Base`
> (`mtxnwtqwfagjzkvgsncs`). Todos os números citados foram medidos, não
> estimados.

---

## 1. Por que isto existe

A restrição conhecida é "no schema `crm`, `authenticated` só tem `select`".
Ela é verdadeira, mas é a metade menor do problema.

**O PostgREST expõe apenas o schema `public`.** Confirmado em duas frentes:
não há `pgrst.db_schemas` em `pg_db_role_setting`, e o próprio código do
painel já registra isso (`lib/access.ts`, no comentário de `amIAgencyUser`,
que existe justamente por causa disso).

Consequência medida: **nenhuma view e nenhuma função de `public` referencia
o schema `crm` hoje.** Zero. O navegador não tem caminho de leitura nem de
escrita para o CRM — `supabase.from('opportunities')` falha inclusive no
`select`.

Por isso a camada abaixo. Ela é a única coisa entre o schema `crm` em
produção e a tela.

### Divisão entre leitura e escrita

| | Mecanismo | Por quê |
|---|---|---|
| **Leitura** | views em `public` com `security_invoker = true` | `authenticated` já tem `select` nas 14 tabelas do `crm`, e a RLS por `crm.is_member(tenant_id)` continua valendo dentro da view. Não precisa de `SECURITY DEFINER` — e não se deve usar, porque isso contornaria a RLS |
| **Escrita** | 4 funções em `public`, `SECURITY DEFINER`, `grant execute to authenticated` | Única forma de o navegador escrever sem `service_role` no cliente. Mesmo padrão de `get_internal_operations_feed`, que já roda em produção |

O frontend continua falando só com `public`, exatamente como as views V2.
Ele nunca escreve o nome `crm` em lugar nenhum.

---

## 2. Pré-requisito: nomes dos usuários

**`crm.profiles.display_name` está `NULL` nas 6 linhas.** E
`public.client_users` não tem coluna de nome nem de e-mail. `auth.users` não
é legível por `authenticated`.

Resultado prático: sem correção, o seletor "atribuir dono" do IMP-207
renderiza seis UUIDs. A funcionalidade existe e não serve para nada.

**Precisa de um `update` nas 6 linhas de `crm.profiles`** preenchendo
`display_name`. É dado, não arquitetura — mas bloqueia a entrega do IMP-207.

Os 6 ids estão em `crm.profiles`; os 4 que operam hoje aparecem em
`public.client_users` com `is_active = true`.

---

## 3. Leitura — 8 views

Todas com `security_invoker = true`. Todas com `grant select to authenticated`.

### Regra de consumo que o frontend vai seguir

Nenhuma dessas views é lida inteira. Colunas de kanban e listas usam
`.range()` com `count: 'exact'`; contagens vêm agregadas do banco. A regra
nº2 do projeto (o PostgREST corta acima de ~1.000 linhas sem erro) foi o que
desenhou a separação entre `v_crm_board_counts_v1` e `v_crm_cards_v1`.

---

### 3.1 `v_crm_board_counts_v1`

Grão: cliente × etapa. **Sempre 6 linhas por cliente**, inclusive as
zeradas — a coluna vazia do kanban precisa aparecer.

```
client_id          uuid
stage_code         text      lead | atendimento | agendado | compareceu | ganho | perdido
stage_label        text
stage_position     smallint  1..6
is_terminal        boolean
opportunities      bigint    contagem; 0 quando vazia
```

Construção: `crm.tenants` (escopado pela RLS) × as 6 linhas de
`crm.global_pipeline_stages` da versão ativa, `left join` nas
oportunidades. **É daqui que sai o número no topo de cada coluna.** O
frontend não conta linha.

Hoje: `atendimento` 239 (Royal 159, QuickClean 80), `lead` 1 (Central),
demais 0.

---

### 3.2 `v_crm_cards_v1`

Grão: oportunidade. É o card do kanban e a base do IMP-207.

```
client_id                      uuid
opportunity_id                 uuid
contact_id                     uuid
contact_name                   text
phone_normalized               text
whatsapp_url                   text       'https://wa.me/' || phone_normalized
title                          text
stage_code                     text
stage_label                    text
stage_position                 smallint
is_terminal                    boolean
status                         text       open | won | lost
stage_version                  integer    <- o frontend devolve isto no move
owner_profile_id               uuid
owner_name                     text
opened_at                      timestamptz
closed_at                      timestamptz
last_activity_at               timestamptz
meta_ad_id                     text
ad_name                        text
adset_name                     text
campaign_name                  text
creative_name                  text
thumbnail_url                  text
ctwa_clid                      text
conversion_source              text
entry_point_conversion_source  text
source_url                     text
ad_title                       text
```

**`whatsapp_url` vem pronto da view, não montado em JavaScript.**
`phone_normalized` é dígito puro com DDI (12 ou 13 caracteres, sem
normalização de nono dígito — verificado), então `wa.me/<phone>` resolve
direto.

**Join de atribuição:** `meta_ad_id` -> `public.v_meta_ads_v2` por
`(client_id, ad_id)`. Medido: **236 das 237 oportunidades com `meta_ad_id`
casam.**

⚠️ `v_meta_ads_v2` tem grão de anúncio-por-dia, e **293 `ad_id` aparecem em
mais de uma data**. O join precisa de `distinct on (client_id, ad_id) …
order by date desc` ou equivalente. Sem isso, um card vira N cards — e a
contagem da coluna deixa de bater com `v_crm_board_counts_v1`.

---

### 3.3 `v_crm_contacts_v1`

Grão: contato. É a lista com busca do IMP-206.

```
client_id             uuid
contact_id            uuid
full_name             text
phone_normalized      text
email                 text
whatsapp_url          text
status                text        active | archived
last_activity_at      timestamptz
messages_total        bigint
opportunity_id        uuid        a MAIS RECENTE do contato; null se não houver
stage_code            text
stage_label           text
stage_position        smallint
opportunity_status    text
search_text           text        lower(unaccent(full_name)) || ' ' || phone_normalized
```

**`search_text`** existe para a busca ser um `ilike` só, em vez de um `.or()`
de três colunas no cliente. Se `unaccent` não estiver disponível, `lower()`
serve.

**`opportunity_id` é a mais recente por contato, não a única.** Hoje são 1:1
(240 contatos com 1 oportunidade aberta cada, medido), mas o schema suporta
ciclos via `previous_opportunity_id` e um dia haverá contato com duas. Usar
`distinct on (contact_id) … order by opened_at desc`.

Hoje: 624 contatos (Royal 287, QuickClean 326, Central 11). Cresce todo
minuto — o parser está rodando.

---

### 3.4 `v_crm_card_history_v1`

Grão: um evento de histórico. União de três tabelas append-only, para a tela
mostrar uma linha do tempo só.

```
client_id           uuid
opportunity_id      uuid
occurred_at         timestamptz
event_kind          text        'stage' | 'milestone' | 'outcome'
transition_type     text        automatic | manual | undo | correction   (stage)
origin              text        frase_configurada | manual | integracao | sistema
from_stage_code     text
from_stage_label    text
to_stage_code       text
to_stage_label      text
milestone_kind      text        lead_received | conversation_started | …  (milestone)
outcome             text        won | lost                                (outcome)
loss_reason_code    text
loss_reason_label   text
value               numeric
value_status        text        pending | valid
currency            text
evidence            text
reason              text
actor_profile_id    uuid
actor_name          text
```

A tela **mostra**; nunca reescreve. Os três triggers `append_only` já
garantem isso do lado do banco — a view existe para que a regra fique
visível, não para reforçá-la.

Hoje: 479 linhas em `opportunity_stage_history`, 479 em
`opportunity_milestones`, 0 em `commercial_outcomes`.

---

### 3.5 `v_crm_activities_v1`

Grão: mensagem. **Escopada por contato, não por oportunidade.**

```
client_id             uuid
contact_id            uuid
opportunity_id        uuid        frequentemente null
activity_id           uuid
created_at            timestamptz
kind                  text        message | note | call | form | system
direction             text        inbound | outbound | internal
body                  text
provider_message_id   text
```

⚠️ **Detalhe que muda o resultado:** das 8.876 atividades, **5.826 não têm
`opportunity_id`**. Uma view por oportunidade esconderia dois terços da
conversa. O histórico do card lê por `contact_id`.

Máximo medido: 100 mensagens por contato. Ainda assim o frontend pagina — é
conversa de WhatsApp, cresce sem teto.

---

### 3.6 `v_crm_owners_v1`

Grão: pessoa que pode ser dona de um card, por cliente.

```
client_id        uuid
profile_id       uuid
display_name     text
membership_role  text      de crm.tenant_memberships: owner|admin|manager|attendant|integration|viewer
can_write        boolean   de public.client_users: is_active and lower(role) <> 'viewer'
```

**Base obrigatória: `crm.tenant_memberships` com `status = 'active'`.** Não é
escolha de estilo — `opportunities.owner_profile_id` tem FK composta para
`(tenant_id, profile_id)` dessa tabela. Um dono fora dela é rejeitado.

`can_write` sai de `public.client_users` porque é de lá que o trigger lê
(ver §5).

---

### 3.7 `v_crm_loss_reasons_v1`

```
code            text
label           text
requires_note   boolean
active          boolean
```

Sem escopo de cliente — a política de `crm.canonical_loss_reasons` é
`using (true)`. São 9 linhas, e só `outro` tem `requires_note = true`.

A tela ordena por `label` e mostra só `active = true`.

---

### 3.8 `v_crm_my_role_v1`

```
client_id    uuid
role         text
can_write    boolean
```

De `public.client_users` para o `auth.uid()` corrente. **É o que esconde os
botões de ação do `viewer`**, em vez de deixar o usuário clicar e tomar erro
de trigger.

⚠️ Note o vocabulário: em `public.client_users` os papéis são **`agency` (10)
e `viewer` (4)** — não `admin`. O "10 admin e 3 viewer" que circula na tarefa
é `crm.tenant_memberships`, que é outra tabela. Conferi as 13 linhas: as duas
batem, mesmo usuário, mesmo tenant, sem órfão dos dois lados. Mas quem
autoriza a escrita é `client_users`, então `can_write` sai de lá.

---

## 4. Escrita — 4 funções

Todas em `public`, `LANGUAGE plpgsql`, `SECURITY DEFINER`,
`SET search_path = ''`, `grant execute to authenticated`,
`revoke execute from anon`.

**Todas retornam a linha atualizada de `v_crm_cards_v1`.** A tela
re-renderiza do banco em vez de adivinhar o estado novo — é a regra nº1
aplicada à escrita.

### Guarda comum, no início das quatro

1. Resolver `tenant_id` **a partir da própria oportunidade**. Nunca aceitar
   `tenant_id` como parâmetro — o cliente não é fonte de verdade sobre o
   próprio escopo.
2. `crm.is_member(tenant_id)` -> falso levanta `CRM_FORBIDDEN`.
3. Papel em `public.client_users`: `is_active` e `lower(role) <> 'viewer'`
   -> falha levanta `CRM_FORBIDDEN`.
4. `actor_profile_id := auth.uid()`, sempre. Nunca vem por parâmetro.
5. `select … from crm.opportunities … for update` antes de qualquer escrita.

---

### 4.1 `crm_move_stage(p_opportunity_id uuid, p_to_stage_code text, p_expected_stage_version integer, p_reason text default null)`

Move entre as quatro etapas não-terminais. **Ganho e Perdido não passam por
aqui** — têm payload próprio (§4.3, §4.4).

Sequência, uma transação:

1. Guarda comum.
2. `stage_version <> p_expected_stage_version` -> `CRM_STAGE_CONFLICT`.
   Outro atendente moveu o card enquanto esta tela o exibia; o frontend
   recarrega e mostra o estado novo.
3. Origem terminal (`status <> 'open'`) -> `CRM_TERMINAL`.
4. `p_to_stage_code in ('ganho','perdido')` -> `CRM_USE_OUTCOME_RPC`.
5. Regressão (`to.position < from.position`) com `p_reason` vazio ->
   `CRM_REASON_REQUIRED`. O trigger `validate_stage_history` já cobra isso;
   a RPC antecipa para a mensagem chegar limpa na tela.
6. `insert` em `crm.opportunity_stage_history`: `transition_type = 'manual'`,
   `origin = 'manual'`, `actor_profile_id = auth.uid()`, `reason = p_reason`.
7. `update crm.opportunities` com `current_stage_id`,
   `stage_version = stage_version + 1`, `updated_at = now()`.
8. Marco correspondente em `crm.opportunity_milestones` quando a etapa tiver
   um (`agendado` -> `appointment`, `compareceu` -> `attendance`),
   `origin = 'manual'`.

A ordem entre 6 e 7 não importa: os três triggers de consistência são
`DEFERRABLE INITIALLY DEFERRED` (verificado em `pg_trigger`). O que é
validado é o estado no fim da transação.

---

### 4.2 `crm_set_owner(p_opportunity_id uuid, p_owner_profile_id uuid)`

1. Guarda comum.
2. `p_owner_profile_id` precisa existir em `crm.tenant_memberships` com
   `status = 'active'` **no mesmo tenant** -> senão `CRM_INVALID_OWNER`.
   (A FK composta rejeitaria de qualquer forma; a RPC antecipa a mensagem.)
3. `update crm.opportunities set owner_profile_id = …, updated_at = now()`.

`p_owner_profile_id = null` limpa o dono. Não mexe em `stage_version`:
atribuir dono não é movimento de etapa.

Hoje: **0 das 240 oportunidades têm dono.** Toda atribuição será a primeira.

---

### 4.3 `crm_register_won(p_opportunity_id uuid, p_evidence text, p_expected_stage_version integer, p_value numeric default null, p_currency text default 'BRL')`

1. Guarda comum + checagem de `stage_version` (`CRM_STAGE_CONFLICT`).
2. Origem já terminal -> `CRM_TERMINAL`.
3. `btrim(p_evidence) = ''` -> `CRM_EVIDENCE_REQUIRED`.
4. Resolver o par valor/estado — **esta é a invariante que mais importa**:

   | Entrada | Grava |
   |---|---|
   | `p_value is null` | `value = null`, `value_status = 'pending'`, `currency = null` |
   | `p_value > 0` | `value = p_value`, `value_status = 'valid'`, `currency = p_currency` |
   | `p_value <= 0` | `CRM_INVALID_VALUE` |

   **Valor ausente permanece pendente, nunca zero.** A RPC não tem caminho
   que produza `value = 0`; `p_value = 0` é rejeitado antes de chegar ao
   `CHECK`, para o atendente ver uma mensagem em vez de um `23514`.

5. `insert` em `crm.opportunity_stage_history` para `ganho`,
   `transition_type = 'manual'`, `origin = 'manual'`.
6. `update crm.opportunities`: `current_stage_id` = ganho, `status = 'won'`,
   `closed_at = now()`, `stage_version + 1`.
7. `insert` em `crm.commercial_outcomes`: `outcome = 'won'`,
   `origin = 'manual'`, `evidence = p_evidence`, `is_current = true`,
   `actor_profile_id = auth.uid()`.
8. Marco `sale` em `crm.opportunity_milestones`; mais `revenue` quando o
   valor veio informado.

⚠️ **O passo 3 não está na descrição do IMP-207.**
`validate_commercial_outcome` exige `evidence` não-vazio para **todo**
outcome com `origin = 'manual'` — inclusive Ganho, não só Perdido. Sem o
campo de observação na tela, todo Ganho é recusado pelo banco. Decisão do
Caio em 18/09: campo curto, livre e obrigatório no modal.

---

### 4.4 `crm_register_lost(p_opportunity_id uuid, p_loss_reason_code text, p_expected_stage_version integer, p_note text default null)`

1. Guarda comum + `stage_version`.
2. Origem já terminal -> `CRM_TERMINAL`.
3. `p_loss_reason_code` resolvido em `crm.canonical_loss_reasons` com
   `active = true` -> senão `CRM_INVALID_REASON`.
4. `requires_note` verdadeiro (só `outro`) e `btrim(p_note) = ''` ->
   `CRM_NOTE_REQUIRED`.
5. `evidence` do outcome = `p_note` quando houver, senão o `label` do
   motivo — porque `origin = 'manual'` exige `evidence` não-vazio também
   aqui.
6. `insert` no histórico para `perdido`, `update` da oportunidade
   (`status = 'lost'`, `closed_at`, `stage_version + 1`), `insert` do outcome
   com `outcome = 'lost'`, `loss_reason_id`, **`value_status = 'pending'` e
   `value = null`**.

⚠️ `commercial_outcomes_check2`: **perda obriga `value_status = 'pending'`.**
Não existe Perdido com valor. A RPC não recebe valor.

---

### 4.5 Erros que o frontend trata

Mensagens com prefixo estável, para a tela poder distinguir sem parsear
texto livre:

| Prefixo | Significado na tela |
|---|---|
| `CRM_FORBIDDEN` | `viewer` ou sem acesso. Não deveria acontecer: os botões já ficam escondidos. Rede de segurança |
| `CRM_STAGE_CONFLICT` | Outro atendente moveu antes. Recarrega o card e avisa |
| `CRM_TERMINAL` | Já está em Ganho/Perdido |
| `CRM_USE_OUTCOME_RPC` | Erro de programação, não de uso |
| `CRM_REASON_REQUIRED` | Abre o campo de motivo da regressão |
| `CRM_EVIDENCE_REQUIRED` | Foca o campo de observação |
| `CRM_NOTE_REQUIRED` | Motivo `outro` sem nota |
| `CRM_INVALID_VALUE` / `CRM_INVALID_REASON` / `CRM_INVALID_OWNER` | Entrada inválida |
| `23514` | `CHECK` do banco que escapou da RPC. Tratado como erro genérico e **reportado**, porque significa que a RPC deixou passar algo |

---

## 5. As invariantes, e onde cada uma aparece

Todas verificadas em `pg_constraint` e `pg_trigger` em 18/09.

| Invariante | Onde o banco impõe | O que a tela faz |
|---|---|---|
| Valor ausente é pendente, nunca zero | `commercial_outcomes_check1` | Campo de valor opcional; vazio manda `null`. Não existe caminho para `0` |
| Perda não tem valor | `commercial_outcomes_check2` | Modal de perda não tem campo de valor |
| Perdido referencia 1 dos 9 motivos | `commercial_outcomes_check` + FK | Select fechado, sem texto livre. `outro` abre a nota |
| Outcome manual exige evidência | `validate_commercial_outcome` | Observação obrigatória no Ganho **e** na Perda |
| Ganho e Perdido são terminais | `global_pipeline_stages_check`, `validate_opportunity` | Card terminal não tem botão de mover. **Sem reabrir neste sprint** |
| Regressão manual exige motivo | `validate_stage_history` | Mover para trás abre o campo de motivo |
| Histórico é append-only | 3 triggers `reject_append_only_mutation` | A tela só lê |
| `viewer` não escreve | `validate_stage_history` e `validate_commercial_outcome`, ambos lendo **`public.client_users`** | `v_crm_my_role_v1.can_write` esconde os botões |
| Etapa e status andam juntos | `validate_opportunity` | Nunca escritos separadamente — sempre pela mesma RPC |
| Etapa bate com o último histórico | `opportunities_validate_latest_history` (deferred) | Histórico e `update` na mesma transação |

### Fora de escopo, e por quê

**Reabrir uma oportunidade terminal.** Sair de Ganho/Perdido exige aposentar
o outcome corrente (`is_current = false`, única alteração que
`restrict_outcome_revision` permite), reabrir a oportunidade e inserir uma
transição de compensação. É uma quinta função, e não está no escopo travado
do IMP-206/207. Fica registrado como a próxima peça natural.

---

## 6. Como validar que está certo

```sql
-- 1. As 6 colunas aparecem para todo cliente, inclusive zeradas
select client_id, stage_code, opportunities
  from public.v_crm_board_counts_v1
 order by client_id, stage_position;
-- esperado hoje: 6 linhas por cliente; atendimento 239, lead 1, resto 0

-- 2. O join de atribuição não duplica card
select (select count(*) from public.v_crm_cards_v1) as cards,
       (select count(*) from crm.opportunities)     as oportunidades;
-- os dois números têm que ser iguais. Diferentes = distinct on faltando

-- 3. A contagem da view bate com a tabela
select sum(opportunities) from public.v_crm_board_counts_v1;
-- igual ao count(*) de crm.opportunities

-- 4. A RLS corta de verdade
--    logado como o viewer de royal_odontologia, v_crm_cards_v1 não pode
--    devolver nenhuma linha de marcos_quickclean

-- 5. can_write reflete client_users, não tenant_memberships
select * from public.v_crm_my_role_v1;
```

E o teste que fecha o IMP-207: levar uma oportunidade de `lead` até `ganho`
com valor e observação, e outra até `perdido` com motivo `outro` e nota,
**sem abrir o GHL** — conferindo que `opportunity_milestones` e
`opportunity_stage_history` ganharam linha e nenhuma perdeu.

---

## 7. Resumo do que precisa ser criado

```
crm.profiles.display_name        update nas 6 linhas          <- bloqueia IMP-207

public.v_crm_board_counts_v1     view, security_invoker
public.v_crm_cards_v1            view, security_invoker
public.v_crm_contacts_v1         view, security_invoker
public.v_crm_card_history_v1     view, security_invoker
public.v_crm_activities_v1       view, security_invoker
public.v_crm_owners_v1           view, security_invoker
public.v_crm_loss_reasons_v1     view, security_invoker
public.v_crm_my_role_v1          view, security_invoker

public.crm_move_stage()          função, security definer
public.crm_set_owner()           função, security definer
public.crm_register_won()        função, security definer
public.crm_register_lost()       função, security definer
```

Nenhuma alteração no schema `crm`. Nenhuma tabela nova. Nenhuma coluna nova.
`stage_version` já existe e está zerada nas 240 linhas — passa a ser usada
como trava otimista.
