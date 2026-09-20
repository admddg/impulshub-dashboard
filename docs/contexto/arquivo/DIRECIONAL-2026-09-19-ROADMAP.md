# Direcional ao Coordenador — roadmap e modelo de trabalho

**Data:** 19/09/2026 · **Decide:** Caio
Substitui a seção "Ordem acordada" do documento anterior de merge.

---

## 1. A decisão que muda o enquadramento

Até hoje o projeto tentava fazer duas coisas ao mesmo tempo: construir um CRM
próprio **e** migrar para ele quatro clientes que já têm hábito formado em outra
ferramenta. A segunda parte era a fonte de quase toda a complexidade.

**Decisão:**

> **Royal e Central permanecem no GoHighLevel, definitivamente.** Não são alvo de
> migração. Servem como **laboratório**: aprendizado, modelagem e teste.
>
> **O sistema é construído para os clientes NOVOS.** Cliente novo entra 100% na
> nossa estrutura, sem GHL.

Consequências práticas, e cada uma remove um problema que estava aberto:

| Antes | Agora |
|---|---|
| Treinar equipes a mudar de ferramenta | Não se aplica |
| Construir inbox para substituir o chat do GHL | Não se aplica |
| Risco de apagar conversão ao tirar o card do GHL | Não existe — o card continua no GHL |
| Piloto com prazo apertado | Não há piloto de migração |

**IMP-208 ("Central operando sem GHL por 3 dias") fica inválida.** Era o teste da
migração que não vai acontecer. Deve ser fechada como cancelada, com o motivo
registrado.

---

## 2. O bloqueio que ninguém tinha visto

O plano prevê usar a **Impuls** como conta de teste para automações e
conversões. Medido no banco em 19/09:

| Cliente | Instância Stevo | Mensagens | Oportunidades |
|---|---|---|---|
| Royal | `royal-closer`, `royal-comercial` | 3.308 | 189 |
| QuickClean | `marcos-quick-clean` | 6.397 | 92 |
| Central | `central-gama-crc` | 137 | 16 |
| **ImpulsHub** | **nenhuma** | **0** | **0** |

**A Impuls não tem instância Stevo conectada.** Sem mensagem entrando, não há o
que automatizar nem o que converter. As etapas 4 e 5 estão bloqueadas por uma
configuração, não por código.

**Recomendação:** conectar o WhatsApp comercial da Impuls a uma instância Stevo
e **usar o sistema para vender a própria agência**. Deixa de ser teste sintético
e passa a ser operação real — conversa real, lead real, anúncio real, conversão
real — com risco zero de cliente. A Impuls vira o primeiro cliente de verdade do
sistema novo, e quem constrói passa a sentir o que o cliente vai sentir.

Isso precisa ser uma tarefa, e ela vem antes das etapas 4 e 5.

---

## 3. O roadmap

Cinco etapas, **uma de cada vez**. Não comece a seguinte antes da anterior estar
em uso.

### Etapa 1 — Merge e deploy do CRM
Em execução. Instruções em `docs/contexto/PROMPT-COORDENADOR-MERGE-CRM.md`.

**Pronto quando:** a aba CRM está em `painel.impulshub.com.br` e nenhuma linha
nova aparece em `conversion_outbox` com `source_system = 'impuls_crm'`.

### Etapa 2 — Avaliar o que foi entregue
Uso real, não revisão de código. O Caio opera o painel por alguns dias e anota
o que incomoda.

**Pronto quando:** existe uma lista de ajustes vinda do uso, e ela foi triada
entre "faz agora" e "backlog". Esta etapa **não é** para reabrir o que já
funciona.

**Tarefas que já existem e podem entrar aqui:** IMP-224 (arrastar card) e
qualquer coisa que o uso revelar.

### Etapa 3 — Permissões e usuários
**IMP-213** (papéis e visibilidade por aba) e **IMP-214** (dois proprietários:
CRC e Vendas).

É o que trava a entrada de cliente novo: hoje um atendente de clínica enxerga
faturamento e investimento. O modelo desejado:

| Papel | Vê |
|---|---|
| Dono / gestor da clínica | Tudo: faturamento, investimento, ROI, CRM, funil, canais |
| Atendente | Só CRM, funil e canais — **não vê dinheiro** |
| Agência | Tudo, em todas as contas, + painel interno |

**Pronto quando:** um atendente logado não consegue ler faturamento nem pela
API direta, e o seletor de proprietário mostra apenas usuários operacionais da
clínica — nunca agência, nunca gestor.

### Etapa 4 — Pipeline automatizada
Regras do tipo **"chegou tal mensagem → move para tal etapa"**.

Escopo confirmado pelo Caio: é isso, e só isso. **Não é** envio de mensagem, não
é lembrete, não é follow-up, não é distribuição entre atendentes. Se alguém
propuser essas coisas, está fora de escopo.

Nota técnica importante: **o mecanismo já existe.** O parser
(`crm.stevo_parse_messages`) já move Lead → Atendimento quando a primeira
resposta sai. Regra nova é mais uma condição no mesmo lugar, não um sistema
novo. Dimensione como pequeno até que se prove o contrário.

Não se aplica a Royal e Central — elas usam o GHL. **Testar na Impuls**, o que
depende da seção 2.

**Pronto quando:** uma regra roda sozinha em conversa real da Impuls e o Caio
confia nela.

### Etapa 5 — Conversões e tracking
**IMP-215 a IMP-219.** Acoplar o CRM ao sistema de tracking, independente do GHL.

O estado real, medido em 19/09:

- **Ninguém consome a `conversion_outbox`.** 512 linhas `pending` paradas — 326
  de `google_ads` desde 24/08, 186 de `meta` desde 10/09 — enquanto linhas
  `sent` continuam fluindo. O workflow n8n `1.1` grava a linha *e* entrega na
  mesma execução; o que não é entregue na hora fica pendente para sempre. **A
  outbox é um registro, não uma fila.**
- A ponte exige `ghl_location_id` e lança exceção se estiver vazio — cliente sem
  GHL quebraria ao mover card.
- Ganho é emitido **antes** de valor e moeda serem gravados.
- Só cria job Meta; Google nunca recebe.

⚠️ **As 512 linhas pendentes são de agosto e setembro. Não podem ser enviadas.**
Qualquer consumidor precisa de corte por data ou escopo — evento enviado para a
Conversions API não volta.

**Testar na Impuls.** Royal, QuickClean e Central continuam emitindo pelo GHL e
**não** devem ter a flag ligada.

**Pronto quando:** mover um card na Impuls faz o evento aparecer no Gerenciador
de Eventos da Meta, e o runbook de ativação (IMP-219) existe.

---

## 4. Critério de entrada do próximo cliente

Cliente novo só entra quando as cinco etapas estiverem fechadas:

- [ ] Sistema funcional, avaliado em uso
- [ ] Permissões por papel funcionando
- [ ] Automações de pipeline rodando
- [ ] Conversões e tracking rodando e revisados
- [ ] Runbook de onboarding (IMP-223) escrito e testado na Impuls

**Não existe data.** A data anterior ("cliente novo em 2 semanas") era estimativa,
não compromisso, e estava produzindo pressa. O critério é a lista acima.

---

## 5. Modelo de trabalho a partir de agora

**Coordenador (você):** organiza tudo. Fila no ClickUp, escopo, contrato de cada
tarefa, delegação aos executores, consolidação de evidência. Tem bots e agentes
à disposição.

**Consultor paralelo (sessão do Caio no Claude Code):** segundo cérebro.
Revisa, debate, questiona decisões de arquitetura e fiscaliza entregas junto com
o Caio. **Não executa tarefa sua e não dá ordem aos seus agentes.** Quando
houver divergência entre os dois, quem decide é o Caio.

Isso não é redundância: uma entrega revisada por quem não a planejou pega o que
o planejador não consegue enxergar. Hoje mesmo aconteceu duas vezes — um script
de aceite que aprovava a tela quebrada, e um ledger de migrations que registrava
como aplicada uma migration que não existia no banco.

**O ClickUp passa a ser seu.** Duas listas:

- `Sprint 22/09 → 09/10 — CRM sem GHL` (901329106534)
- `Sprint 2 — Permissões e Conversões` (901329121622)

Pendências de arrumação, nesta ordem:

1. Fechar **IMP-206, IMP-207 e IMP-212** — entregues, esperando só o merge
2. Cancelar **IMP-208** com o motivo: migração da Central não vai acontecer
3. Criar a tarefa de **conectar a instância Stevo da Impuls** (seção 2)
4. Criar a tarefa de **automações de pipeline** — não existe em lugar nenhum
5. Reordenar o Sprint 2 conforme a seção 3
6. **IMP-210** (segredos → Vault) não tem etapa no roadmap. É segurança, vence
   16/10, e deve ser encaixada onde couber sem atropelar as cinco etapas

---

## 6. Regras que continuam valendo

- **Não ligue `crm_emits_conversions`** para nenhum cliente. Só o Caio, e só
  depois de IMP-215 a IMP-219
- **Escrita em produção exige o Caio**: DDL, migration, flag, push, merge, deploy
- Revisão independente em toda mudança de RLS, view ou função `SECURITY DEFINER`
- Nenhum executor aprova o próprio trabalho de risco médio ou alto
- Não trabalhe em `Impuls-Platform` nem em `Impuls-Platform-onda3` — arquivados
- **Não abra tarefa que não esteja ligada à etapa atual, a um cliente com
  problema, ou a um risco de perda irreversível.** Levantar risco e não agir é
  decisão válida. Registrar é obrigatório; corrigir não é

## 7. Como entregar

Uma tarefa IMP-NNN por entrega, branch isolada, commits pequenos.

No relatório, **separe sempre**: o que foi **verificado rodando** com o número
medido, o que está **correto por construção mas não testado**, e o que **não
bateu** e por quê.

Requisito visual só conta como entregue com um número que o comprove. Um número
errado é pior que um número ausente — se não mediu, diga que não mediu.
