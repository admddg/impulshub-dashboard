# Incidente 17tpepcdufj — parser WhatsApp

## Diagnóstico

A falha é causada pelo empate de ordenação entre duas linhas de `crm.opportunity_stage_history` criadas para o mesmo evento: a entrada em `lead` e a transição imediata para `atendimento` recebem o mesmo `occurred_at` (`v_ocorrido`) e, dentro da mesma transação, o mesmo `created_at` (`now()` é estável na transação). O validador deferred escolhe o `latest_history_stage_id` por `occurred_at DESC, created_at DESC, id DESC`; o UUID não representa ordem de inserção. Quando o UUID da linha `lead` é maior, ela é considerada a última, embora `opportunities.current_stage_id` já seja `atendimento`, produzindo `P0001 opportunity current stage must match its latest history row`.

Isso explica o sintoma de 1 mensagem passar e 2 falharem: cada oportunidade nova tem uma chance independente de o empate ordenar a linha inicial depois da transição.

## Correção mínima proposta

Na inserção da transição automática `lead -> atendimento`, usar um `occurred_at` estritamente posterior ao da linha inicial do mesmo evento, por exemplo `v_ocorrido + interval '1 microsecond'` (ou uma coluna/ordem monotônica dedicada, se o domínio exigir precisão sub-microsegundo). Não alterar a constraint para ignorar o desencontro e não desabilitar os triggers.

## Limite de implementação

Não foi criada migration executável para substituir `crm.stevo_parse_messages`: o parser no staging tem hash `f6930a9d1ea153f2bb863e1ef8549087` e 8.075 bytes, enquanto a migration em `origin/main` tem outra implementação (13.458 bytes e regra condicional de oportunidade). Substituir a função inteira sem obter a definição canônica atual de produção pode remover lógica já aplicada. O artefato desta branch prova a causa e a correção em harness; a migration final deve ser gerada a partir da definição lida do ambiente que o Caio autorizar como fonte canônica.

## Evidência

- Staging `nfratueiutxnypbxfnmi`, via `scripts/staging-run.py rollback`: `cron.job = NULL`, `raw_pending = 0`; nenhum dado persistiu.
- Harness de empate (`scripts/incident-17tpepcdufj-tie-failure.sql`): falhou exatamente em `set constraints all immediate` com `P0001 opportunity current stage must match its latest history row`.
- Harness corrigido (`scripts/incident-17tpepcdufj-tie-fixed.sql`): retornou `fixed_path_passed` e `ROLLBACK ok (7 statements)`.
- Harness com duas oportunidades (`scripts/incident-17tpepcdufj-direct-repro.sql`): `before_immediate = 2/2`, `after_immediate`, `ROLLBACK ok (9 statements)` quando os timestamps são distintos; confirma que o número de linhas, isoladamente, não é a causa.
- Chamada real `crm.stevo_parse_messages(1)` e `(2)` no staging retornou `0`/`0` por fila vazia; não reproduziu o parser por ausência de fixture WhatsApp sintética.

## Segurança e gates

Nenhuma escrita em produção, migration, flag ou job foi executada. Todas as provas de banco terminaram em `ROLLBACK`; o harness de falha abortou antes do rollback explícito, mas o runner chamou `c.rollback()` ao capturar o erro.

`npm test -- --runInBand`: 35/35 passou. `git diff --check`: passou.
