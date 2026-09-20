# Prompt — IMP-212 (agente de front)

Você vai ajustar a aba CRM do painel Impuls, que já está funcionando. São três
ajustes pedidos depois de ver a tela rodando com dados reais. Nenhum deles muda
o banco.

## Onde

- Repositório: `admddg/impulshub-dashboard`
- Pasta local: `C:\Users\caiop\ImpulsHub\App-Impuls-Legado\impuls-app-v10-1-1`
- **Branch: `feat/imp-206-crm-tab`** — continue nela, não abra outra
- Leia `AGENTS.md` na raiz antes de começar. Ele tem a regra que mais afeta seu
  trabalho: **o navegador não alcança o schema `crm` de jeito nenhum, nem para
  ler.** Toda leitura passa por views em `public`, toda escrita por funções em
  `public`. Se você precisar de um dado que não está numa view, isso é um
  bloqueio — avise em vez de contornar.

A premissa do projeto é **simplicidade e objetividade**: antes de cada decisão,
pergunte "estou indo pelo caminho mais simples que resolve?". Não refatore o que
está funcionando.

## Arquivos que importam

```
lib/crm.ts                      tipos, fetches e RPCs
components/tabs/CrmTab.tsx      estado da aba, orquestra tudo
components/crm/KanbanBoard.tsx  colunas
components/crm/KanbanColumn.tsx paginação por coluna
components/crm/ContactsList.tsx visão lista
components/crm/CardDrawer.tsx   card aberto
app/globals.css                 estilos (classes com prefixo crm-)
```

---

## Ajuste 1 — altura fixa do card (urgente)

**Problema:** `.crm-card-name` não tem line clamp. Nome longo quebra em duas
linhas, o card cresce, e o `overflow:hidden` corta o conteúdo. Na conta Royal a
coluna fica ilegível porque os cards têm alturas diferentes.

**Correção sugerida** (ajuste se encontrar coisa melhor, mas o resultado tem que
ser altura uniforme):

```css
.crm-card-open{ min-height:76px; display:flex; flex-direction:column; justify-content:center }
.crm-card-name{ display:-webkit-box; -webkit-line-clamp:1; -webkit-box-orient:vertical;
                overflow:hidden; word-break:break-word }
```

**Aceite:** com a Royal aberta, todos os cards de uma coluna têm a mesma altura,
e nome longo aparece truncado com reticências em vez de cortado no meio.

---

## Ajuste 2 — filtros (urgente)

A Royal tem mais de 3 mil leads no sistema legado. Sem filtro a tela não serve
para trabalhar.

**Dois filtros, no topo da aba, valendo para as duas visões (kanban e lista):**

1. **Criado em** — intervalo de datas sobre `opened_at`
2. **Proprietário** — um select, com uma opção "Sem proprietário"

### O que já existe no banco (não precisa criar nada)

Os cards vêm de `v_crm_cards_v1`, que já expõe `opened_at` e
`owner_profile_id`. A lista de proprietários vem de `v_crm_owners_v1`, já usada
por `fetchOwners(clientId)`.

A contagem no topo de cada coluna hoje vem de `v_crm_board_counts_v1`, que
**não aceita parâmetro**. Para filtro existe uma função pronta:

```
public.crm_board_counts(
  p_client_id        uuid,
  p_opened_from      date    default null,
  p_opened_to        date    default null,
  p_owner_profile_id uuid    default null,
  p_unassigned       boolean default false
) returns table (client_id, stage_code, stage_label, stage_position, is_terminal, opportunities)
```

Chamar via `supabase.rpc('crm_board_counts', {...})` — devolve array de linhas,
mesmo formato do tipo `BoardCount` que já existe em `lib/crm.ts`.

### Três detalhes que decidem se vai funcionar

**a) Use `crm_board_counts` sempre que houver filtro ativo.** Se continuar
usando a view, o número no topo da coluna conta o conjunto inteiro enquanto a
tela mostra o subconjunto. O atendente veria "Atendimento 173" com 12 cards na
tela e não saberia em qual acreditar. Sem filtro, a função devolve exatamente o
mesmo que a view — pode usar sempre, se preferir simplificar.

**b) A semântica da data final tem que ser idêntica nos dois lados.** A função
usa `o.opened_at < (p_opened_to + 1)::timestamptz`, ou seja, **inclui o dia
final inteiro**. Ao filtrar os cards em `fetchCards`, use `.lt('opened_at', <dia
seguinte>)`, não `.lte('opened_at', <dia final>)` — senão a contagem e os cards
divergem para quem foi criado ao longo do último dia.

**c) `p_unassigned` tem precedência sobre `p_owner_profile_id`.** Quando "Sem
proprietário" estiver marcado, mande `p_unassigned: true` e ignore o outro. No
lado dos cards, isso é `.is('owner_profile_id', null)`.

**Não esqueça:** mudar filtro tem que **zerar o offset de paginação** de todas
as colunas. `fetchCards` pagina por coluna com `.range(offset, offset+limit-1)`.

**Aceite:** com um filtro de data aplicado, o número no topo de cada coluna bate
exatamente com a quantidade de cards que dá para paginar naquela coluna. O mesmo
com filtro de proprietário. Os filtros valem também na visão de lista.

---

## Ajuste 3 — rótulo

Trocar **"Dono"** por **"Proprietário"** onde aparecer na interface
(`CardDrawer.tsx` tem "Dono" e "Sem dono"). Só o texto visível — não renomeie
variáveis, tipos nem colunas. `owner_profile_id` e `owner_name` continuam com
esse nome no código e no banco.

---

## Fora de escopo — não faça

- **Dois proprietários (CRC e Vendas).** Está planejado para o próximo sprint
  (IMP-214) e depende de uma mudança de papéis no banco que ainda não existe.
- **Tirar Caio e Igor do seletor de proprietário.** Mesmo motivo — exige
  distinguir agência de equipe operacional da clínica, que é IMP-213.
- **Arrastar card no kanban.** IMP-224, prioridade baixa, decisão consciente.
  Mover é pelo botão "Mover etapa".
- **Qualquer migration ou mudança de banco.** Se achar que precisa, pare e
  avise.

## Um achado que você pode encontrar

`components/tabs/LeadsTab.tsx` usa `className="badge"`, mas `.badge` **não
existe** em `app/globals.css` — a coluna Etapa e a de plataforma renderizam sem
estilo. É bug pré-existente da aba Leads, legado, **não é do CRM**. Se sobrar
tempo e for barato, pode corrigir; se não, deixe e reporte. Não deixe isso
atrasar os três ajustes acima.

## Como entregar

1. Commits pequenos na branch `feat/imp-206-crm-tab`, um por ajuste
2. `npm run build` tem que passar
3. Teste com **duas contas diferentes**, uma delas a Royal (volume alto)
4. **Não faça push nem merge para `main`** — o Caio publica

No relatório final, separe o que você **verificou rodando** do que **acredita
estar certo mas não testou**. Se algum número não bater, diga qual e por quê —
número errado em contagem é pior que ausência de contagem.
