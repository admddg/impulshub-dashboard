# IMP-226 — Normalização e matching de frases

> **Documento de especificação** — define a regra de normalização e de
> correspondência para as frases configuráveis por cliente (ADR-0019).
> Não é código, não é SQL. É o contrato de comportamento para a implementação
> do IMP-226.

## Contexto

No IMP-226, uma mensagem **enviada por nós** (pelo atendente) move o card de
etapa quando, depois de normalizada, ela contiver a frase configurada para
aquela etapa. O cliente pode configurar até 5 frases por etapa (Atendimento,
Agendado e Compareceu no escopo enxuto do sprint; Ganho e Perdido continuam
manuais).

Este documento especifica apenas **como** a mensagem e a frase são normalizadas
e **como** se decide se houve correspondência. Decisões de pipeline, matriz de
etapas, autoridade de configuração e auditoria são tratadas nas regras de
domínio (referência: `Impuls-Platform/docs/phase-1/domain-rules-approved.md`,
seção 10) e no ROADMAP.

## 1. Regra de normalização

A normalização é aplicada **tanto à mensagem enviada quanto à frase
configurada**, sempre na mesma ordem, antes de qualquer comparação. O texto
original permanece imutável para auditoria.

Passos, em ordem:

1. **Minúsculas** — toda a string é convertida para caixa baixa.
2. **Remover acentos** — caracteres com diacríticos (ex.: `á`, `ã`, `é`, `ç`,
   `ü`) são convertidos para a forma sem acento (`a`, `a`, `e`, `c`, `u`).
3. **Remover pontuação** — pontuação e símbolos são removidos. Isso inclui
   pontos, vírgulas, exclamações, interrogações, aspas, travessões, barras,
   dois-pontos, ponto e vírgula, parênteses, colchetes, chaves e
   cifrão/porcentagem/arroba etc. O que resta são letras, dígitos e espaços.
4. **Colapsar espaços** — sequências de espaços em branco (incluindo quebras de
   linha e tabs) viram um único espaço; espaços no início e no fim são
   removidos.
5. **Unicode NFKC** — a string é normalizada para a forma de compatibilidade
   NFKC. Isso resolve equivalências como ligaduras (`ﬁ` → `fi`), formas de
   largura total (１２３ → 123), e outras variantes compatíveis.

O resultado é a **forma canônica** usada na comparação.

## 2. Regra de correspondência (match)

- A mensagem normalizada deve **conter a frase normalizada como uma sequência
  completa de palavras inteiras, na mesma ordem**.
- **Não** é substring solta: `"agendado"` não pode casar dentro de
  `"desagendado"`, porque aí a palavra `agendado` não aparece inteira.
- A frase pode aparecer **no meio de uma mensagem maior** — não é necessário que
  a mensagem seja exatamente igual à frase.
- A comparação é feita sobre **palavras** (tokens separados por espaço após a
  normalização). Uma palavra normalizada é uma sequência contígua de letras
  e/ou dígitos.
- A frase normalizada deve ser encontrada como **palavras consecutivas** na
  mensagem normalizada, sem palavras entre elas.
- **Mensagem vazia** (ou que se torna vazia após normalização) **nunca** casa
  com nenhuma frase.
- Frase vazia ou que se torna vazia após normalização é **inválida** e não deve
  ser configurada (não gera correspondência).

## 3. Tabela de casos

Legenda: **casa?** = a mensagem (depois de normalizada) contém a frase
(normalizada) como sequência completa de palavras na ordem. `SIM` = casa,
`NÃO` = não casa.

### 3.1 Caixa, acentos e pontuação

| # | Mensagem enviada | Frase configurada | Casa? | Motivo |
|---|---|---|---|---|
| 1 | `agendado` | `agendado` | SIM | igual após normalização |
| 2 | `AGENDADO` | `agendado` | SIM | caixa alta normaliza para minúscula |
| 3 | `AgEnDaDo` | `agendado` | SIM | caixa mista normaliza |
| 4 | `agendado!` | `agendado` | SIM | exclamação é removida |
| 5 | `agendado.` | `agendado` | SIM | ponto final é removido |
| 6 | `já agendado` | `agendado` | SIM | acento em `já` não afeta `agendado`; frase no meio |
| 7 | `agendado para amanhã` | `agendado` | SIM | frase no início de texto maior |
| 8 | `está agendado sim` | `agendado` | SIM | frase no meio de texto maior |
| 9 | `agendado?` | `agendado` | SIM | interrogação removida |
| 10 | `"agendado"` | `agendado` | SIM | aspas removidas |
| 11 | `agendado - confirmado` | `agendado` | SIM | travessão removido |
| 12 | `tudo certo, agendado!` | `agendado` | SIM | vírgula, espaço e exclamação normalizados |

### 3.2 Espaços e formatação

| # | Mensagem enviada | Frase configurada | Casa? | Motivo |
|---|---|---|---|---|
| 13 | `agendado   confirmado` | `agendado confirmado` | SIM | espaços duplos colapsam |
| 14 | `  agendado  ` | `agendado` | SIM | espaços nas bordas removidos |
| 15 | `agendado\nconfirmado` | `agendado confirmado` | SIM | quebra de linha vira espaço |
| 16 | `agendado\tconfirmado` | `agendado confirmado` | SIM | tab vira espaço |
| 17 | `agendado  confirmado` | `agendado  confirmado` | SIM | espaços duplos na frase também colapsam |
| 18 | `agendado confirmado` | `agendado  confirmado` | SIM | frase com espaço duplo colapsa igual |

### 3.3 Palavra parcial e sequência

| # | Mensagem enviada | Frase configurada | Casa? | Motivo |
|---|---|---|---|---|
| 19 | `desagendado` | `agendado` | NÃO | palavra parcial: `agendado` não aparece inteira |
| 20 | `reagendado` | `agendado` | NÃO | palavra parcial dentro de outra palavra |
| 21 | `agendado amanhã` | `amanhã agendado` | NÃO | ordem invertida |
| 22 | `amanhã agendado` | `agendado amanhã` | NÃO | ordem invertida |
| 23 | `agendado para amanhã` | `amanhã` | SIM | palavra no meio de texto maior |
| 24 | `agendado para amanhã` | `agendado para` | SIM | sequência completa no início |
| 25 | `agendado para amanhã` | `para amanhã` | SIM | sequência completa no final |
| 26 | `agendado para amanhã` | `agendado amanhã` | NÃO | `para` entre as palavras — não são consecutivas |
| 27 | `agendado para amanhã` | `para agendado` | NÃO | ordem invertida |
| 28 | `não agendado` | `agendado` | SIM | negação não é interpretada (semântica fora de escopo) |

### 3.4 Unicode (NFKC) e emoji

| # | Mensagem enviada | Frase configurada | Casa? | Motivo |
|---|---|---|---|---|
| 29 | `eﬁciente` | `eficiente` | SIM | ligadura `ﬁ` normaliza para `fi` (NFKC) |
| 30 | `ａｇｅｎｄａｄｏ` | `agendado` | SIM | largura total normaliza para largura normal |
| 31 | `１２３` | `123` | SIM | dígitos de largura total normalizam (NFKC) |
| 32 | `agendado 👍` | `agendado` | SIM | emoji é removido (não é letra/dígito/espaço) |
| 33 | `agendado!👍` | `agendado` | SIM | emoji colado sem espaço também é removido |
| 34 | `👍agendado` | `agendado` | SIM | emoji no início é removido |
| 35 | `médico` | `medico` | SIM | acento removido em ambos |
| 36 | `coração` | `coracao` | SIM | acento removido |

### 3.5 Vazio, símbolos e bordas

| # | Mensagem enviada | Frase configurada | Casa? | Motivo |
|---|---|---|---|---|
| 37 | `` (vazia) | `agendado` | NÃO | mensagem vazia nunca casa |
| 38 | `   ` (só espaços) | `agendado` | NÃO | após normalização fica vazia |
| 39 | `!!!` | `agendado` | NÃO | só pontuação → vazia após normalização |
| 40 | `agendado` | `` (vazia) | NÃO | frase vazia é inválida, nunca casa |
| 41 | `R$ 1.234,56 agendado` | `agendado` | SIM | símbolos e pontuação removidos; frase presente |
| 42 | `agendado (confirmado)` | `agendado confirmado` | SIM | parênteses removidos; palavras ficam consecutivas |
| 43 | `agendado,confirmado` | `agendado confirmado` | SIM | vírgula sem espaço é removida; palavras ficam consecutivas |
| 44 | `tel: 1234-5678 agendado` | `agendado` | SIM | dois-pontos, hífen removidos; dígitos e frase presentes |

## 4. Fora de escopo

- **Regex** — não usar expressões regulares no matching.
- **Fuzzy matching** — sem tolerância a erros de digitação, distância de
  edição ou similaridade.
- **IA / embeddings** — sem modelos, semântica ou similaridade vetorial.
- **Auditoria de frases** — o histórico de versões das frases, quem mudou e
  quando, e a trilha de auditoria do matching são tratados fora desta
  especificação (regras de domínio / IMP-226).
- **Interpretação semântica** — negação, pergunta, hipótese ou contradição não
  são interpretadas. Se a sequência está presente, a regra pode ser aplicada
  (mesmo em `não agendado`).
- **Conteúdo não textual** — áudio, transcrição, legenda, imagem, documento e
  outras mídias não acionam frases.
- **Texto citado/encaminhado** — apenas texto novo escrito pelo atendente é
  avaliado.
- **Etapas Ganho e Perdido** — continuam manuais no escopo enxuto do IMP-226.

## 5. Critérios de aceite (para a implementação futura)

1. A ordem dos passos de normalização é exatamente a listada na seção 1.
2. O matching exige sequência completa de palavras inteiras, na ordem, sem
   palavras no meio.
3. Todos os 44 casos acima passam (ou falham) exatamente como indicado.
4. A mensagem e a frase originais ficam preservadas para auditoria.
