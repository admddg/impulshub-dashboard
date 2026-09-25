# Runbook de produção — IMP-17TPEPCDUFJ

## Escopo e regra de segurança

- **Produção (`mtxnwtqwfagjzkvgsncs`) é somente leitura neste runbook.**
- Nenhuma migration, rollback, fixture, chamada a `crm.stevo_parse_messages(...)`, alteração de flag ou alteração de `cron.job` é permitida contra produção.
- O aceite mutável e a prova do empate são **exclusivos de staging**, em uma transação que termina com `ROLLBACK`.
- Este documento não autoriza aplicação. Qualquer mudança de produção exige um procedimento separado, aprovação explícita e revisão independente.

## 1. Preflight de produção — SELECT-only

Usar uma conexão explicitamente apontada para o project-ref de produção, com `ON_ERROR_STOP=1`. Não usar este banco para o arquivo de acceptance.

```sql
BEGIN READ ONLY;
SET LOCAL statement_timeout = '10s';
SET LOCAL lock_timeout = '2s';

SELECT current_database(), current_user, session_user;

-- Captura de identidade, assinatura, segurança e definição; não altera nada.
SELECT
  p.oid::regprocedure AS function_signature,
  p.prosecdef AS security_definer,
  pg_get_function_result(p.oid) AS return_type,
  pg_get_functiondef(p.oid) AS function_definition,
  md5(pg_get_functiondef(p.oid)) AS function_md5,
  octet_length(pg_get_functiondef(p.oid)) AS definition_bytes
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'crm' AND p.proname = 'stevo_parse_messages'
  AND p.proargtypes = '23'::oidvector;

-- Assinatura, search_path, grants e dependências devem ser apenas observados.
SELECT p.oid::regprocedure, p.proconfig
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'crm' AND p.proname = 'stevo_parse_messages';

SELECT grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'crm' AND routine_name = 'stevo_parse_messages'
ORDER BY grantee, privilege_type;

SELECT trigger_schema, trigger_name, event_manipulation, event_object_schema, event_object_table,
       action_statement
FROM information_schema.triggers
WHERE event_object_schema IN ('crm', 'public')
  AND (event_object_table IN ('opportunities', 'opportunity_stage_history', 'activities')
       OR action_statement ILIKE '%stevo_parse_messages%');

SELECT parse_status, count(*) AS rows
FROM public.stevo_events_raw
GROUP BY parse_status
ORDER BY parse_status;

SELECT count(*) AS raw_message_backlog
FROM public.stevo_events_raw r
WHERE r.event_type = 'Message'
  AND r.parse_status = 'raw'
  AND r.client_id IS NOT NULL
  AND EXISTS (SELECT 1 FROM crm.tenants t WHERE t.id = r.client_id);

SELECT to_regclass('cron.job') AS cron_job_relation;
SELECT jobid, jobname, schedule, active, command
FROM cron.job
WHERE jobname = 'crm-stevo-parser';

SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'crm-stevo-parser')
ORDER BY start_time DESC
LIMIT 3;

ROLLBACK;
```

Registrar o readback completo: identidade da conexão, assinatura, `SECURITY DEFINER`, `search_path`, grants, triggers, hash/tamanho da definição, backlog e estado do job. Se qualquer item divergir do baseline autorizado, parar. Não tentar corrigir pelo runbook.

## 2. Aceite executável — staging somente

O arquivo abaixo é o único aceite do incidente. Ele insere fixtures sintéticas em `public.stevo_events_raw`, executa a função real `crm.stevo_parse_messages(4)`, valida oportunidades, atividades, histórico de etapas, isolamento entre dois tenants e `SET CONSTRAINTS ALL IMMEDIATE`, e termina com `ROLLBACK`:

```bash
psql "$STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/acceptance/imp17tpepcdufj-parser-tie-fix.sql
```

A variável deve apontar para staging; não substituir por `$PROD_DATABASE_URL`. O resultado exigido é `parser_tie_fix_acceptance_passed`. Qualquer erro, inclusive falha de constraint deferred, é blocker. Após a execução, confirmar em uma leitura separada de staging que os UUIDs de fixture não persistiram.

## 3. Verificações estáticas antes de qualquer proposta futura

- Forward e rollback devem manter a assinatura `crm.stevo_parse_messages(integer)`, `SECURITY DEFINER`, `SET search_path = ''`, grants e triggers existentes.
- O guard canônico de criação de oportunidade deve aparecer nos dois corpos exatamente como `not v_de_mim and v_conv_source is not null`.
- `interval '1 microsecond'` pode aparecer somente na transição automática `Lead -> Atendimento`; não pode alterar timestamps de entrada, atividades ou milestones.
- Não aceitar acceptance que insira histórico manualmente como substituto da chamada do parser.

## Stop conditions

1. A conexão de produção não é claramente o project-ref esperado.
2. Qualquer comando propõe `INSERT`, `UPDATE`, `DELETE`, DDL, migration, rollback, fixture ou chamada do parser em produção.
3. O aceite não executa `crm.stevo_parse_messages(...)` sobre `stevo_events_raw` sintético.
4. O aceite não confirma oportunidades, atividades, histórico, isolamento, `SET CONSTRAINTS ALL IMMEDIATE` e `ROLLBACK`.
5. Forward/rollback divergem em guard, assinatura, segurança, `search_path`, grants ou triggers.

Em qualquer stop condition: preservar o output, não repetir a operação e escalar com o erro/SQLSTATE e o readback correspondente.
