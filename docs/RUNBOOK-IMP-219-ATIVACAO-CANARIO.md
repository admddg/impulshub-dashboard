# Runbook IMP-219 — ativação canário de `crm_emits_conversions`

Este runbook é **fail-closed**. Ele documenta uma ativação por cliente, sem replay
implícito, sem lote, sem n8n e sem escrita fora da transação autorizada. Se uma
pré-condição, leitura, contagem ou retorno não for exatamente o esperado, pare.
Eventos aceitos por Meta/Google são irreversíveis; abortar interrompe novas
emissões, mas não desfaz o que já foi aceito.

## 1. Contrato e pré-flight obrigatório

A flag `public.clients_base.crm_emits_conversions` permite que
`crm.emit_opportunity_stage_event` grave na `public.conversion_outbox`. A ponte
não reenvia histórico por ligar a flag.

Antes de abrir a transação de ativação, execute em uma conexão somente leitura e
salve o resultado junto da autorização. Substitua somente os placeholders
`<client_id>`, `<janela_inicio>` e `<janela_fim>`; não substitua os predicados.

```sql
begin read only;

-- 1) O alvo existe, está desligado e há exatamente um alvo lógico.
select id, client_slug, client_name, crm_emits_conversions, updated_at
from public.clients_base
where id = '<client_id>'::uuid;

-- Deve retornar exatamente 1 linha e crm_emits_conversions=false.
select count(*) as target_rows,
       count(*) filter (where crm_emits_conversions = false) as target_off
from public.clients_base
where id = '<client_id>'::uuid;

-- 2) Não há emissão GHL recente para o cliente.
select count(*) as ghl_events
from public.events_normalized
where client_id = '<client_id>'::uuid
  and source_system = 'ghl'
  and created_at >= now() - interval '7 days';
-- Critério: ghl_events = 0, além da confirmação operacional de desligamento.

-- 3) Contratos de IMP-216/217/218 observáveis no banco.
select table_name, column_name
from information_schema.columns
where (table_schema, table_name, column_name) in (
  ('public', 'events_normalized', 'valor_ganho'),
  ('public', 'events_normalized', 'currency'),
  ('public', 'events_normalized', 'value_status'),
  ('public', 'conversion_outbox', 'platform'),
  ('public', 'conversion_outbox', 'payload'),
  ('public', 'conversion_outbox', 'external_request_id'),
  ('public', 'conversion_outbox', 'external_job_id')
)
order by table_name, column_name;
-- Critério: todas as 7 linhas retornam. Ausência é bloqueio.

select indexname
from pg_indexes
where schemaname = 'public'
  and tablename = 'conversion_outbox'
  and indexname in ('conversion_outbox_event_platform_uidx',
                    'conversion_outbox_normalized_event_id_platform_route_meta_e_key');
-- Critério: os índices de deduplicação esperados retornam; ausência é bloqueio.

select routine_schema, routine_name
from information_schema.routines
where routine_schema = 'crm'
  and routine_name = 'emit_opportunity_stage_event';
-- Critério: exatamente 1 função viva; confirme a assinatura com pg_get_functiondef.

-- 4) O consumidor IMP-215 não pode ser presumido por esta consulta.
select 'MANUAL_EVIDENCE_REQUIRED' as consumer_readiness,
       'workflow export/version + active-state screenshot + last successful execution + imp215 harness output' as exact_evidence;
-- Cole as referências desses quatro artefatos na autorização. Sem eles, pare.

rollback;
```

Não prossiga se `target_rows <> 1`, `target_off <> 1`, `ghl_events <> 0`, o
cliente ainda receber GHL, alguma linha/índice/função do contrato faltar, ou a
evidência manual de prontidão do consumidor não estiver anexada. O SQL acima
prova apenas os objetos de banco; **não afirma que IMP-215–218 estão aplicados
nem que o workflow está pronto**. Para cada contrato, anexe o resultado do
acceptance harness correspondente (`imp216-acceptance.sql`,
`imp217-acceptance.sql`, `imp218-acceptance.sql`) e, para IMP-215, o output de
`n8n/acceptance/imp215_contract_harness.py` e o export/versionamento do
consumidor. Se esses artefatos não puderem ser obtidos, registre exatamente
`manual evidence missing: <artefato>` e pare; não marque o pre-flight como
executável ou verde.

### Replay: ignorar é o padrão seguro

`replay_decision = ignore` é o **replay default** desta ativação.

O padrão desta ativação é **ignorar o histórico acumulado**. Ligar a flag não
faz replay e não autoriza reprocessar linhas antigas `failed`/`pending`. Replay
só pode ocorrer em tarefa separada, com plano, deduplicação, aprovação e teste
próprios; se houver dúvida, não faça replay e não ative. Registre
`replay_decision = ignore` na auditoria. A decisão de replay não pode ser
silenciosamente inferida de uma contagem.

## 2. Ativação atômica, com retorno exato e auditoria posterior

Execute o bloco inteiro em **uma única conexão**, com `ON_ERROR_STOP=1`. A
atribuição `INTO STRICT` exige que o `UPDATE ... RETURNING` devolva exatamente
uma linha: zero ou mais de uma lança erro. Esse erro aborta a transação; a
conexão deve emitir `ROLLBACK` e a flag não pode ser considerada ativada.

A identidade da auditoria vem da linha retornada pelo `UPDATE`, não de
placeholders. O `SELECT` seguinte é o readback/prova pós-escrita. O insert de
sucesso só ocorre depois dessa prova; falha no readback ou no insert também
aborta tudo.

```sql
-- Invocação: psql --set=ON_ERROR_STOP=1 --file=ativacao-imp219.sql
begin;

-- Os valores de actor/motivo/referências abaixo são preenchidos antes de executar.
-- Não altere o WHERE nem remova INTO STRICT/RETURNING.
DO $activation$
DECLARE
  v_returned record;
  v_readback record;
BEGIN
  update public.clients_base
     set crm_emits_conversions = true,
         updated_at = now()
   where id = '<client_id>'::uuid
     and crm_emits_conversions = false
   returning id, client_slug, client_name, crm_emits_conversions, updated_at
        into strict v_returned;

  -- Prova/readback: a mesma identidade retornada agora está ligada.
  select id, client_slug, client_name, crm_emits_conversions, updated_at
    into strict v_readback
    from public.clients_base
   where id = v_returned.id
     and crm_emits_conversions = true;

  if v_readback.id is distinct from v_returned.id
     or v_readback.crm_emits_conversions is distinct from true then
    raise exception 'IMP-219 readback mismatch for returned client %', v_returned.id;
  end if;

  -- Somente depois do UPDATE + readback: auditoria de sucesso.
  insert into public.workflow_execution_logs (
    id, workflow_key, workflow_name, workflow_category,
    client_id, client_slug, client_name, status, stage,
    started_at, finished_at, metadata
  ) values (
    gen_random_uuid(),
    -- workflow_category allowed set: 'onboarding', 'events', 'dispatch',
    -- 'media_sync', 'backfill', 'other'.
    'manual-imp219-canary-activation',
    'IMP-219 - Ativação manual de crm_emits_conversions',
    'other', -- valor permitido pelo CHECK do schema; 'ops' é inválido
    v_readback.id, v_readback.client_slug, v_readback.client_name,
    'success', 'flag_enabled', now(), now(),
    jsonb_build_object(
      'actor', '<actor autorizado e executor>',
      'flag', 'crm_emits_conversions',
      'from', false,
      'to', true,
      'motivo', '<motivo da ativação>',
      'ghl_check_ref', '<referência do pre-flight>',
      'replay_decision', 'ignore',
      'replay_decision_ref', '<autorização/registro da decisão>',
      'returned_client_id', v_returned.id,
      'readback_client_id', v_readback.id
    )
  );
END
$activation$;

commit;
```

Após qualquer erro, não tente `COMMIT`: emita `ROLLBACK` na mesma conexão (ou
encerre a conexão, que deve desfazer a transação) e repita o pre-flight. Nunca
corrija cardinalidade com um `LIMIT 1`, remova a condição `false`, ou insira uma
auditoria de sucesso manualmente.

Leia de volta, em nova consulta somente leitura, a flag e a auditoria recém-criada;
o `returned_client_id`, `readback_client_id`, `client_id`, slug e nome devem ser
coerentes e a flag deve estar `true`. Se não houver exatamente uma auditoria de
sucesso correspondente, trate como falha e aborte a expansão.

## 3. Janela de canário

Ative um cliente por vez. A janela proposta é de 4–8 horas úteis e precisa
cobrir movimento real de cards. Antes da ativação, capture o baseline; durante
a janela, não reprocese o histórico. Observe Meta Events Manager/Google e o
banco. Não toque em workflows n8n.

O critério numérico principal é **event_code × platform**, usando somente os
códigos elegíveis `lead`, `agendado` e `ganho` e as plataformas `meta` e
`google_ads`. Para cada par, os eventos CRM elegíveis devem gerar exatamente
uma linha de outbox; `primeira_conversa` e `perdido` são inelegíveis e devem
ter zero linhas. `ganho` também exige valor/moeda conforme o contrato de
IMP-217.

Capture o baseline e a janela com esta consulta executável:

```sql
with eligible as (
  select en.event_code, p.platform, count(*)::bigint as eligible_events
  from public.events_normalized en
  cross join (values ('meta'::text), ('google_ads'::text)) as p(platform)
  where en.client_id = '<client_id>'::uuid
    and en.source_system = 'impuls_crm'
    and en.event_code in ('lead', 'agendado', 'ganho')
    and en.created_at >= '<janela_inicio>'::timestamptz
    and en.created_at <  '<janela_fim>'::timestamptz
  group by en.event_code, p.platform
), outbox as (
  select en.event_code, co.platform, count(*)::bigint as outbox_rows,
         count(*) filter (where co.status = 'sent')::bigint as sent_rows,
         count(*) filter (where co.status = 'failed')::bigint as failed_rows,
         count(*) filter (where co.status not in ('sent','failed'))::bigint as open_rows,
         count(*) filter (where co.status = 'sent' and co.sent_at is null)::bigint as sent_without_sent_at,
         count(*) filter (where co.status = 'sent'
                           and co.external_job_id is null
                           and co.external_request_id is null)::bigint as sent_without_external_id
  from public.conversion_outbox co
  join public.events_normalized en on en.id = co.normalized_event_id
  where en.client_id = '<client_id>'::uuid
    and en.source_system = 'impuls_crm'
    and en.created_at >= '<janela_inicio>'::timestamptz
    and en.created_at <  '<janela_fim>'::timestamptz
  group by en.event_code, co.platform
)
select e.event_code, e.platform, e.eligible_events,
       coalesce(o.outbox_rows,0) as outbox_rows,
       coalesce(o.sent_rows,0) as sent_rows,
       coalesce(o.failed_rows,0) as failed_rows,
       coalesce(o.open_rows,0) as open_rows,
       coalesce(o.sent_without_sent_at,0) as sent_without_sent_at,
       coalesce(o.sent_without_external_id,0) as sent_without_external_id,
       (coalesce(o.outbox_rows,0) = e.eligible_events) as exact_outbox_match
from eligible e
left join outbox o using (event_code, platform)
order by e.event_code, e.platform;
```

A janela só passa quando cada linha tem `exact_outbox_match = true`,
`failed_rows = 0`, `sent_without_sent_at = 0` e
`sent_without_external_id = 0`. Defasagem `open_rows > 0` é motivo para
investigar; não declare sucesso por aparência. Compare também os números
externos com o Events Manager e registre a resposta, sem inventar uma resposta
HTTP que não foi lida.

Para `ganho`, execute também este contrato numérico; texto explicativo não
substitui os contadores. Um ganho válido tem valor estritamente positivo,
`value_status='valid'`, moeda `BRL` e payload com os mesmos dois valores. Um
ganho pendente não pode criar outbox e deve ter valor/moeda nulos.

```sql
with gains as (
  select en.id, en.value_status, en.valor_ganho, en.currency,
         en.normalized_payload,
         count(co.id)::bigint as outbox_rows,
         count(*) filter (where co.id is not null and co.platform in ('meta','google_ads'))::bigint as eligible_outbox_rows
  from public.events_normalized en
  left join public.conversion_outbox co on co.normalized_event_id = en.id
  where en.client_id = '<client_id>'::uuid
    and en.source_system = 'impuls_crm'
    and en.event_code = 'ganho'
    and en.created_at >= '<janela_inicio>'::timestamptz
    and en.created_at <  '<janela_fim>'::timestamptz
  group by en.id, en.value_status, en.valor_ganho, en.currency, en.normalized_payload
), checks as (
  select *,
    (value_status = 'valid' and valor_ganho > 0 and currency = 'BRL'
      and normalized_payload->>'value' = valor_ganho::text
      and normalized_payload->>'currency' = 'BRL') as valid_contract,
    (value_status = 'pending' and valor_ganho is null and currency is null
      and outbox_rows = 0) as pending_contract
  from gains
)
select count(*) filter (where not (valid_contract or pending_contract))::bigint as ganho_contract_violations,
       count(*) filter (where value_status = 'valid' and outbox_rows <> 2)::bigint as valid_ganho_outbox_count_violations,
       count(*) filter (where value_status = 'pending' and outbox_rows <> 0)::bigint as pending_ganho_outbox_count_violations,
       count(*) filter (where value_status = 'valid' and eligible_outbox_rows <> 2)::bigint as valid_ganho_platform_violations
from checks;
```

Todos os quatro contadores devem ser `0`. Se a política aprovada para ganho
pendente for diferente, registre a decisão e ajuste o critério antes da janela;
não aceite uma linha sem valor por inferência.

## 4. Abortar integralmente

Aborte imediatamente se surgir qualquer evento GHL, duplicidade provável,
linha nova `failed`, mismatch numérico event_code × platform, ausência de
`sent_at`/ID externo em linha `sent`, resposta de plataforma com erro, queda de
match quality ou dúvida sobre duplicidade. Primeiro pare novas emissões; depois
investigue. Para desligar o canário, use a mesma disciplina fail-closed:

```sql
begin;
DO $abort$
DECLARE
  v_returned record;
  v_readback record;
BEGIN
  update public.clients_base
     set crm_emits_conversions = false,
         updated_at = now()
   where id = '<client_id>'::uuid
     and crm_emits_conversions = true
   returning id, client_slug, client_name, crm_emits_conversions, updated_at
        into strict v_returned;

  select id, client_slug, client_name, crm_emits_conversions
    into strict v_readback
    from public.clients_base
   where id = v_returned.id and crm_emits_conversions = false;

  insert into public.workflow_execution_logs (
    id, workflow_key, workflow_name, workflow_category, client_id,
    client_slug, client_name, status, stage, started_at, finished_at, metadata
  ) values (
    gen_random_uuid(), 'manual-imp219-canary-abort',
    'IMP-219 - Abortar canário', 'other',
    v_readback.id, v_readback.client_slug, v_readback.client_name,
    'success', 'flag_disabled', now(), now(),
    jsonb_build_object(
      'actor', '<actor autorizado e executor>',
      'reason', '<critério de abortar e referência das leituras>',
      'returned_client_id', v_returned.id,
      'readback_client_id', v_readback.id
    )
  );
END
$abort$;
commit;
```

Também aqui `INTO STRICT`, readback e auditoria são obrigatórios. Cardinalidade
diferente de um, erro de readback ou erro de auditoria exige `ROLLBACK`; nunca
force o estado com `LIMIT 1`. O abort é completo quanto a novas emissões; ele
não apaga outbox, eventos normalizados, nem eventos aceitos externamente.

## 5. Reconciliação pós-canário

Reconcilie, sem DML de correção, **toda a janela de `conversion_outbox`** usando
`co.created_at`, e não apenas eventos que conseguiram fazer join. O `left join`
é deliberado: um outbox órfão precisa aparecer como `orphaned_outbox`, com a
identidade desconhecida, em vez de desaparecer. A consulta também emite as
linhas esperadas com zero outbox para códigos inelegíveis, e marca plataforma
não suportada, duplicidade e excedente por linha.

```sql
with params as (
  select '<janela_inicio>'::timestamptz as start_at,
         '<janela_fim>'::timestamptz as end_at,
         '<client_id>'::uuid as client_id
), allowed_events(event_code, eligible) as (
  values ('lead', true), ('primeira_conversa', false), ('agendado', true),
         ('ganho', true), ('perdido', false)
), supported_platforms(platform) as (
  values ('meta'), ('google_ads')
), events_in_window as (
  select en.*
  from public.events_normalized en, params p
  where en.client_id = p.client_id
    and en.source_system = 'impuls_crm'
    and en.created_at >= p.start_at and en.created_at < p.end_at
), event_counts as (
  select event_code, count(*)::bigint as eligible_events
  from events_in_window
  group by event_code
), outbox_window as (
  select co.*, en.id as normalized_event_id, en.client_id, en.opportunity_id,
         en.event_code, en.source_system, en.created_at as event_created_at,
         row_number() over (partition by co.normalized_event_id, co.platform
                            order by co.created_at, co.id) as duplicate_number,
         count(*) over (partition by co.normalized_event_id, co.platform) as duplicate_count,
         count(*) over (partition by en.event_code, co.platform) as pair_outbox_rows,
         coalesce(ec.eligible_events, 0)::bigint as pair_eligible_events
  from public.conversion_outbox co
  left join public.events_normalized en on en.id = co.normalized_event_id
  left join event_counts ec on ec.event_code = en.event_code
  cross join params p
  where co.created_at >= p.start_at and co.created_at < p.end_at
), classified as (
  select ow.*,
    case
      when ow.normalized_event_id is null then 'orphaned_outbox'
      when ow.event_code not in (select event_code from allowed_events) then 'unsupported_event_code'
      when ow.platform not in (select platform from supported_platforms) then 'unsupported_platform'
      when ow.event_code in ('primeira_conversa', 'perdido') then 'ineligible_event_code'
      when ow.duplicate_count > 1 and ow.duplicate_number > 1 then 'duplicate'
      when ow.pair_outbox_rows > ow.pair_eligible_events then 'surplus'
      else 'eligible_match'
    end as row_category
  from outbox_window ow
), expected as (
  select ae.event_code, sp.platform, ae.eligible,
         count(eiw.id)::bigint as eligible_events
  from allowed_events ae
  cross join supported_platforms sp
  left join events_in_window eiw on eiw.event_code = ae.event_code
  group by ae.event_code, sp.platform, ae.eligible
), expected_report as (
  select 'expected_pair' as report_type, e.event_code, e.platform,
         0::bigint as outbox_rows, e.eligible_events,
         case when e.eligible then e.eligible_events else 0 end as expected_outbox_rows,
         case when e.eligible then 0 else 0 end::bigint as ineligible_zero_outbox,
         null::text as row_category
  from expected e
), row_report as (
  select 'outbox_row' as report_type, c.event_code, c.platform,
         count(*)::bigint as outbox_rows, null::bigint as eligible_events,
         null::bigint as expected_outbox_rows, null::bigint as ineligible_zero_outbox,
         c.row_category
  from classified c
  group by c.event_code, c.platform, c.row_category
)
select * from expected_report
union all
select * from row_report
order by report_type, event_code nulls first, platform nulls first;
```

The `row_category` column is part of the `expected_report`/`row_report` union;
do not drop it while aggregating. The detailed category query below is scoped to
the target client so another client's rows cannot inflate duplicate or surplus
counts in the canary.

The `expected_pair` rows for `primeira_conversa` and `perdido` must report
`expected_outbox_rows = 0` and the matching `outbox_row` count must be zero.
Rows with `row_category` are retained in the detailed report below, including
zero-count category rows, so unsupported platforms, duplicates, surplus rows
and orphans cannot be hidden by an inner join:

```sql
with params as (
  select '<client_id>'::uuid as client_id,
         '<janela_inicio>'::timestamptz as start_at,
         '<janela_fim>'::timestamptz as end_at
), categories(category) as (
  values ('orphaned_outbox'), ('ineligible_event_code'),
         ('unsupported_platform'), ('duplicate'), ('surplus'),
         ('unsupported_event_code'), ('eligible_match')
), classified as (
  select co.id as outbox_id, en.id as normalized_event_id, en.client_id,
         en.opportunity_id, en.event_code, co.platform, co.status, co.sent_at,
         co.external_job_id, co.external_request_id, co.http_status,
         co.response, co.last_error,
         count(*) over (partition by en.event_code, co.platform) as pair_outbox_rows,
         coalesce(ec.eligible_events, 0)::bigint as pair_eligible_events,
         case
           when en.id is null then 'orphaned_outbox'
           when co.platform not in ('meta', 'google_ads') then 'unsupported_platform'
           when en.event_code in ('primeira_conversa', 'perdido') then 'ineligible_event_code'
           when count(*) over (partition by co.normalized_event_id, co.platform) > 1 then 'duplicate'
           when en.event_code not in ('lead', 'agendado', 'ganho') then 'unsupported_event_code'
           when count(*) over (partition by en.event_code, co.platform)
                > coalesce(ec.eligible_events, 0)
             then 'surplus'
           else 'eligible_match'
         end as category
  from public.conversion_outbox co
  left join public.events_normalized en on en.id = co.normalized_event_id
  left join (
    select event_code, count(*)::bigint as eligible_events
    from public.events_normalized en_count
    cross join params p_count
    where en_count.client_id = p_count.client_id
      and en_count.source_system = 'impuls_crm'
      and en_count.event_code in ('lead', 'agendado', 'ganho')
      and en_count.created_at >= p_count.start_at
      and en_count.created_at < p_count.end_at
    group by event_code
  ) ec on ec.event_code = en.event_code
  cross join params p
  where en.client_id = p.client_id
    and co.created_at >= p.start_at
    and co.created_at < p.end_at
)
select c.category, count(x.outbox_id)::bigint as outbox_rows,
       count(x.outbox_id) filter (where x.status = 'failed')::bigint as failed_rows,
       count(x.outbox_id) filter (where x.status = 'sent' and x.sent_at is null)::bigint as sent_without_sent_at,
       count(x.outbox_id) filter (where x.status = 'sent' and x.external_job_id is null and x.external_request_id is null)::bigint as sent_without_external_id,
       count(x.outbox_id) filter (where x.status = 'sent' and x.response is null)::bigint as sent_without_response
from categories c
left join classified x on x.category = c.category
group by c.category
order by c.category;
```

Verifique também a sobreposição de fontes sem perder linhas órfãs do relatório
principal:

```sql
select opportunity_id, event_code,
       count(distinct source_system)::bigint as source_count,
       count(*)::bigint as normalized_rows
from public.events_normalized
where client_id = '<client_id>'::uuid
  and created_at >= '<janela_inicio>'::timestamptz
  and created_at < '<janela_fim>'::timestamptz
  and source_system in ('ghl', 'impuls_crm')
group by opportunity_id, event_code
having count(distinct source_system) > 1 or count(*) > 1;
```

Qualquer linha retornada é `source_overlap` e bloqueia a expansão até ser
explicada. Essa consulta é complementar: não substitui o `left join` sobre a
janela de outbox.

For the target client, additionally run the following numeric assertion. It
uses the complete eligible set and fails closed if any expected pair is missing,
has a duplicate, or has surplus rows; it also reports all invalid categories.

```sql
with expected as (
  select en.event_code, p.platform, count(*)::bigint as expected_rows
  from public.events_normalized en
  cross join (values ('meta'::text), ('google_ads'::text)) p(platform)
  where en.client_id = '<client_id>'::uuid
    and en.source_system = 'impuls_crm'
    and en.event_code in ('lead', 'agendado', 'ganho')
    and en.created_at >= '<janela_inicio>'::timestamptz
    and en.created_at < '<janela_fim>'::timestamptz
  group by en.event_code, p.platform
), actual as (
  select en.event_code, co.platform, count(*)::bigint as actual_rows
  from public.conversion_outbox co
  left join public.events_normalized en on en.id = co.normalized_event_id
  where en.client_id = '<client_id>'::uuid
    and co.created_at >= '<janela_inicio>'::timestamptz
    and co.created_at < '<janela_fim>'::timestamptz
  group by en.event_code, co.platform
)
select e.event_code, e.platform, e.expected_rows, coalesce(a.actual_rows, 0) as actual_rows,
       coalesce(a.actual_rows, 0) - e.expected_rows as delta,
       (coalesce(a.actual_rows, 0) = e.expected_rows) as exact_match
from expected e left join actual a using (event_code, platform)
union all
select 'unexpected'::text, a.platform, 0, a.actual_rows, a.actual_rows, false
from actual a left join expected e using (event_code, platform)
where e.event_code is null or a.actual_rows > e.expected_rows;
```

Every `exact_match` must be true and the final query must return no
`unexpected` row. `failed_rows`, `sent_without_sent_at`,
`sent_without_external_id` and `sent_without_response` must be zero; preserve
the report and record source overlap between `ghl` and `impuls_crm`. `response`
is platform evidence, not a boolean inferred from `status`. Never delete or
resend rows to "fix" a count.

## 6. Checklist de expansão

- [ ] pré-flight retornou exatamente um alvo desligado e zero GHL recente;
- [ ] consumidor IMP-215 e contratos IMP-216/217/218 foram confirmados;
- [ ] replay foi registrado como `ignore` (ou existe plano separado aprovado);
- [ ] ativação usou `UPDATE ... WHERE ... AND crm_emits_conversions=false RETURNING` com `INTO STRICT`;
- [ ] identidade veio do retorno e o readback ocorreu antes do audit success;
- [ ] qualquer cardinalidade diferente de um abortou/fez rollback;
- [ ] cada par numérico `event_code × platform` bateu exatamente;
- [ ] reconciliação guardou status, sent_at, IDs externos e response;
- [ ] nenhum n8n, deploy, merge ou dado real foi alterado por este trabalho.

A expansão só é autorizada após a janela completa, critérios numéricos verdes,
reconciliação lida e aprovação explícita do próximo cliente.
