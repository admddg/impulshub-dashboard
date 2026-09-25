# Runbook de produção — IMP-17TPEPCDUFJ

## Estado e escopo

- **Estado:** pronto para execução condicionada; nenhuma escrita, restart, alteração de flag ou alteração de job de produção foi executada nesta preparação.
- **Alvo:** Supabase `Clients_Base`, project-ref `mtxnwtqwfagjzkvgsncs`.
- **Mudança:** substituir somente `crm.stevo_parse_messages(integer)` pela migration `supabase/migrations/20261003000000_stevo_parser_tie_fix.sql`.
- **Rollback:** `supabase/migrations/20261003000000_stevo_parser_tie_fix.rollback.sql` restaura a definição canônica capturada.
- **Pré-condição de autorização:** o hash canônico de produção é `f6930a9d1ea153f2bb863e1ef8549087`, definição com 8.075 bytes. O forward esperado é `f970e9952dcc45be5c32cec8102fec95`, com 8.116 bytes.
- **Não fazer:** não reiniciar serviços, não habilitar/desabilitar flags, não editar `cron.job`, não executar `crm.stevo_parse_messages(...)` manualmente como teste e não rodar qualquer SQL de escrita fora da migration/rollback autorizada.

## A única ação humana

**Caio deve dar uma aprovação explícita, por escrito, para aplicar esta migration no projeto de produção `mtxnwtqwfagjzkvgsncs`, autorizando também o rollback somente se um stop condition deste runbook for atingido.**

Sem essa aprovação, executar apenas a preparação e os preflights `BEGIN READ ONLY`; parar antes da migration.

## 1. Preflight somente leitura — registrar os números antes da escrita

Usar uma conexão apontando para `mtxnwtqwfagjzkvgsncs`, com `ON_ERROR_STOP=1`. O bloco abaixo é somente leitura e deve ser executado em uma transação que termina com `ROLLBACK`:

```sql
BEGIN READ ONLY;
SET LOCAL statement_timeout = '10s';
SET LOCAL lock_timeout = '2s';

SELECT current_database(), current_user, session_user;

-- Identidade e tamanho da função canônica; não prosseguir se não baterem.
SELECT
  md5(pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS function_md5,
  octet_length(pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS definition_bytes,
  position('v_ocorrido + interval ''1 microsecond''' in
           pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS tie_fix_position;

-- Contagens de backlog por status; guardar o resultado como baseline.
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

-- Objetos/agenda do parser; não alterar nada.
SELECT to_regclass('cron.job') AS cron_job_relation;
SELECT jobid, jobname, schedule, active, command
FROM cron.job
WHERE jobname = 'crm-stevo-parser';

-- Última execução conhecida do job, se pg_cron estiver disponível.
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'crm-stevo-parser')
ORDER BY start_time DESC
LIMIT 1;

ROLLBACK;
```

**Readback obrigatório do preflight:**

- identidade: `current_database` é produção e `session_user`/`current_user` são os papéis esperados;
- função: exatamente `f6930a9d1ea153f2bb863e1ef8549087`, `8075`, e `tie_fix_position = 0`;
- backlog: registrar o total elegível `raw_message_backlog` e a distribuição de `parse_status`; esses números são o baseline pós-apply;
- job: exatamente uma linha `crm-stevo-parser`, com seu schedule/active/command atuais; não modificar;
- última execução: registrar status e mensagem. Ausência de linha não é prova de saúde.

Se qualquer contagem, hash, tamanho, identidade, assinatura, schedule ou estado do job divergir do esperado, **parar**.

## 2. Migration forward — somente após a aprovação única

Executar do diretório raiz do repositório, usando a conexão de produção já autorizada em `$PROD_DATABASE_URL`. O único caminho de apply deste runbook é o `psql` abaixo; ele executa somente o arquivo nomeado e não pode aplicar migrations pendentes alheias:

```bash
psql "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261003000000_stevo_parser_tie_fix.sql
```

A migration deve ser aplicada uma única vez. Não executar `supabase db push`, `supabase db reset`, `supabase stop`, restart, ou qualquer comando de aplicação.

**Readback imediato após o forward (somente leitura):**

```sql
SELECT
  md5(pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS function_md5,
  octet_length(pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS definition_bytes,
  position('v_ocorrido + interval ''1 microsecond''' in
           pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS tie_fix_position;
```

Esperado: hash `f970e9952dcc45be5c32cec8102fec95`, `8116`, posição maior que zero. Se o hash/tamanho não bater, parar e não tentar novamente.

## 3. Acceptance — depois do forward, sem persistir fixture

O aceite cria somente fixtures determinísticas e termina em `ROLLBACK`; ele não deve ser editado nem executado contra staging como substituto da produção:

```bash
psql "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/acceptance/imp17tpepcdufj-parser-tie-fix.sql
```

Readback obrigatório: uma linha contendo exatamente `parser_tie_fix_acceptance_passed`, seguida de término bem-sucedido da transação. Qualquer erro, inclusive `P0001 opportunity current stage must match its latest history row`, é falha e exige stop.

## 4. Rollback — somente se necessário

Acionar rollback se qualquer stop condition ocorrer, se o acceptance falhar, ou se o post-apply não confirmar a saúde. O rollback também é uma escrita de produção e é permitido apenas pela aprovação humana definida acima:

```bash
psql "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20261003000000_stevo_parser_tie_fix.rollback.sql
```

**Readback obrigatório do rollback:**

```sql
SELECT
  md5(pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS function_md5,
  octet_length(pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS definition_bytes,
  position('v_ocorrido + interval ''1 microsecond''' in
           pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS tie_fix_position;
```

Esperado: hash `f6930a9d1ea153f2bb863e1ef8549087`, `8075`, `tie_fix_position = 0`. O histórico de migrations não deve ser apagado manualmente. Se o rollback não restaurar exatamente a função canônica, parar, não repetir cegamente e escalar.

## 5. Pós-apply — saúde do parser e backlog

Executar somente SELECTs, sem chamar o parser manualmente:

```sql
BEGIN READ ONLY;
SET LOCAL statement_timeout = '10s';

-- Saúde da definição instalada.
SELECT
  md5(pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS function_md5,
  octet_length(pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS definition_bytes,
  position('v_ocorrido + interval ''1 microsecond''' in
           pg_get_functiondef('crm.stevo_parse_messages(integer)'::regprocedure)) AS tie_fix_position;

-- Saúde do job, sem restart nem alteração.
SELECT jobid, jobname, schedule, active, command
FROM cron.job
WHERE jobname = 'crm-stevo-parser';

SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'crm-stevo-parser')
ORDER BY start_time DESC
LIMIT 3;

-- Backlog e erros, comparados ao baseline capturado no preflight.
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

SELECT parse_status, count(*) AS rows_last_15m
FROM public.stevo_events_raw
WHERE received_at >= now() - interval '15 minutes'
GROUP BY parse_status
ORDER BY parse_status;

ROLLBACK;
```

**Acceptance/readback esperado:**

- função: `f970e9952dcc45be5c32cec8102fec95`, `8116`, posição maior que zero;
- job: exatamente uma linha, `active = true`, sem mudança de schedule/command;
- execução: a próxima execução deve aparecer como `status = 'succeeded'` (ou o status de sucesso efetivamente usado pelo ambiente), sem erro no `return_message`; se ainda não houver execução posterior, aguardar o ciclo normal do job sem reiniciar e repetir a leitura;
- backlog: `raw_message_backlog` não pode aumentar em relação ao baseline sem uma explicação de ingestão concorrente; após um ciclo saudável, deve reduzir ou permanecer estável enquanto a entrada não superar a capacidade; não aceitar `failed`/erro novo no job;
- não existem fixtures do acceptance persistidas: os UUIDs `12000000-...`, `22000000-...` e `33000000-...` devem ter contagem zero se consultados.

## Stop conditions

1. Não existe a aprovação explícita de Caio para este project-ref.
2. Identidade de conexão, project-ref, hash/tamanho canônico, assinatura da função, ou baseline de backlog não conferem.
3. A migration retorna erro, timeout, lock timeout, ou altera qualquer objeto além da função indicada.
4. O hash forward não é exatamente `f970e9952dcc45be5c32cec8102fec95` / `8116`.
5. O acceptance não retorna exatamente `parser_tie_fix_acceptance_passed` ou deixa qualquer fixture persistida.
6. `crm-stevo-parser` fica ausente, duplicado, inativo, com schedule/command alterados, ou apresenta execução falha.
7. O backlog elegível cresce além do delta explicável pela ingestão, ou surge erro novo de parser/constraint.
8. O rollback não restaura exatamente `f6930a9d1ea153f2bb863e1ef8549087` / `8075`.
9. Qualquer comando pedir restart, mudança de flag, edição de job, fixture manual ou segunda tentativa de DDL fora da sequência acima.

Em qualquer stop condition: preservar os readbacks, não improvisar correção, não repetir a operação, e escalar com o erro/SQLSTATE, horário e baseline comparativo.
