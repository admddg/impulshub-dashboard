# ADR-0019 — Pipeline fixo; frases e rótulos configuráveis por cliente

- **Data:** 20/09/2026
- **Estado:** aceita
- **Decide:** Caio
- **Relaciona-se com:** ADR-0014 (arquivada, em `Impuls-Platform`), IMP-226, IMP-228

## Contexto

Com o CRM publicado, surgiu a pergunta de como atender um cliente que não é
clínica odontológica. A ideia levantada foi permitir personalizar o pipeline e
definir frases automáticas por etapa, numa tela de configuração.

A ADR-0014 já tinha decidido o essencial: pipeline global fixo de seis etapas
(Lead, Atendimento, Agendado, Compareceu, Ganho, Perdido), com frases
configuráveis por clínica. O que falhou naquela tentativa foi a execução: o
motor de frases do worktree `onda3` chegou a 19 commits, com auditoria,
reconciliação e views de exceção, e foi cancelado.

## O que foi medido

O quanto o restante do sistema assume um pipeline fixo, em produção, em
20/09/2026:

- **9 funções** com código de etapa escrito dentro: `crm.emit_opportunity_stage_event`,
  `crm.stevo_parse_messages`, `crm.validate_opportunity`, `public.crm_move_stage`,
  `crm_register_won`, `crm_register_lost` e três `get_meta_*_summary`
- **18 views**, entre elas o funil, a performance de campanha Meta e Google, o
  feed de eventos e a ponte de conversões
- **3 arquivos** do frontend: `lib/crm.ts`, `MoveActions.tsx` e `EventsTab.tsx`

Essas camadas dependem do **significado** de cada etapa: Agendado vira o evento
`Schedule` na Meta e Ganho vira `Purchase`. Etapa livre exigiria um mapa de
significado por etapa e a reescrita dessas 27 peças.

## Decisão

1. **O pipeline continua fixo, com as seis etapas.** Etapas livres, ordem
   diferente, etapa nova ou removida não serão feitas.

2. **Frases automáticas configuráveis por cliente, na versão enxuta**, dentro do
   IMP-226:
   - tabela `(cliente, etapa, frase)`, até cinco frases por etapa
   - o parser compara o texto normalizado (sem acento, caixa, pontuação nem
     espaço duplicado) de mensagens **enviadas por nós** com as frases do cliente
   - só move para frente, e só oportunidade aberta
   - origem `automatico`, pela mesma lógica de `crm_move_stage`
   - só **Atendimento, Agendado e Compareceu**. Ganho e Perdido ficam manuais:
     Ganho exige evidência e valor, Perdido exige motivo canônico
   - tela de configuração em `/agencia`, restrita à agência
   - sem regex, fuzzy, IA, auditoria de frases, reconciliação ou views de exceção

3. **Rótulos de etapa por cliente ficam no backlog (IMP-228), com gatilho:** o
   primeiro cliente fora de clínica, ou a decisão de tirar a QuickClean do GHL.
   Só o texto exibido muda; o `code` da etapa e o seu significado não. Funil e
   conversões continuam intactos.

## Por quê

Renomear resolve o que muda entre setores, que é o vocabulário. "Compareceu"
vira "Visita" e "Agendado" vira "Reunião marcada" sem que nenhuma das 27 peças
precise saber. Etapa livre resolveria um caso que ainda não existe, ao custo de
mexer no que sustenta o funil e as conversões.

Frases configuráveis custam pouco e destravam a automação para cada cliente sem
mudar código. O que torna o custo alto é a máquina de auditoria em volta, e ela
fica fora.

## Consequências

- **QuickClean passa a ser candidata a sair do GHL.** Deixou de ser "sem decisão
  comercial, fora do roteiro". Não é prioridade e depende do IMP-228. O Caio
  registrou que a preocupação principal com o processo dela era a estrutura de
  etapas, e o rótulo a resolve
- Etapas livres ficam recusadas. Só reabrem se **dois clientes** precisarem de
  estruturas diferentes do pipeline fixo, e aí o custo de referência são as 27
  peças acima
- A regra de normalização de frase tem como referência somente leitura
  `docs/phase-1/domain-rules-approved.md`, no repositório arquivado. O motor da
  onda3 **não** é reaproveitado
- O ponto sobre emitir `Purchase` enquanto o valor está pendente continua no
  IMP-217, para decisão quando aquela tarefa começar
