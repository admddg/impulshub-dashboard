# Prompt — IMP-213 e IMP-214 (papéis, visibilidade e proprietários)

Etapa 3 do roteiro. Leia [`docs/ROADMAP.md`](../ROADMAP.md) e
[`AGENTS.md`](../../AGENTS.md) antes de começar.

Repositório `admddg/impulshub-dashboard`, pasta
`C:\Users\caiop\ImpulsHub\App-Impuls-Legado\impuls-app-v10-1-1`.
Branch nova a partir de `main`, uma por tarefa.

---

## O problema, medido — não suposto

Simulei o JWT do usuário `Atendimento Central`
(`bb04435c-fabb-4ba8-b5b5-e0175d9ca17d`, papel `attendant` na Central) contra o
banco de produção em 20/09:

```sql
set local role authenticated;
set local request.jwt.claims = '{"sub":"bb04435c-...","role":"authenticated"}';
select count(*) from public.get_client_overview_v2('19c9d8c6-...', ..., ...);
-- devolveu 1 linha
```

**O atendente lê o overview inteiro.** E o que essa função devolve inclui:

```
investment, acquisition_revenue, total_cohort_revenue, closed_revenue,
cpl_paid, cac_acquisition, roas_acquisition, roas_total_cohort
```

Faturamento, investimento, CAC e ROAS. Tudo.

**A causa:** `get_client_overview_v2`, `get_meta_ads_summary_v2` e
`get_google_ads_summary_v2` são `SECURITY INVOKER` e estão liberadas para
`authenticated`. A proteção depende inteiramente da RLS das tabelas por baixo —
e a RLS é por **pertencer ao cliente**, não por papel. Quem é membro, vê.

Esconder no frontend não resolve: a função é alcançável direto pelo PostgREST
com o token do próprio usuário.

---

## IMP-213 — Papéis e visibilidade por aba

### O que se quer

| Papel | Vê |
|---|---|
| Dono / gestor da clínica | Tudo: faturamento, investimento, ROI, CRM, funil, canais |
| **Atendente** | **Só CRM, funil e canais — não vê dinheiro** |
| Agência | Tudo, em todas as contas, + painel interno |

### A primeira decisão: existem dois vocabulários de papel

```
public.client_users.role        owner, admin, viewer, agency, attendant
crm.tenant_memberships.role     owner, admin, manager, attendant, integration, viewer
```

Sobrepostos e não equivalentes. **Parte do trabalho é decidir qual é a
autoridade e reconciliar.** Registre a decisão em ADR antes de implementar — a
série local começa em `docs/adr/`, próxima é a ADR-0018.

Estado real em 20/09, para a decisão não ser no vácuo:

| Cliente | Usuário | `client_users.role` | `tenant_memberships.role` |
|---|---|---|---|
| Royal | Caio, Igor | `agency` | `admin` |
| Royal | Royal Odontologia | `viewer` | `viewer` |
| Central | Caio, Igor | `agency` | `admin` |
| Central | Atendimento Central | `attendant` | `attendant` |
| Central | Central - Gama | `viewer` | `viewer` |
| QuickClean | Marcos | `viewer` | `viewer` |
| ImpulsHub | Caio, Igor | `agency` | `admin` |

Repare: **hoje ninguém tem papel de "dono da clínica"** — as contas de clínica
são `viewer`. O modelo desejado precisa desse papel, e a migração de dados
precisa decidir o que `viewer` vira.

### Onde não pisar

Estes leitores comparam `client_users.role` **apenas contra `'viewer'`**:
`validate_stage_history`, `validate_commercial_outcome`, `crm_guard`,
`v_crm_my_role_v1`, `v_crm_owners_v1`, `crm.can_write`. O app pergunta só "sou
agência?" via `am_i_agency_user()`.

**Qualquer papel novo tem que ser conferido contra essa lista antes de entrar.**
Já quebramos o `client_users_role_check` uma vez adicionando papel sem conferir.

### Precedente a seguir

`am_i_agency_user()` é `SECURITY DEFINER` e funciona. `crm.can_write()` também —
foi criada para resolver exatamente este tipo de problema, quando a RLS de
`client_users` escondia os outros membros. Use o mesmo padrão: helper
`SECURITY DEFINER` com `search_path = ''`, e a função de leitura consulta o
helper.

⚠️ **As três funções financeiras servem o dashboard inteiro.** Mudar a
segurança delas sem cuidado tira o painel do ar para dono e agência. Teste os
três papéis, não só o atendente.

### Critério de aceite — negativo e medido

Simulando o JWT de um atendente, **contra o banco**, não pela interface:

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<profile do atendente>","role":"authenticated"}';

-- Tem que falhar ou devolver zero linhas:
select * from public.get_client_overview_v2('<client_id>', '2026-08-01', '2026-09-20');
select * from public.get_meta_ads_summary_v2('<client_id>', '2026-08-01', '2026-09-20', 'campaign');
select * from public.get_google_ads_summary_v2('<client_id>', '2026-08-01', '2026-09-20', 'campaign');

-- Tem que continuar funcionando:
select count(*) from public.v_crm_cards_v1 where client_id = '<client_id>';

rollback;
```

E o mesmo bloco com o JWT do **dono** e da **agência** tem que devolver os
números normalmente. **Cole as seis saídas no relatório.**

### O que sai quando isto entrar

`components/DashboardClient.tsx` tem uma trava temporária: a aba CRM só aparece
para a agência (`const abas = ehAgencia ? TABS : ...`). Foi posta porque Royal,
Central e QuickClean operam no GHL e o kanban não é a verdade delas.

**Substitua por visibilidade por papel**, mas mantenha o efeito: quem opera no
GHL não deve ver a aba CRM. Se a nova camada não cobrir isso, deixe a trava.

---

## IMP-214 — Dois proprietários por oportunidade

Depende de IMP-213. Só comece depois que os papéis estiverem decididos.

**O modelo real das clínicas:** cada oportunidade tem até dois responsáveis —
**Proprietário CRC** (quem atende) e **Proprietário Vendas** (quem fecha).

**Regra do seletor:** mostra **apenas usuário operacional da clínica**. Nunca
agência (Caio, Igor), nunca gestor ou dono.

### O que muda

1. `crm.opportunities` ganha duas colunas de proprietário no lugar de
   `owner_profile_id`, com FK composta por `tenant_id` como o resto do schema
2. Papel para quem fecha — hoje existe `attendant`, falta o equivalente de vendas
3. **Separar "pode escrever" de "pode ser proprietário"** — são coisas
   diferentes. Caio e Igor precisam continuar podendo mover card (suporte), mas
   não devem aparecer como proprietário
4. `v_crm_owners_v1` passa a filtrar por papel operacional
5. Front: dois seletores no card; o filtro de proprietário pergunta "CRC ou
   Vendas?"
6. Migração: o `owner_profile_id` atual vira CRC

### Um aviso sobre o dado

Hoje **nenhuma das 297 oportunidades tem proprietário** — `owner_profile_id` é
nulo em todas. O filtro por proprietário nunca foi verificado contra conjunto
não-vazio: o teste deu `0 = 0`, o que não prova nada.

Atribua alguém antes de testar, senão você valida contra o vazio de novo.

---

## Fora de escopo

Inbox, envio de mensagem, automações, conversões, arrastar card. Nada de
`crm_emits_conversions` — a flag fica `false` nos 6 clientes.

## Regras

- **Escrita em produção exige o Caio:** DDL, migration, flag, merge, deploy
- Revisão independente obrigatória: isto mexe em RLS e em `SECURITY DEFINER`
- **Não rode `npm run build` com o `npm run dev` ligado na mesma pasta** — o
  build sobrescreve o `.next` do dev server e derruba o localhost com
  `Cannot find module './NNN.js'`. Valide com `npx tsc --noEmit`
- Uma IMP por branch, commits pequenos

## Relatório

Separe **verificado rodando** (com o número), **correto por construção mas não
testado**, e **o que não bateu**. Se não mediu, diga que não mediu.
