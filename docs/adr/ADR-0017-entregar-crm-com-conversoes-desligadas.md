# ADR-0017 — Entregar o CRM com conversões desligadas

**Data:** 19/09/2026
**Status:** aceito
**Decide:** Caio

## Contexto

O sprint 22/09 → 09/10 foi aberto para entregar um CRM que não dependa do GHL,
a tempo do quinto cliente. O núcleo ficou pronto em um dia: schema `crm` com
RLS, parser do Stevo, views e RPCs públicas, e a aba CRM no painel.

Uma auditoria independente em 19/09 apontou 13 pontos. Conferidos contra o banco
de produção, três mostraram que **o caminho de conversão sem GHL não existe
ponta a ponta**:

1. **Ninguém consome a `conversion_outbox`.** 512 linhas `pending` paradas — 326
   de `google_ads` desde 24/08 e 186 de `meta` desde 10/09 — enquanto linhas
   `sent` continuam fluindo. Só existe um cron no banco (`crm-stevo-parser`).
   O workflow n8n `1.1` grava a linha *e* chama o `1.2`/`1.3` na mesma execução;
   o que não é entregue na hora fica pendente para sempre. A outbox é um
   registro, não uma fila.

2. **A ponte exige `ghl_location_id`** e lança exceção se estiver vazio. O
   cliente 5 não tem GHL. Com a flag ligada, **toda movimentação de card dele
   falharia** — pior do que não emitir conversão.

3. **Ganho é emitido antes do valor existir**, e o payload não tem campo de
   valor. O `Purchase` nasceria sem o valor da venda.

Some-se a isso que a ponte só cria job Meta, e cria job para etapas que o
contrato não declara elegíveis.

Nenhum desses pontos é regressão: a ponte foi construída para entrar inerte
(ADR-0015) e entrou. A auditoria mostrou que falta mais do que estava mapeado.

## Decisão

**O CRM é entregue com `clients_base.crm_emits_conversions = false` para todos
os clientes, incluindo o cliente 5.** O caminho de conversão pelo CRM é
corrigido depois da entrega, como prioridade 2 do sprint seguinte.

O cliente 5 entra com CRM, funil e canais funcionando sem GHL, e roda as
campanhas com o evento padrão da Meta nas primeiras semanas — como qualquer
conta nova.

## Por quê

O que faz o cliente 5 entrar não é a conversão pelo CRM: é ter CRM, funil e
canais sem depender do GHL. Isso está pronto.

Ligar conversão mal resolvida em conta nova é irreversível — evento enviado para
a Conversions API não volta. Já evitamos esse erro uma vez, quando a ponte foi
desenhada para entrar inerte em vez de duplicar as conversões que Royal,
QuickClean e Central já emitem pelo GHL (394 jobs em 7 dias).

E o custo de esperar é baixo: conta nova não tem histórico de otimização para
proteger.

## Consequências

- O cliente 5 fica sem otimização por conversão do CRM nas primeiras semanas.
  Aceito.
- A flag continua sendo a única chave. Nenhum cliente com GHL ativo pode
  ligá-la — os dois caminhos juntos duplicam conversão.
- Ligar depois sem replay produz um funil que começa no meio. Como tratar isso
  faz parte do IMP-219.
- As 512 linhas pendentes de agosto e setembro **não podem ser enviadas** quando
  o consumidor existir. Qualquer varredura precisa de corte por data ou escopo.

## Ordem de correção (Sprint 2)

Papéis antes de conversões, por decisão do Caio — sem a camada de permissão, o
atendente da clínica enxerga faturamento e investimento.

| # | Tarefa |
|---|---|
| 1 | IMP-213 — papéis e visibilidade por aba |
| 2 | IMP-214 — dois proprietários (CRC e Vendas) |
| 3 | IMP-215 — consumidor da `conversion_outbox` |
| 4 | IMP-216 — ponte sem `ghl_location_id` |
| 5 | IMP-217 — ganho/perdido com valor e motivo |
| 6 | IMP-218 — matriz evento × plataforma |
| 7 | IMP-219 — runbook de ativação canário |

Só depois de 3 a 7 a flag pode ser ligada para um cliente piloto.

## Aplicado ainda no sprint de entrega

Duas correções pequenas não esperaram, por serem baratas e por afetarem coisa
que já está em uso (IMP-211):

- `stage_version` passa a ser incrementado em qualquer troca de etapa. O parser
  promovia Lead → Atendimento sem mexer no número: 259 de 259 oportunidades em
  atendimento estavam na versão 0, e a trava otimista da tela estava cega.
- O ledger de migrations volta a bater com os arquivos do repositório, e
  `client_users_attendant_role` ganha o arquivo que nunca teve.
