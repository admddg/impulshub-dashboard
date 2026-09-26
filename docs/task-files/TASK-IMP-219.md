# IMP-219 — Correção fail-closed do runbook de ativação

**Escopo:** documentação/processo; nenhuma migration, workflow n8n, deploy ou
alteração de dados reais. O arquivo executável de referência é
`docs/RUNBOOK-IMP-219-ATIVACAO-CANARIO.md`.

## Correções entregues

- Corrigido `workflow_category` de `ops` para `other`, valor permitido pelo
  `workflow_execution_logs_workflow_category_check` (`onboarding`, `events`,
  `dispatch`, `media_sync`, `backfill`, `other`).
- Reescrita a ativação para exigir, na mesma transação,
  `UPDATE ... WHERE id = ... AND crm_emits_conversions = false RETURNING` e
  `INTO STRICT`; zero ou múltiplas linhas abortam.
- A identidade do cliente da auditoria é derivada da linha retornada, não de
  placeholders. Há readback explícito da linha atualizada antes do insert de
  auditoria de sucesso.
- A documentação manda `ROLLBACK` em qualquer cardinalidade diferente de um,
  readback inconsistente ou falha de auditoria; não há `LIMIT 1`.
- O replay histórico é explicitamente **ignorado por padrão**. Replay e
  reprocessamento de linhas antigas exigem plano separado e aprovação.
- Pré-flight executável cobre alvo único desligado, ausência de GHL recente,
  contratos do consumidor e baseline.
- Canary e reconciliação usam critérios numéricos `event_code × platform` para
  `lead`, `agendado`, `ganho` × `meta`, `google_ads`; códigos inelegíveis devem
  gerar zero outbox.
- Reconciliação lista `conversion_outbox` com `events_normalized`, preservando
  `platform`, `status`, `sent_at`, `external_job_id`, `external_request_id`,
  `http_status`, `response`, origem e identidade do evento.
- Critérios de abortar e comando de desligamento também são fail-closed; o
  abort para novas emissões sem apagar ou reprocessar histórico.

## Validação estática

`npm run validate:imp219` verifica os invariantes do runbook e da task file:
valor de categoria, `UPDATE` com predicado/`RETURNING`/`INTO STRICT`, ordem
update → readback → auditoria, rollback, replay-ignore, tabelas/colunas da
reconciliação e critérios numéricos.

## Fora de escopo e segurança

- Não ativar/desativar flags reais.
- Não reprocessar outbox, enviar eventos, tocar n8n, fazer deploy ou merge.
- Não afirmar que uma resposta externa ocorreu sem `response`/IDs/sent_at lidos.
- O canário existente da Impuls permanece apenas como contexto; este commit não
  o cria, reverte nem modifica.

## Arquivos

- `docs/RUNBOOK-IMP-219-ATIVACAO-CANARIO.md`
- `docs/task-files/TASK-IMP-219.md`
- `scripts/validate-imp219-runbook.mjs`
- `package.json` (script de validação)
