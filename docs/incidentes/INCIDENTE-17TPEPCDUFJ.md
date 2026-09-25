# Incidente 17tpepcdufj — parser WhatsApp

## Diagnóstico

A falha é causada pelo empate de ordenação entre duas linhas de `crm.opportunity_stage_history` criadas para o mesmo evento: a entrada em `lead` e a transição imediata para `atendimento` recebem o mesmo `occurred_at` (`v_ocorrido`) e, dentro da mesma transação, o mesmo `created_at` (`now()` é estável na transação). O validador deferred escolhe o `latest_history_stage_id` por `occurred_at DESC, created_at DESC, id DESC`; o UUID não representa ordem de inserção. Quando o UUID da linha `lead` é maior, ela é considerada a última, embora `opportunities.current_stage_id` já seja `atendimento`, produzindo `P0001 opportunity current stage must match its latest history row`.

Isso explica o sintoma de 1 mensagem passar e 2 falharem: cada oportunidade nova tem uma chance independente de o empate ordenar a linha inicial depois da transição.

## Correção mínima proposta

Na inserção da transição automática `lead -> atendimento`, usar um `occurred_at` estritamente posterior ao da linha inicial do mesmo evento, por exemplo `v_ocorrido + interval '1 microsecond'` (ou uma coluna/ordem monotônica dedicada, se o domínio exigir precisão sub-microsegundo). Não alterar a constraint para ignorar o desencontro e não desabilitar os triggers.

## Limite de implementação

Não foi criada migration executável para substituir `crm.stevo_parse_messages`: o parser no staging tem hash `f6930a9d1ea153f2bb863e1ef8549087` e 8.075 bytes, enquanto a migration em `origin/main` tem outra implementação (13.458 bytes e regra condicional de oportunidade). Substituir a função inteira sem obter a definição canônica atual de produção pode remover lógica já aplicada. O artefato desta branch prova a causa e a correção em harness; a migration final deve ser gerada a partir da definição lida do ambiente que o Caio autorizar como fonte canônica.

## Evidência

- O aceite executável (`supabase/acceptance/imp17tpepcdufj-parser-tie-fix.sql`) insere quatro fixtures sintéticas em `public.stevo_events_raw`, em dois tenants, e chama `crm.stevo_parse_messages(4)` dentro da transação.
- O aceite verifica duas oportunidades, quatro atividades, quatro linhas de histórico, avanço para `atendimento`, isolamento de tenant, status `processed`, `SET CONSTRAINTS ALL IMMEDIATE` e termina com `ROLLBACK`.
- O harness de empate (`scripts/incident-17tpepcdufj-tie-failure.sql`) falhou exatamente em `set constraints all immediate` com `P0001 opportunity current stage must match its latest history row`; o caminho corrigido preserva o +1 microsecond somente na transição automática.
- Nenhuma escrita em produção, migration, flag ou job foi executada.

## Segurança e gates

O runbook de produção foi reduzido a preflight `BEGIN READ ONLY` com readback de identidade, assinatura, `SECURITY DEFINER`, `search_path`, grants, triggers, backlog e cron. O aceite mutável aponta exclusivamente para staging e todas as fixtures terminam em `ROLLBACK`.

`npm test -- --runInBand`: 35/35 passou. `git diff --check`: passou.
