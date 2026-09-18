# ImpulsHub — Comece aqui

> Este é o ponto de entrada do projeto. Se você é um Claude retomando o
> trabalho, leia este arquivo inteiro antes de qualquer coisa. Os demais
> arquivos são referência, consultados conforme a necessidade.

---

## O que é o projeto

Dashboard de marketing odontológico multi-cliente, feito por uma agência
para seus clientes acompanharem resultados reais — do investimento em
mídia até a venda no CRM.

**Stack:** Next.js 14 (App Router, TypeScript) + Supabase/Postgres + Recharts.
**Deploy:** Vercel, auto-deploy via push no GitHub.
**Domínio:** `painel.impulshub.com.br`

**Divisão de trabalho:** o usuário (Caio) cuida do banco de dados e dos
workflows n8n com outro colaborador. **Comigo, ele trabalha exclusivamente
o frontend.** Isso significa que mudanças de banco chegam prontas, via
documento ou contrato, e meu papel é consumir essas fontes corretamente —
nunca recriar a lógica delas.

---

## As 5 regras que não se quebram

Estas nasceram de erros reais cometidos neste projeto. Cada uma custou
tempo de investigação.

### 1. O frontend não recria metodologia do banco

Nunca recalcular no cliente: atribuição, deduplicação de leads, estágio de
jornada, vendas, receita, CAC, ROAS, vínculo de criativo. Se o número não
vem pronto do banco, a resposta certa é pedir ao time de banco — não
inventar a conta em JavaScript.

**Como isso deu errado:** reconstruí a lógica de coorte de memória dentro de
RPCs que criei, sem saber que ela já existia diferente no banco. Resultado:
duas metodologias divergentes em produção, uma investigação de horas que
nunca fechou, e todo aquele trabalho descartado.

### 2. Nunca buscar linhas cruas para o navegador quando o volume pode crescer

O PostgREST/Supabase **corta a resposta acima de ~1.000 linhas sem erro
nenhum**. O sintoma é número errado, silenciosamente. Sempre agregar no
banco (view ou RPC) ou paginar explicitamente.

**Como isso deu errado:** este mesmo bug apareceu **quatro vezes** em abas
diferentes. Ver `04_HISTORICO_E_LICOES.md` — é a lição mais cara do projeto.

### 3. Confirmar colunas no banco antes de escrever query

Nunca assumir que uma coluna existe por lembrança ou por analogia com outra
view. Rodar `information_schema.columns` e confirmar.

**Como isso deu errado:** usei `video_id` numa função porque a tabela antiga
tinha — a view nova não tinha. Erro de sintaxe na hora de aplicar.

### 4. Validar antes de alterar, sempre

O usuário pediu explicitamente: **"preciso sempre validar os steps antes de
realizarmos alterações"**. Isso significa apresentar o plano, esperar aval,
e só então codificar. Vale especialmente para mudanças de metodologia ou
que afetem números visíveis ao cliente.

### 5. Número tecnicamente correto que comunica algo falso é pior que número nenhum

**Como isso apareceu:** CPA de R$ 22.547 por conta — matematicamente certo
(investimento ÷ 1 ganho rastreável), mas passava a mensagem de que a
campanha era péssima, quando o problema real era atribuição incompleta.
Decisão: remover a métrica até a base melhorar.

---

## Estado atual (17/07/2026)

**Versão publicada:** v24
**Banco:** metodologia V2 completa, 17 views canônicas, 2 RPCs de mídia
**Frontend:** 8 abas, todas consumindo fontes V2

**Abas:** Visão Geral · Funil · Canais · Meta Ads · Google Ads · Leads ·
Eventos · Diário (+ `/operacao`, painel interno da agência)

**Cliente piloto:** Royal Odontologia. Outros: `[TEMPLATE]` (dados
fictícios para demo), ImpulsHub, Central-Gama.

---

## Como trabalhar comigo neste projeto

**Ao pedir uma mudança de frontend:** eu leio o contrato de dados
(`02_CONTRATO_DE_DADOS.md`), confirmo se a fonte existe e tem as colunas
necessárias, apresento o plano, espero aval, implemento, valido o build,
e entrego o zip.

**Ao trazer um contrato/documento do time de banco:** eu leio, mapeio o
que muda no frontend, listo as decisões que preciso de você, e só depois
começo.

**Ao reportar um bug:** primeiro investigamos com queries no banco antes de
mexer em código. O padrão que funciona aqui é: hipótese → query que
confirma ou descarta → correção. Nunca chutar direto para o código.

**Ao entregar:** sempre um zip com build validado, e um resumo do que mudou
com os pontos que merecem teste especial.

---

## Mapa dos arquivos deste projeto

| Arquivo | Quando consultar |
|---|---|
| `00_COMECE_AQUI.md` | Sempre, primeiro |
| `01_CONCEITOS.md` | Antes de mexer em qualquer métrica ou número |
| `02_CONTRATO_DE_DADOS.md` | Antes de escrever qualquer query ou chamada de RPC |
| `03_ARQUITETURA_FRONTEND.md` | Ao mexer em componentes, rotas ou layout |
| `04_HISTORICO_E_LICOES.md` | Ao investigar bug, ou antes de decisão arquitetural |
| `05_AMBIENTE_E_PUBLICACAO.md` | Ao empacotar, buildar ou publicar |
