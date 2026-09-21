# Roteiro do ImpulsHub

**Atualizado em 21/09/2026.** Este arquivo é a fonte única de direção. Se outro
documento disser algo diferente, este vale.

---

## A decisão que define tudo

> **Royal, Central e QuickClean permanecem no GoHighLevel, definitivamente.**
> Não são alvo de migração. Servem como laboratório: aprendizado, modelagem e
> teste.
>
> **O sistema é construído para os clientes NOVOS.** Cliente novo entra 100% na
> nossa estrutura, sem GHL.
>
> **A Impuls é o primeiro cliente de verdade do sistema novo.** A agência usa o
> próprio sistema para vender, antes de qualquer cliente externo.

Por que isso importa: o projeto tentava construir um CRM **e** migrar quatro
operações com hábito formado em outra ferramenta. A segunda parte era a fonte de
quase toda a complexidade. Removê-la eliminou de uma vez o treino de equipe, a
necessidade de um inbox, e o risco de apagar conversão ao tirar o card do GHL.

**Não há data de entrega.** A data anterior era estimativa, não compromisso, e
estava produzindo pressa. O critério é a lista da seção "Porta de entrada".

---

## Onde estamos — medido em 20/09/2026

| Peça | Estado |
|---|---|
| Schema `crm`, 14 tabelas, RLS | ✅ produção |
| Parser do Stevo (`pg_cron`, 1 min) | ✅ produção |
| 15 migrations | ✅ produção, até `20260928000001` |
| Aba CRM (kanban, lista, card, filtros) | ✅ publicada em `main` (`c220687`) |
| Conversões pelo CRM | ⛔ desligadas, cadeia incompleta |
| Permissões por papel | ✅ aplicada na IMP-213; hotfix de isolamento do histórico aplicado e registrado |

**IMP-229 está aplicada e em observação até 23/09/2026.** As policies de leitura
usam `private.my_client_ids()` com alias explícito no consumo da função.
**IMP-213 está aplicada com o hotfix do histórico entre clientes.**

**Produção roda `793f72b`, com o painel atualizado.** A ponte de conversões continua inerte.

### Dados por cliente

| Cliente | Instância Stevo | Mensagens | Oportunidades | Papel |
|---|---|---:|---:|---|
| Royal Odontologia | `royal-closer`, `royal-comercial` | 3.308 | 189 | Laboratório, fica no GHL |
| Marcos QuickClean | `marcos-quick-clean` | 6.397 | 92 | **Candidata a sair do GHL** depois do IMP-228 (rótulos de etapa). Não é prioridade |
| Central - Gama | `central-gama-crc` | 137 | 16 | Laboratório, fica no GHL |
| ImpulsHub | **nenhuma** | **0** | **0** | Será a primeira operação própria |

Tenant interno da Impuls: `client_id 3ec294db-a64a-4420-9b4a-0d917f65d399`,
slug `impulshub`, tenant CRM existe, 2 usuários ativos. **"Impuls" e "ImpulsHub"
são o mesmo registro** — não há ambiguidade.

A Central tem volume baixo porque a equipe dela atende dentro do GHL; o que
chega aqui é a sobra. Não é defeito de captura.

---

## As cinco etapas

Uma de cada vez. **Não comece a seguinte antes de a anterior estar em uso.**

### 1 — Publicar o CRM · IMP-227 ✅ concluída
Merge de `feat/imp-206-crm-tab` para `main` concluído em `c220687`; o deploy é automático.

IMP-206, 207 e 212 foram fechadas junto com o IMP-227. O smoke foi executado
em produção após dois movimentos manuais na Central:

| Verificação | Resultado |
|---|---:|
| Eventos CRM em `events_normalized` | 0 |
| Eventos CRM em `events_raw` | 0 |
| Linhas CRM em `conversion_outbox` | 0 |
| Clientes com `crm_emits_conversions` ligada | 0 |
| Movimentos manuais após o deploy | 2 |

A variação da ponte foi zero. O smoke cobriu movimento de etapa; ganho e perda
ficam para avaliação na Etapa 2.

**A aba CRM só aparece para a agência.** Royal, Central e QuickClean operam no
GoHighLevel: as etapas que o parser calcula a partir do WhatsApp não são a
verdade da clínica. Mostrar esse kanban para quem trabalha no GHL cria a
pergunta "para onde eu olho?", e a resposta hoje é "para o GHL".

As três contas têm login de clínica — Royal (viewer), Central (attendant e
viewer) e QuickClean (viewer). Tirar Royal e Central do sistema não resolveria:
o Marcos veria o mesmo desencontro, e perderíamos o dado que serve de
laboratório.

É trava temporária, não permissão. Sai quando existir flag por cliente em
IMP-214/onboarding; a IMP-213 não libera o CRM para clínicas que ainda operam
no GHL.

**Pronto quando:** a aba CRM está em `painel.impulshub.com.br`, **não aparece
para um login de clínica**, e o smoke test prova **variação zero** em
`conversion_outbox` para `source_system = 'impuls_crm'` — conta antes, move um
card, conta depois, diferença exatamente zero.

### 2 — Avaliar em uso · IMP-224
O Caio opera o painel por alguns dias e anota o que incomoda. Uso real, não
revisão de código.

Pode mover card à vontade em Royal, Central e QuickClean: **nenhuma delas usa
nosso CRM para trabalhar**, então escrever aqui não afeta operação nenhuma.

**Pronto quando:** existe uma lista de incômodos vinda do uso, triada entre
"corrige agora" e "backlog". Não é para reabrir o que já funciona.

### 3 — Permissões e usuários · IMP-213, IMP-214
IMP-213 (papéis e visibilidade por aba) e IMP-214 (dois proprietários: CRC e
Vendas).

| Papel | Vê |
|---|---|
| Dono / gestor da clínica | Tudo: faturamento, investimento, ROI, CRM, funil, canais |
| Atendente | Só CRM, funil e canais — **não vê dinheiro** |
| Agência | Tudo, em todas as contas, + painel interno |

**Pronto quando:** um atendente logado não lê faturamento **nem pela API
direta**, e o seletor de proprietário mostra apenas usuários operacionais da
clínica — nunca agência, nunca gestor.

### 4 — Pipeline automatizada · IMP-225, IMP-226

**IMP-225 está concluída:** a Impuls foi conectada ao Stevo.
**IMP-226 fase 1 está em curso:** toda conversa individual nova abre card,
seja recebida ou iniciada por nós; grupos, LID e mensagens incompletas não abrem card.

**4A · IMP-225 (concluída):** conectar o WhatsApp comercial da Impuls a uma instância
Stevo. A conexão está feita; a fase 1 trata da abertura de cards em conversas individuais.

**4B · IMP-226:** regras do tipo **"chegou tal mensagem → move para tal etapa"**, com a frase **configurável por cliente** (ADR-0019): tabela `(cliente, etapa, frase)`, até 5 por etapa, só Atendimento, Agendado e Compareceu, tela em `/agencia` restrita à agência. Ganho e Perdido continuam manuais.

O mecanismo **já existe**: `crm.stevo_parse_messages` já move Lead →
Atendimento na primeira resposta. Regra nova é mais uma condição no mesmo lugar.
Dimensione como pequeno até que se prove o contrário.

**Fora de escopo, explicitamente:** envio de mensagem, follow-up, lembrete,
distribuição entre atendentes, inbox, campanhas.

**Pronto quando:** uma regra roda sozinha em conversa real da Impuls e o Caio
confia nela.

### 5 — Conversões e tracking · IMP-215 a IMP-219

O estado medido:

- **Ninguém consome a `conversion_outbox`.** 512 linhas `pending` paradas — 326
  de `google_ads` desde 24/08, 186 de `meta` desde 10/09. O n8n `1.1` grava a
  linha *e* entrega na mesma execução; o que não sai na hora fica pendente para
  sempre. **A outbox é um registro, não uma fila.**
- A ponte exige `ghl_location_id` e lança exceção se vazio — cliente sem GHL
  quebraria ao mover card.
- Ganho é emitido **antes de valor e moeda serem gravados.**
- Só cria job Meta; Google nunca recebe.

⚠️ **As 512 linhas pendentes não podem ser enviadas.** São de agosto e setembro.
Qualquer consumidor precisa de corte por data e por cliente — evento aceito pela
Conversions API não volta.

**Meta é o primeiro canário.** O Google não pode sumir em silêncio: antes de
encerrar a etapa, a IMP-218 precisa de decisão explícita — entra junto ou é
adiada com motivo escrito. O Google recebe conversão hoje (230 enviadas).

**Pronto quando:** mover um card na Impuls faz o evento aparecer no Gerenciador
de Eventos da Meta, e o runbook de ativação (IMP-219) existe.

---

## Porta de entrada do próximo cliente
Cliente novo só entra com tudo abaixo fechado:

- [ ] Sistema publicado e avaliado em uso
- [ ] Permissões por papel funcionando
- [ ] Automações de pipeline rodando
- [ ] Conversões e tracking rodando e revisados
- [ ] Runbook de onboarding (IMP-223) escrito e testado na Impuls

---

## Regras que não se quebram

- **Não ligue `crm_emits_conversions`** para nenhum cliente. Só o Caio, e só
  depois de IMP-215 a IMP-219. Hoje os 6 registros estão `false`
- **Exigem autorização do Caio:** push para branches compartilhadas, merge ou
  push em `main`, deploy, DDL, migrations, flags e escrita em dados de produção.
  **Merge e deploy de produção nunca são delegados implicitamente.** Push de
  feature branch para revisão não é escrita em produção
- A execução ocorre em uma única sessão, sem estrutura de coordenador,
  supervisor, executores ou subagentes. O agente implementa, mede e reporta;
  não aplica em produção, não faz merge e não aprova o próprio trabalho de
  risco médio ou alto.
- Mudanças de RLS, views ou funções `SECURITY DEFINER` exigem revisão
  independente em sessão separada do Claude Code. O Caio leva ao revisor o
  relatório e o diff e confirma a revisão antes de merge ou aplicação.
- Não trabalhe em `Impuls-Platform` nem em `Impuls-Platform-onda3` — arquivados
- **Não abra tarefa que não esteja ligada à etapa atual, a um cliente com
  problema, ou a um risco de perda irreversível.** Levantar risco e não agir é
  decisão válida. Registrar é obrigatório; corrigir não é

## Como entregar

Uma IMP por entrega, branch isolada, commits pequenos, a partir da próxima
entrega depois da publicação do CRM. A branch atual do CRM carrega IMP-206, 207
e 212 — exceção histórica já consolidada.

No relatório, **separe sempre**: o que foi **verificado rodando** com o número
medido, o que está **correto por construção mas não testado**, e o que **não
bateu** e por quê.

Requisito visual só conta como entregue com um número que o comprove. Um número
errado é pior que um número ausente — se não mediu, diga que não mediu.

---

## Onde está o resto

| Assunto | Arquivo |
|---|---|
| Regras de como escrever aqui | [`AGENTS.md`](../AGENTS.md) |
| Contrato das views e RPCs do CRM | [`CONTRATO-TELA-CRM.md`](CONTRATO-TELA-CRM.md) |
| Decisão de conversões desligadas | [`adr/ADR-0017-...`](adr/ADR-0017-entregar-crm-com-conversoes-desligadas.md) |
| Banco: schema, segurança | [`BANCO_DE_DADOS.md`](BANCO_DE_DADOS.md) |
| Arquitetura geral | [`ARQUITETURA.md`](ARQUITETURA.md) |
| Briefings já cumpridos | [`contexto/arquivo/`](contexto/arquivo/) |

## Decisões de produto já tomadas — não reabrir sem fato novo

- **Pipeline fixo de seis etapas** (ADR-0019). Etapas livres foram recusadas: exigiriam reescrever 9 funções, 18 views e 3 arquivos do front que dependem do significado de cada etapa
- **Frases automáticas configuráveis por cliente**, versão enxuta, dentro do IMP-226
- **Rótulos de etapa por cliente** no backlog (IMP-228), com gatilho: primeiro cliente fora de clínica, ou a decisão de tirar a QuickClean do GHL
- **Purchase quando o valor está pendente**: decisão em aberto no IMP-217, tomada quando a tarefa começar
