# Direcionamento ao Coordenador — 19/09/2026

Seu relatório de ambientação foi aceito. É disciplinado, separou "documentado"
de "verificado" e não tocou em nada. Continue assim.

Este documento faz três coisas: responde suas 12 perguntas com evidência,
triagem dos ~30 riscos que você levantou, e define a regra de operação que vale
a partir de agora.

---

## 0. A regra que vale acima de todas as outras

A Impuls é agência de marketing, não empresa de tecnologia. O sistema existe
para a agência focar em adquirir cliente e entregar resultado — não para ser
cuidado.

Já travamos este projeto uma vez por excesso de rigor. A Fase 0 demorou mais que
o projeto legado inteiro. O sprint atual foi aberto com prazo de 3 semanas e
entregue em 1 dia, **porque cortou escopo, não porque acelerou**.

Portanto, sua regra de parada:

> **Não abra tarefa que não esteja ligada a (a) entregar o CRM, (b) um cliente
> específico com problema, ou (c) um risco que pode causar perda irreversível.**
>
> Todo o resto vai para o backlog do próximo sprint, escrito, e não é discutido
> de novo até o sprint virar.

Levantar um risco e **não** agir sobre ele é uma decisão válida e frequentemente
a certa. Registrar é obrigatório. Corrigir não é.

Quando estiver em dúvida entre a solução completa e a solução que resolve,
**escolha a que resolve e escreva no relatório o que ficou de fora e por quê.**
Uma nota honesta em relatório vale mais que uma semana de engenharia preventiva.

---

## 1. Respostas às suas 12 perguntas

### Prioridade imediata

**1. `feat/imp-206-crm-tab` é a base oficial?**
Sim. É a única linha de desenvolvimento ativa do dashboard. `feat/imp-205-event-bridge`
está contida no `main` e pode ser descartada como linha — o worktree pode ser
removido quando for conveniente, sem pressa.

**2. Existe PR para os 14 commits?**
Não. **Eles existem apenas nesta máquina.** Não há branch remota correspondente.
Este é o único risco da sua lista que merece ação hoje — ver seção 2.

**3. Qual commit está em `painel.impulshub.com.br`?**
`b43b805` (`fix(crm): ponte de eventos entra inerte, com flag por cliente`),
branch `main`, deploy `dpl_D4e2KUcvrHH7TfE7eSvh3o9U5vib`, estado READY.
Verificado na API da Vercel em 19/09.

**Consequência importante: a aba CRM não está em produção.** Todo o trabalho de
IMP-206, 207 e 212 está só na branch local. O que está no ar é o dashboard sem
CRM, com a ponte de eventos inerte.

**4. As migrations da branch já foram aplicadas em produção?**
**Sim, todas.** O banco está à frente do que está publicado — o oposto do risco
que você imaginou. Ledger verificado em 19/09, 11 migrations, batendo exatamente
com os arquivos do repositório:

```
20260922000000  crm_baseline
20260922000001  crm_opportunity_attribution
20260923000000  crm_stevo_parser
20260923000001  crm_schedule_stevo_parser
20260923000002  crm_public_read_views
20260923000003  crm_public_write_rpcs
20260923000004  client_users_attendant_role
20260924000000  crm_event_bridge
20260925000000  crm_fix_owners_can_write
20260925000001  crm_board_counts_filtered
20260925000002  crm_stage_version_guard
```

Uma migration está escrita e **ainda não aplicada**:
`20260925000003_crm_contacts_view_filters` — expõe `opened_at` e
`owner_profile_id` em `v_crm_contacts_v1`. Bloco pronto em
`docs/APLICAR-2026-09-19-parte2.sql`, aguardando o Caio colar.

Contexto que você deve conhecer: o ledger já esteve desalinhado e **foi
corrigido hoje**. Quatro migrations estavam registradas com o carimbo de
aplicação em vez do nome do arquivo, e uma não tinha arquivo nenhum no repo. Se
você encontrar documentação que diga o contrário, ela é anterior a 19/09.

**5. A ADR-0017 continua vigente?**
Sim, e verificado no banco hoje. Os 6 registros de `clients_base` estão com
`crm_emits_conversions = false`, incluindo o template e o inativo. Nenhum cliente
emite conversão pelo CRM.

A flag é a única chave. **Nenhum agente liga essa flag.** Só o Caio, e só depois
de IMP-215 a IMP-219.

### Organização do trabalho

**6. A lista "Sprint 22/09 → 09/10 — CRM sem GHL" ainda é a fila atual?**
Sim. Existe também a lista **"Sprint 2 — Permissões e Conversões"**, já criada e
priorizada, com 12 tarefas (IMP-213 a IMP-224). Ela é o destino de tudo que não
for entrega do CRM.

**7. Qual é a próxima prioridade real?**
Nesta ordem, sem paralelismo:

1. **Fechar a entrega do CRM** — IMP-212 (entregue, em revisão), merge, deploy
2. **IMP-208** — Central operando 3 dias sem GHL. É o teste real
3. **IMP-213** — papéis e visibilidade por aba. Hoje o atendente da clínica vê
   faturamento e investimento
4. **IMP-214** — dois proprietários (CRC e Vendas)
5. **IMP-215 a IMP-219** — a cadeia de conversões

Permissões vêm antes de conversões por decisão do Caio, e a razão é boa: é um
problema de exposição de dado do cliente, com pessoa real olhando a tela.

**8. Preservar o trabalho de IMP-117/118 em `Impuls-Platform-onda3`?**
Congelado. **Não apague, não limpe, não reaproveite.** Não decida agora — o
motor de frases foi cancelado e esse conteúdo não está no caminho de nada.
Revisitar quando o Sprint 2 fechar.

**9. Segunda identidade para revisão de PR no GitHub?**
Pergunta legítima, só o Caio responde. Enquanto não houver, **a revisão
independente é o Supervisor**, e o merge é do Caio. Não bloqueie entrega
esperando branch protection.

### Produção e segurança

**10. Verificar GitHub, Vercel, Supabase, n8n e ClickUp em modo leitura?**
Sim, autorizado e desejável — leitura, sempre. Parte disso já está feito neste
documento (Vercel, Supabase, ClickUp). Falta n8n e Stevo.

**Escrita em produção continua exigindo o Caio.** DDL, migration, flag de
conversão, push e deploy passam por ele. Esse gate não é burocracia: já evitou
duplicar conversão na Meta para os três maiores clientes, o que é irreversível.

**11. Os arquivos em `Backups\...\restore-tests\...`?**
Planeje revisão de retenção — ver seção 2. É o segundo item da sua lista que
merece ação.

**12. Existe staging separado?**
Existe um projeto Vercel `impulshub-staging`, criado em 17/09. O projeto Supabase
de staging foi **aposentado pela ADR-0016** — existe um banco só, `Clients_Base`.
Na prática: validação funcional acontece local e depois em produção.

Isso é consequência aceita da arquitetura enxuta (ADR-0013), não um descuido.
Não proponha recriar staging.

---

## 2. Triagem dos riscos que você levantou

Você listou cerca de 30. **Dois merecem ação agora.** O resto está classificado
abaixo e **não deve ser reaberto** sem fato novo.

### Agir agora

**9.1 — Trabalho ativo só em branch local.** Correto e urgente. 14 commits, uma
máquina, sem backup remoto. Inclui todo o CRM. Ação: `git push origin
feat/imp-206-crm-tab` hoje. Só o Caio executa.

**9.10 — Chaves e SQLite em `restore-tests`.** Você fez certo em não abrir. Há
arquivos `.key` do Caddy e `database.sqlite` do n8n em claro num ensaio de
restauração. Ação: propor política de retenção e criptografia ao Caio. Tarefa
delimitada, não investigação aberta.

### Já registrado — não reabra

| Seu item | Onde já está |
|---|---|
| 9.3 conversões quebradas | IMP-215 a IMP-219, e a ADR-0017 explica a decisão |
| 9.2 sem testes e sem CI | IMP-222 |
| 9.11 retry do Stevo, @lid | IMP-220 |
| 9.11 credenciais em texto no banco | IMP-210 |

Se você propuser de novo qualquer um destes, a resposta já está escrita.

### Aceito conscientemente — não é para corrigir

**9.7 — Segurança dependente do banco.** Não é fragilidade, é a arquitetura
escolhida (ADR-0013): sem backend intermediário, RLS e RPCs como autoridade.
A mitigação não é mudar isso, é **revisão independente em toda mudança de RLS,
view ou função SECURITY DEFINER**. Essa regra vale e é sua para fazer cumprir.

**9.9 — Deploy por ZIP.** Documentação velha. O deploy real é push na `main` →
Vercel, e funciona. Corrija o documento quando passar por ele; não abra tarefa.

**9.8 — Node não fixado.** Verdadeiro e irrelevante hoje. Uma máquina, um
agente de front. Se virar problema, são 5 minutos.

**9.4 — Estado de produção não verificado.** Estava certo quando você escreveu.
Este documento resolve: Vercel, Supabase e ClickUp verificados em 19/09.

### Desescalar

**9.5 — `Impuls-Platform-onda3`.** Congelado, sem decisão pendente.

**9.6 — Documentação contraditória.** Real, e a correção é por atrito, não por
projeto: **quem tocar num documento corrige o que viu ali**. Não abra tarefa de
"sincronizar a documentação" — é exatamente o tipo de trabalho que consome
sprint e não entrega cliente.

Duas correções que valem quando alguém passar perto: `docs/README.md` cita
`.env.example` mas o arquivo é `.env.local.example`; e o `AGENTS.md` ainda diz
que falta a aba CRM.

**A pasta `App-Impuls-Legado`** tem nome enganoso — é o checkout ativo. Renomear
está pendente por trava de arquivo do VSCode. Baixa prioridade; só não se
confunda.

---

## 3. Divisão dos executores

Decisão do Caio, considerando consumo de tokens da assinatura:

| Agente | Papel |
|---|---|
| **Coordenador** (você) | Fila, escopo, contrato, evidências. Não implementa |
| **Supervisor** | Revisão independente. Não implementa o que revisa |
| **Executor DeepSeek** | **Executor principal** de tarefa delimitada e de risco baixo/médio |
| **Executor Codex** | Reservado para banco, RLS, SECURITY DEFINER, cadeia de conversões e bug que cruza front/PostgREST/banco |
| **Claude Code no Antigravity** | Frontend, exclusivamente |

O Codex é caro — use quando o custo de errar for maior que o custo dele. Banco e
RLS são esse caso. Ajuste de UI e documentação não são.

**Nunca**: DeepSeek em migration crítica, RLS, SECURITY DEFINER, conversão
Meta/Google, dado real ou produção.

**Nunca**: qualquer executor aprovando o próprio trabalho de risco médio ou alto.

---

## 4. Como quero receber o trabalho

Uma tarefa IMP-NNN por entrega, branch isolada, commits pequenos.

No relatório final, **separe sempre**:

- o que foi **verificado rodando**, com o número medido
- o que está **correto por construção mas não testado**
- o que **não bateu**, e por quê

Esse formato já produziu resultado: o agente de front mediu um filtro de data
contra produção e descobriu que a versão errada devolveria **zero cards com a
contagem dizendo 18**. Ninguém teria achado isso lendo o código.

Um número errado é pior que um número ausente. Se não mediu, diga que não mediu.

---

## 5. O que não fazer

- Não ligue `crm_emits_conversions` para nenhum cliente
- Não rode DDL, migration ou escrita em produção sem o Caio
- Não faça push nem merge para `main` sem o Caio
- Não aponte `supabase db reset` para projeto remoto — é destrutivo
- Não trabalhe em `Impuls-Platform` nem em `Impuls-Platform-onda3`
- Não abra tarefa de melhoria que não esteja ligada a entrega, cliente ou perda
  irreversível
