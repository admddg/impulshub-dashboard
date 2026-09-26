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

-- 3) O consumidor e a matriz vigente estão implantados.
select event_code, platform, count(*) as existing_outbox_rows
from public.conversion_outbox co
join public.events_normalized en on en.id = co.normalized_event_id
where en.client_id = '<client_id>'::uuid
  and en.source_system = 'impuls_crm'
  and co.event_code in ('lead', 'agendado', 'ganho')
group by event_code, platform
order by event_code, platform;

rollback;
```

Não prossiga se `target_rows <> 1`, `target_off <> 1`, `ghl_events <> 0`, o
cliente ainda receber GHL, as migrations/contratos de IMP-215–218 não estiverem
confirmados, ou o consumidor não estiver pronto. A checagem de banco não prova
sozinha que o GHL foi desligado: obtenha também a confirmação operacional.

### Replay: ignorar é o padrão seguro

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

Reconcilie, sem DML de correção, a janela inteira a partir de
`conversion_outbox` → `events_normalized`. O relatório deve manter uma linha por
outbox e conter `event_code`, `platform`, `status`, `sent_at`,
`external_job_id`, `external_request_id`, `http_status`, `response`, origem e
identidade do evento:

```sql
select co.id as outbox_id,
       en.id as normalized_event_id, en.client_id, en.opportunity_id,
       en.event_code, en.source_system, en.created_at as event_created_at,
       co.platform, co.status, co.sent_at,
       co.external_job_id, co.external_request_id,
       co.http_status, co.response, co.last_error
from public.conversion_outbox co
join public.events_normalized en on en.id = co.normalized_event_id
where en.client_id = '<client_id>'::uuid
  and en.created_at >= '<janela_inicio>'::timestamptz
  and en.created_at <  '<janela_fim>'::timestamptz
order by en.opportunity_id, en.event_code, co.platform, co.created_at, co.id;
```

Faça a agregação numérica e a verificação de sobreposição entre `ghl` e
`impuls_crm`:

```sql
with pairs as (
  select en.event_code, co.platform,
         count(*) as outbox_rows,
         count(*) filter (where co.status='sent') as sent_rows,
         count(*) filter (where co.status='failed') as failed_rows,
         count(*) filter (where co.status='sent' and co.sent_at is null) as sent_without_sent_at,
         count(*) filter (where co.status='sent' and co.external_job_id is null
                                      and co.external_request_id is null) as sent_without_external_id,
         count(*) filter (where co.status='sent' and co.response is null) as sent_without_response
  from public.conversion_outbox co
  join public.events_normalized en on en.id=co.normalized_event_id
  where en.client_id='<client_id>'::uuid
    and en.created_at >= '<janela_inicio>'::timestamptz
    and en.created_at < '<janela_fim>'::timestamptz
  group by en.event_code, co.platform
), overlap as (
  select opportunity_id, event_code,
         count(distinct source_system) as source_count,
         count(*) as normalized_rows
  from public.events_normalized
  where client_id='<client_id>'::uuid
    and created_at >= '<janela_inicio>'::timestamptz
    and created_at < '<janela_fim>'::timestamptz
    and source_system in ('ghl','impuls_crm')
  group by opportunity_id, event_code
)
select 'pair' as check_type, event_code, platform,
       outbox_rows, sent_rows, failed_rows, sent_without_sent_at,
       sent_without_external_id, sent_without_response
from pairs
union all
select 'source_overlap', event_code, null,
       count(*) filter (where source_count > 1),
       count(*) filter (where normalized_rows > 1), 0, 0, 0, 0
from overlap
group by event_code;
```

`failed_rows`, `sent_without_sent_at`, `sent_without_external_id` e
`sent_without_response` devem ser zero para declarar sucesso; qualquer
`source_overlap` deve ser listado e explicado. `response` é evidência da
plataforma, não um booleano inferido de `status`. Preserve o relatório e
registre uma auditoria operacional de reconciliação; não apague nem reenvie
linhas para "consertar" a contagem.

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
