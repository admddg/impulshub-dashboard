# Prompt — IMP-212 rodada 2 (agente de front)

Continuação do IMP-212, mesma branch `feat/imp-206-crm-tab`. Três coisas: dois
ajustes pedidos depois de ver a tela, e um bloqueio seu que foi resolvido no
banco.

Seu relatório da rodada 1 foi aceito como está. O ponto (b) medido contra
produção — `.lte` devolvendo zero cards com o número dizendo 18 — foi exatamente
o risco que justificava o pedido. Mantenha esse padrão: medir, e separar o que
rodou do que não rodou.

---

## 1. Filtro de data vira preset

Hoje são dois campos `<input type="date">` soltos. Vira:

| Opção | Significa |
|---|---|
| **7 dias** | criados nos últimos 7 dias |
| **30 dias** | criados nos últimos 30 dias |
| **Personalizado** | mostra os dois campos de data manuais, como hoje |

**Instrução que importa:** os presets **só preenchem os mesmos `from` e `to`**
que você já usa. Não crie um segundo caminho de filtragem, não mande parâmetro
novo para a RPC, não mexa em `crm_board_counts`. Toda a lógica que você já
verificou — inclusive o `.lt()` do dia seguinte — fica intacta e continua valendo.

Os campos manuais só aparecem em "Personalizado". Nos presets, ficam escondidos.

**Uma decisão que é sua, com recomendação:** qual opção vem selecionada ao abrir
a aba. Recomendo **continuar sem filtro** ("Todos"), porque mudar o padrão muda o
que as pessoas veem ao abrir sem terem pedido — a Royal cairia de 177 para uma
fração em Atendimento e pareceria que sumiu dado. Se discordar, argumente no
relatório em vez de decidir em silêncio.

Continua valendo a aritmética de data em UTC que você documentou. Preset de 7
dias é `hoje - 7` em UTC, mesmo critério do resto.

---

## 2. Caixinhas de oportunidade maiores

A altura ficou uniforme — isso está resolvido e **não pode regredir**. O
problema agora é outro: o card está pequeno e apertado para o uso real.

Estado atual em `app/globals.css`:

```
.crm-card-open   min-height:76px, padding:10px 11px, justify-content:center
.crm-card-name   13px, line-clamp 1
.crm-card-ad     11px, white-space:nowrap + ellipsis  (uma linha só)
.crm-card-meta   11px
.crm-card-next   11.5px, padding:7px
```

O nome da campanha é a informação mais cortada — "ROYAL ODONTOLOGIA -
IMPLANTES …" não diz qual anúncio é.

**Alvo:**

```css
.crm-card-open{ height:120px; justify-content:flex-start; padding:13px 14px }
.crm-card-name{ font-size:15px; line-height:1.3 }          /* segue clamp 1 */
.crm-card-ad{ display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical;
              white-space:normal; font-size:12.5px; line-height:1.35; margin-top:6px }
.crm-card-meta{ font-size:12px; margin-top:auto }          /* cola no rodapé */
.crm-card-next{ font-size:12.5px; padding:10px }
```

**O detalhe técnico que decide tudo:** trocar `min-height` por **`height` fixo**.
Com o nome da campanha podendo ocupar uma ou duas linhas, `min-height` faz os
cards voltarem a ter alturas diferentes — seria desfazer a correção da rodada 1.
Com `height` fixo mais `margin-top:auto` no meta, card curto e card longo ocupam
o mesmo espaço e a última linha fica alinhada nos dois.

Os números são ponto de partida. Se encontrar proporção melhor, use — o critério
de aceite é o resultado, não o valor exato:

1. Todos os cards de uma coluna com **exatamente** a mesma altura, na Royal
2. Nome da campanha legível em até duas linhas, truncado com reticências só
   depois disso
3. Nada cortado no meio de uma linha de texto

**Contrapartida que você deve conferir:** card maior significa menos card por
tela. A coluna pagina de 20 em 20 (`TAMANHO_COLUNA`), então não deve incomodar —
mas olhe a Royal em Atendimento e diga no relatório se ficou pesado para rolar.

---

## 3. Bloqueio resolvido: filtros na visão de lista

Você reportou que `v_crm_contacts_v1` não expunha `opened_at` nem
`owner_profile_id`, e resolveu com um aviso na tela. A escolha foi certa — não
fingir que o filtro estava aplicado.

**A view foi alterada.** As duas colunas agora existem, vindas do mesmo
`LEFT JOIN LATERAL` que já estava lá, sem junção nova. Migration
`20260925000003_crm_contacts_view_filters.sql`.

Então:

- Aplique os dois filtros também na visão de lista, com a **mesma semântica** do
  kanban (`.lt()` no dia seguinte, `.is(null)` para sem proprietário)
- **Remova o aviso** de "filtro não se aplica aqui"
- Atenção: `opened_at` e `owner_profile_id` vêm da **oportunidade mais recente**
  do contato, não do contato. Contato sem oportunidade tem os dois nulos e some
  quando houver filtro de data. É o comportamento certo — filtro de "criado em"
  só faz sentido para quem tem oportunidade — mas registre no relatório se achar
  que deveria ser outro.

Confira que a view atualizada já está no banco antes de começar (a coluna tem
que aparecer em `v_crm_contacts_v1`). Se não estiver, pare e avise.

---

## Fora de escopo — continua valendo

Dois proprietários (CRC/Vendas), tirar agência do seletor, arrastar card,
qualquer migration nova.

## Como entregar

Commits pequenos na branch, um por item. `npx tsc --noEmit` e `npm run build`
limpos. **Sem push, sem merge para `main`.**

No relatório, o mesmo formato da rodada 1: o que verificou rodando, o que não
verificou, e qualquer número que não bateu.
