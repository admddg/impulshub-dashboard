# Tarefa ao Coordenador — publicar o CRM

Objetivo: levar a aba CRM de `feat/imp-206-crm-tab` para produção.

Hoje o painel em `painel.impulshub.com.br` roda `b43b805`, **sem a aba CRM**.
Todo o trabalho de IMP-206, 207 e 212 está na branch. O banco já está em
produção e à frente do que está publicado — 12 migrations aplicadas.

## Antes de mexer, confira o estado

Leitura apenas. Se algum item não bater, **pare e avise o Caio**.

| O quê | Esperado |
|---|---|
| Branch remota | `feat/imp-206-crm-tab` existe no GitHub |
| Produção Vercel | `b43b805`, branch `main`, READY |
| Ledger Supabase | 12 migrations, batendo com `supabase/migrations/` |
| Flag de conversão | `crm_emits_conversions = false` nos 6 registros de `clients_base` |
| Última migration | `20260925000003_crm_contacts_view_filters` aplicada |

A última importa: a visão de lista filtra por `opened_at` e `owner_profile_id`
em `v_crm_contacts_v1`. Se a view não tiver as duas colunas, o filtro quebra em
produção.

## Sequência

1. **Revisão independente pelo Supervisor**, antes do merge. Escopo:
   RLS e views novas, as 4 RPCs de escrita, e se algo além do CRM foi tocado.
   O Supervisor **não implementa** o que revisa.

2. **PR de `feat/imp-206-crm-tab` para `main`.** Descrição listando as
   migrations já aplicadas e o que muda na interface.

3. **Merge — só o Caio.** Não faça merge nem push por conta própria.

4. **Deploy é automático.** Merge na `main` dispara a Vercel. Não rode deploy à
   mão.

5. **Verificação pós-deploy**, com o Caio logado:
   - a aba CRM aparece nos 3 clientes com dado (Royal, QuickClean, Central)
   - kanban carrega e o número no topo bate com os cards
   - filtros de data e proprietário funcionam nas duas visões
   - mover um card funciona e a versão incrementa
   - **nenhuma conversão nova** em `conversion_outbox` com
     `source_system = 'impuls_crm'` — tem que continuar zero

O último item é o mais importante. Se aparecer linha do CRM na outbox, algo
ligou a flag. Pare tudo e avise.

## Rollback

Se der problema em produção: reverter pela Vercel para o deploy `b43b805`
(`dpl_D4e2KUcvrHH7TfE7eSvh3o9U5vib`, marcado como rollback candidate).

**Não reverta migration.** O banco é compatível com as duas versões do front —
as views e RPCs novas simplesmente deixam de ser chamadas. Reverter DDL em
produção é mais arriscado que o problema que resolveria.

## O que não fazer

- Não ligue `crm_emits_conversions` para nenhum cliente
- Não aplique migration nova
- Não faça merge nem push sem o Caio
- Não toque na branch `feat/imp-205-event-bridge` nem nos repositórios
  arquivados

## Contexto para o que vem depois

Não é tarefa agora — é para você não propor na ordem errada.

**Decisão de negócio tomada em 19/09:** Royal e Central continuam com o GHL,
reduzido ao plano mais simples, **exclusivamente para o chat**. São os dois
primeiros clientes do nicho e o custo de manter é menor que o de mudar como as
equipes trabalham. **Cliente novo entra 100% na nossa estrutura.**

Consequência que precisa estar no radar: hoje a conversão da Royal e da Central
sai do GHL **porque os cards se movem lá dentro**. No momento em que a operação
passar a mover o card no nosso sistema, o GHL para de emitir e o nosso ainda não
emite — rastreamento apagado sem aviso. Por isso a cadeia de conversões
(IMP-215 a IMP-219) tem prazo amarrado a esse momento, não a uma data no
calendário.

Ordem acordada com o Caio:

1. Usuários e acessos (IMP-213, IMP-214) — trava a entrada de cliente novo
2. Automatizações por mensagem — **escopo ainda não definido**, não abra tarefa
3. Conversões (IMP-215 a IMP-219)
