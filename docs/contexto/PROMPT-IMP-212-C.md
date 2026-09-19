# Prompt — IMP-212 rodada 3 (agente de front)

Mesma branch `feat/imp-206-crm-tab`. **Um item só.** Os filtros estão aprovados
e não devem ser tocados.

## O que está errado

A caixinha de oportunidade está com o texto **fatiado na horizontal**. Em Royal
e Central, a linha de rodapé do card ("Sem proprietário · 18/09/26") aparece
cortada ao meio, e na Central os cards viraram tiras com o nome serrado.

**A causa é a correção da rodada 2.** Trocar `min-height` por `height:120px`
resolveu a uniformidade e criou coisa pior: altura fixa com `overflow:hidden`
não empurra o excesso, ela **corta no meio da linha de texto**. O card anterior
crescia — feio, mas legível. O atual guilhotina.

Isto é terceira rodada no mesmo defeito. Leia a seção "Por que isso se repetiu"
antes de escrever CSS.

## A causa real não é CSS — é o componente

Antes de mexer em `globals.css`, olhe `components/crm/KanbanColumn.tsx:113-138`.
**Dois elementos do card são condicionais e podem não existir no DOM:**

```tsx
{card.campaign_name && (
  <span className="crm-card-ad" …>{card.campaign_name}</span>
)}
…
{canWrite && nextStage && !card.is_terminal && (
  <button className="crm-card-next" …>
)}
```

Nenhuma regra de CSS alcança um elemento ausente. Por isso as rodadas 1 e 2
falharam: ajustar `.crm-card-ad` não faz nada no card que não tem campanha.

Formas diferentes que o card assume hoje:

| Situação | O que some |
|---|---|
| Oportunidade sem `campaign_name` | A linha do anúncio |
| Etapas **Ganho** e **Perdido** (terminais) | O botão do rodapé |
| Etapa **Compareceu** (última não terminal) | O botão — não há próxima etapa |
| Usuário sem permissão de escrita | O botão |

> **Corrigido depois de medir:** esta seção dizia que os cards da Central não
> têm linha de campanha. Têm — todos os 14. E a estrutura condicional, embora
> real e digna de correção, **não era a causa principal.** Ver abaixo.

### A causa principal, medida no Chrome

```
.crm-card        altura  32px   flex-shrink 1   overflow hidden
.crm-card-open   altura 120px
```

`.crm-col-body` é um flex column com altura limitada pelo `max-height` da
coluna. **Item flex tem `flex-shrink:1` por omissão**, então o Chrome comprime
cada card para caber em vez de deixar a coluna rolar — medido em **20px por
card** na Royal em Atendimento e **32px** na Central — e o `overflow:hidden` do
`.crm-card` corta o conteúdo de 120px no meio da linha. O body nem rolava:
`scrollHeight == offsetHeight` nas quatro colunas com card.

A correção de primeira ordem é `.crm-card{flex:0 0 auto}`. Sem encolher, a
coluna transborda e o `overflow-y:auto` do body faz o que devia fazer desde o
início. As duas correções abaixo continuam necessárias, mas sozinhas não
resolveriam: com `flex-shrink` ativo, `height:auto` também é comprimido.

## A correção

**Duas partes. A do componente vem primeiro.**

**1. Torne a estrutura constante.** O bloco de conteúdo do card
(nome + anúncio + rodapé) deve renderizar **sempre os três elementos**,
independentemente de haver campanha. Sem campanha, o elemento existe vazio e
ocupa a linha reservada. Trate isso no TSX, não no CSS.

O botão de avançar é caso diferente e legítimo: em Ganho e Perdido ele não deve
existir mesmo. A regra correta é **uniformidade dentro da coluna**, não entre
colunas — ver critério de aceite.

**2. Reserve linha, não limite pixel.** O erro conceitual da rodada 2 foi
`height:120px` no contêiner: altura fixa com `overflow:hidden` não empurra o
excesso, ela corta no meio da linha. Cada bloco de texto deve declarar quantas
linhas ocupa, e a altura do card vira a soma.

```css
.crm-card-open{ height:auto; padding:13px 14px }        /* sem height fixo */
.crm-card-name{ height:1.3em;  line-height:1.3;  -webkit-line-clamp:1 }
.crm-card-ad  { height:2.7em;  line-height:1.35; -webkit-line-clamp:2; margin-top:6px }
.crm-card-meta{ height:1.4em;  line-height:1.4;  white-space:nowrap;
                overflow:hidden; text-overflow:ellipsis }
```

Emoji no nome deixa de quebrar, porque a linha tem altura declarada em vez de
herdada da métrica da fonte — há nomes com emoji na Royal.

Os valores são ponto de partida. O que não é negociável são os dois princípios:
**estrutura constante no DOM** e **nenhuma altura fixa em pixel num contêiner
cujo conteúdo é texto.**

## Onde testar — dado real medido em 19/09

| Cliente | Lead | Atend. | Agend. | Compar. | Ganho | Perdido | Sem campanha |
|---|---|---|---|---|---|---|---|
| Royal Odontologia | 4 | 182 | 0 | 0 | 0 | 0 | **3** |
| Marcos QuickClean | 0 | 92 | 0 | 0 | 0 | 0 | **1** |
| Central - Gama | 14 | 0 | 0 | 0 | 0 | 0 | 0 |
| ImpulsHub | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

**Tem que valer para os três clientes com dado.** Não teste só na Royal.

Dois casos que o dado real esconde:

**1. Os 4 cards sem campanha** (3 na Royal, 1 na QuickClean) são a variante
estrutural que quebra hoje — e são raros demais para aparecer por acaso.
Encontre-os e confira que ficam da mesma altura dos vizinhos.

**2. Agendado, Compareceu, Ganho e Perdido estão zerados em todos os clientes.**
Não há como observá-los com dado real, e são justamente os que não têm o botão
do rodapé. Faça a estrutura ser correta por construção nesses casos e **diga no
relatório que não pôde observar** — não declare verificado.

### Por que a Central está pior que a Royal

Não é falta de campanha — todos os 14 cards da Central têm. É **emoji composto
no nome**: `Matheus Ruan 🏴‍☠️` e `Antônio 👨🏽‍🌾` usam sequências com
zero-width joiner, que inflam a caixa de linha muito além do `line-height`
herdado. Com altura fixa e `overflow:hidden`, o card estoura e fatia tudo.

Declarar `height` na linha do nome resolve isso. Confira nesses dois contatos
especificamente.

## Critério de aceite — cole a saída no relatório

Rode no console com o kanban aberto, **nos três clientes que têm dado**:

> ⚠️ **A primeira versão deste script aprovava a tela quebrada.** Ela media
> `.crm-card-open`, que reportava 120px e zero cortes enquanto os cards
> estavam fatiados nas fotos. Quem é comprimido pelo `flex-shrink` da coluna é
> a caixa `.crm-card` em volta; o botão de dentro só informa a altura que
> *pediu*. A versão abaixo mede a caixa certa e separa **corte** de
> **truncagem** — ver a nota depois do bloco.

```js
// Mede a CAIXA do card (.crm-card), nao o botao de dentro (.crm-card-open).
const linhas = [...document.querySelectorAll('.crm-col')].map((col) => {
  const titulo = col.querySelector('.crm-col-name')?.innerText?.trim() ?? '?';
  const cards  = [...col.querySelectorAll('.crm-card')];
  const alturas = [...new Set(cards.map((c) => Math.round(c.offsetHeight)))];
  // DEFEITO: caixa menor que o conteudo. E o corte no meio da linha, sem
  // nenhum indicador visual. Tem que ser 0.
  const caixasCortadas = [...col.querySelectorAll('.crm-card,.crm-card-open')]
    .filter((e) => e.scrollHeight > e.clientHeight + 1).length;
  // ESPERADO: texto maior que a reserva de linhas. O line-clamp poe
  // reticencias, entao isto e truncagem anunciada. NAO reprova.
  const truncados = [...col.querySelectorAll('.crm-card-name,.crm-card-ad,.crm-card-meta')]
    .filter((e) => e.scrollHeight > e.clientHeight + 1).length;
  const body = col.querySelector('.crm-col-body');
  return { coluna: titulo, cards: cards.length, alturas: alturas.join(','),
           caixasCortadas, truncados,
           rola: body.scrollHeight > body.offsetHeight + 1 };
}).filter((l) => l.cards > 0);
console.table(linhas);
```

**Passa quando, em toda coluna que tem card:** `alturas` mostra **um único
valor** e `caixasCortadas = 0`. Vale para os três clientes.

**`truncados` não reprova.** É texto que excedeu a reserva de linhas e ganhou
reticências — comportamento correto. Confundir as duas coisas faz o critério
reprovar um nome longo que está certo e aprovar um card guilhotinado.

**`rola` é diagnóstico, não aprovação.** Numa coluna cheia, `rola: false`
significa que os cards foram comprimidos para caber em vez de a coluna
transbordar — foi exatamente o sintoma deste bug, com as quatro colunas com
card em `rola: false`. Numa coluna com poucos cards, `false` é normal.

O seletor da coluna pode não ser `.crm-col` — confira o nome real da classe em
`KanbanColumn.tsx` e ajuste antes de rodar. Se o título vier `?`, não é
problema; o que importa são os números.

Uniformidade é **dentro da coluna**, não entre colunas: Ganho e Perdido
legitimamente não têm o botão de avançar, então são mais baixos. Isso é
correto e esperado.

Não escreva "está correto". Cole a saída, dos três clientes.

### Como abrir a tela

Você precisa ver o resultado renderizado — sem isso este bug volta pela quarta
vez. Duas opções:

- **Preview da Vercel:** https://impulshub-painel-8wdqwdnt8-adm-9328s-projects.vercel.app
  (atualiza a cada push na branch)
- **Local:** `npm run dev` na pasta do projeto

Se não tiver credencial para passar do login, **pare e peça ao Caio** antes de
mexer no CSS. Entregar CSS sem ver a tela é o que produziu as três rodadas.

## Por que isso se repetiu — leia antes de codar

Nos seus dois relatórios anteriores você escreveu, corretamente e com honestidade:

> "Tudo que é visual está correto por construção, não por observação."

Essa frase é o diagnóstico. Compare os dois resultados da rodada 2:

- **Filtro de data: acertou de primeira.** Porque era mensurável — você comparou
  164 contra 146 e provou qual predicado estava certo.
- **Card: errou, de novo.** Porque ninguém mediu nada. Só olhou o CSS e achou
  que estava bom.

A diferença não foi cuidado, foi **medição**. Layout some por causa de um emoji,
de uma fonte, de uma linha a mais — nada disso aparece lendo o arquivo.

**Regra a partir de agora:** requisito visual só é considerado entregue com um
número que o comprove. Se você não consegue pensar em como medir um requisito
visual, diga isso no relatório em vez de declarar que está pronto.

## Fora de escopo

Não toque nos filtros, nos presets, na visão de lista nem em nada de banco.
Dois proprietários, seletor sem agência e arrastar card continuam fora.

## Entrega

Um commit. `npx tsc --noEmit` limpo.

**Não rode `npm run build` com o `npm run dev` ligado na mesma pasta** — o build
de produção sobrescreve o `.next` que o dev server tem aberto e derruba o
servidor com 404 em todos os arquivos estáticos. Aconteceu hoje. Pare o dev
antes, ou valide só com `tsc --noEmit`.

Sem push e sem merge para `main`.
