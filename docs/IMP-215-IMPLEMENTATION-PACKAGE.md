# IMP-215 — pacote implementável do claim dispatcher

**Escopo desta entrega:** somente documentação e plano de patch. Não publica/importa/ativa n8n, não altera exports em `Downloads`, não liga flags, não executa claim/dispatch, não envia eventos e não escreve em produção ou staging.

## 1. Veredicto de schema

**Não é necessária migration de schema para o claim mínimo.** A tabela já possui os campos suficientes para uma posse curta:

- `status text NOT NULL`;
- `attempts integer NOT NULL DEFAULT 0`;
- `next_attempt_at timestamptz`;
- `updated_at timestamptz`;
- `last_error`, `response`, `sent_at`, `external_job_id`, `external_request_id` e campos de resultado;
- índice `idx_conversion_outbox_platform_status_next (platform, status, next_attempt_at)`;
- índice `idx_conversion_outbox_status_created (status, created_at DESC)`.

A definição viva não tem `CHECK`, trigger ou outra constraint que restrinja os valores de `status`; portanto `processing` é aceito estruturalmente. A posse será identificada por `status='processing'` + `attempts=<claimed_attempt>` e limitada por `next_attempt_at` como deadline de lease. Não criar `lease_token`, `claimed_at` ou outra coluna neste pacote.

**Limite explícito:** sem token/coluna de geração, o desenho não deve rebaixar automaticamente um `processing` expirado para `pending` nem disparar novo HTTP. A recuperação segura é marcar como `failed` com `claim_lease_expired_external_state_unknown` sem reenviar, após decisão operacional. Assim, não há necessidade de interromper por migration, mas a política de lease não pode prometer retry automático sem schema adicional e decisão do Head.

## 2. Evidência read-only

### Produção — projeto `mtxnwtqwfagjzkvgsncs`

Probe executado em transação `BEGIN READ ONLY`, identidade observada `current_user=postgres`, `session_user=cli_login_postgres`, finalizada com rollback. Resultado:

- `public.conversion_outbox`: 31 colunas;
- não há `source_system` nem `client_id` na outbox;
- `ghl_location_id`, `route` e `meta_event_name` são nullable em produção;
- constraints: PK `id` e unicidades por evento/plataforma/rota; nenhuma constraint de status;
- triggers de usuário: nenhuma;
- status presentes: `failed=43`, `pending=512`, `sent=2346`, `skipped=1304`; `processing=0` no momento da leitura;
- o índice único vivo `conversion_outbox_event_platform_uidx (normalized_event_id, platform)` está presente;
- não há coluna de lease dedicada.

### Staging — projeto `nfratueiutxnypbxfnmi`

Probe executado com a mesma transação read-only e rollback. O schema também possui 31 colunas, `status` sem constraint/triggers, `attempts`, `next_attempt_at`, `updated_at` e os índices de varredura. A tabela estava sem linhas no momento da leitura e, neste staging, `ghl_location_id`, `route` e `meta_event_name` são `NOT NULL`; isto não altera a decisão do claim, mas impede usar staging vazio como prova de payload completo.

## 3. Pacote de arquivos a implementar depois da autorização

Os exports reais devem ser copiados para uma área versionada do repositório antes de qualquer edição; os arquivos originais em `C:/Users/caiop/Downloads/` permanecem intactos.

### 3.1 Dispatcher Meta — cópia versionada de `1.2`

Arquivo planejado: `n8n/workflows/IMP-215-dispatch-single-meta-claim.json`.

Patch mínimo:

1. Normalizar a entrada para `outbox_id`, `dispatch_mode` (`inline|scheduled`) e `claimed_attempt` quando agendado.
2. Substituir o `Get Single Meta Outbox` por uma operação de claim inline quando `dispatch_mode='inline'`.
3. Para `scheduled`, não incrementar `attempts`; reler e validar a posse com o predicado de lease abaixo.
4. Montar a request Meta somente da linha relida; entrada do chamador nunca é autoridade para payload/rota/evento.
5. Fazer o fechamento condicional e tratar `0 rows` como `stale_result`, sem novo HTTP e sem converter para `sent`/`failed`.

### 3.2 Dispatcher Google — cópia versionada de `1.3`

Arquivo planejado: `n8n/workflows/IMP-215-dispatch-single-google-claim.json`.

Aplicar exatamente a mesma máquina de claim/fechamento, preservando a exceção existente de credencial Google (`pending` com janela de 6h) e a montagem específica Data Manager API. Não reutilizar payload Meta.

### 3.3 Consumidor agendado

Arquivo planejado: `n8n/workflows/IMP-215-scheduled-conversion-outbox-consumer.json`.

Fluxo mínimo: Schedule a cada 1 minuto, concorrência efetiva 1, lote pequeno por plataforma (10 inicialmente), consulta read-only de candidatos, claim transacional, split por plataforma, Execute Workflow sem payload fabricado e log sanitizado. A primeira execução real deve ser precedida por dry-run que só conta candidatos.

## 4. SQL do patch

### 4.1 Candidatos — sempre por join, allowlist e cutoff

`conversion_outbox` não contém origem/cliente. O consumidor deve resolver ambos via `events_normalized` e `clients_base`/configuração versionada. O `cutoff_at` é obrigatório por cliente e não pode ter default móvel.

```sql
select
  co.id,
  co.platform,
  co.attempts,
  co.next_attempt_at,
  en.client_id,
  c.cutoff_at
from public.conversion_outbox as co
join public.events_normalized as en
  on en.id = co.normalized_event_id
join imp215_dispatch_cutoff as c
  on c.client_id = en.client_id
where co.platform = :expected_platform
  and co.status in ('pending', 'failed')
  and co.created_at >= c.cutoff_at
  and co.next_attempt_at <= now()
  and co.attempts < :max_attempts
  and en.source_system = 'impuls_crm'
  and en.client_id = any(:allowlisted_client_ids)
order by co.created_at asc, co.id asc
limit :batch_size;
```

`imp215_dispatch_cutoff` acima é um nome lógico de configuração do workflow, não uma recomendação para criar tabela. Se o n8n não tiver fonte segura/versionada para esse mapa, o workflow deve abortar fechado; não inventar cutoff nem selecionar por data global.

### 4.2 Claim agendado — uma atualização, uma tentativa

Implementar como query parametrizada em transação do nó Postgres. O caminho efetivo deve manter o join/filtros da consulta de candidatos dentro do `UPDATE`; não fazer `SELECT` e depois `UPDATE` desprotegidos.

```sql
with claimed as (
  update public.conversion_outbox as co
     set status = 'processing',
         attempts = co.attempts + 1,
         next_attempt_at = now() + interval '30 minutes',
         updated_at = now()
    from public.events_normalized as en
   where co.id = :outbox_id
     and en.id = co.normalized_event_id
     and co.platform = :expected_platform
     and co.status in ('pending', 'failed')
     and co.created_at >= :cutoff_at
     and co.next_attempt_at <= now()
     and co.attempts < :max_attempts
     and en.source_system = 'impuls_crm'
     and en.client_id = any(:allowlisted_client_ids)
  returning co.id, co.platform, co.attempts as claimed_attempt
)
select id, platform, claimed_attempt from claimed;
```

O segundo dispatcher que receber zero linhas não chama HTTP. O prazo de 30 minutos é parâmetro de lease e deve ser maior que o timeout máximo real do dispatcher; validar esse valor no teste de integração antes de ativar.

### 4.3 Claim inline nos dispatchers

```sql
with claimed as (
  update public.conversion_outbox as co
     set status = 'processing',
         attempts = co.attempts + 1,
         next_attempt_at = now() + interval '30 minutes',
         updated_at = now()
   where co.id = :outbox_id
     and co.platform = :expected_platform
     and co.status = 'pending'
     and co.next_attempt_at <= now()
     and co.attempts < :max_attempts
  returning co.id, co.attempts as claimed_attempt
)
select * from claimed;
```

O `1.1` continua `waitForSubWorkflow=false`, mas passa `outbox_id` e `dispatch_mode='inline'`. O filho que perder o claim termina sem HTTP.

### 4.4 Leitura agendada e fechamento

```sql
select co.*
from public.conversion_outbox as co
where co.id = :outbox_id
  and co.platform = :expected_platform
  and co.status = 'processing'
  and co.attempts = :claimed_attempt
  and co.next_attempt_at > now();
```

```sql
update public.conversion_outbox as co
   set status = :computed_status,
       response = :sanitized_response,
       last_error = :last_error,
       sent_at = case when :computed_status = 'sent' then now() else co.sent_at end,
       next_attempt_at = :next_attempt_at,
       updated_at = now()
 where co.id = :outbox_id
   and co.status = 'processing'
   and co.attempts = :claimed_attempt
returning co.id, co.status, co.attempts, co.next_attempt_at;
```

O fechamento não incrementa `attempts`. `0 rows` significa `stale_result`: não registrar sucesso/falha da tentativa antiga e não repetir HTTP.

## 5. Testes de aceitação antes de qualquer ativação

Os testes devem usar linhas sintéticas em ambiente seguro ou mocks do dispatcher; nunca usar as 512 `pending`/43 `failed` históricas como carga de envio.

1. **Schema/status:** inserir/atualizar uma fixture autorizada para `status='processing'`; confirmar que não há erro de constraint/trigger. Rollback ao final.
2. **Claim concorrente:** duas transações disputam a mesma linha elegível; exatamente uma obtém `RETURNING`, `attempts` sobe uma vez e apenas uma chama o dispatcher.
3. **Corrida `1.1` × agendado:** após claim agendado, o caminho inline encontra `status <> pending` e faz zero HTTP.
4. **Lease/attempt:** dispatcher agendado aceita somente `processing` + `attempts=claimed_attempt` + `next_attempt_at > now()`; ID correto com tentativa velha, lease expirado, plataforma errada e status terminal retornam zero linhas.
5. **Resposta velha:** uma tentativa antiga executa o `UPDATE` depois de mudança de estado; `row_count=0`, sem sobrescrever `sent`, `failed` ou nova tentativa.
6. **Terminalidade:** `sent` e `skipped` nunca são candidatos; `failed` fora do cutoff nunca é candidato nem sofre alteração.
7. **Corte/allowlist:** candidato anterior ao cutoff, cliente fora da allowlist, `source_system <> 'impuls_crm'` e cliente sem cutoff produzem zero claim e zero HTTP; ausência de cutoff aborta fechado.
8. **Plataformas:** `meta` chama somente `1.2`; `google_ads` chama somente `1.3`; os campos `platform_event_name`/`platform_conversion_action` chegam literalmente ao Google.
9. **Retry existente:** 429/5xx/timeout preservam `pending` + backoff Meta; quarta tentativa transitória vira `failed`; credencial Google preserva `pending` com backoff de 6h. Nenhum fechamento incrementa duas vezes.
10. **Lease expirado:** recuperação transforma `processing` expirado em `failed` com `claim_lease_expired_external_state_unknown` e zero HTTP automático.
11. **Observabilidade:** logs têm contadores e IDs sem payload/segredo; a outbox contém o resultado sanitizado e os IDs externos quando fornecidos.
12. **Regressão estrutural:** exports originais em Downloads têm hash/conteúdo inalterado; `git diff --check` passa; nenhum arquivo de produção, migration ou flag foi alterado nesta preparação.

## 6. Artefatos versionados desta etapa

Os exports reais foram copiados somente de `C:/Users/caiop/Downloads/` para a área versionada abaixo; os originais não foram editados:

- `n8n/workflows/IMP-215-dispatch-single-meta-claim.json` — cópia inativa do `1.2`, com `inline` preservado e modo `scheduled` protegido por `processing + claimed_attempt + lease`; o builder Meta, a classificação de respostas e o retry existente foram mantidos.
- `n8n/workflows/IMP-215-dispatch-single-google-claim.json` — cópia inativa do `1.3`, com a mesma guarda; o builder Data Manager, a exceção de credencial Google e os retries existentes foram mantidos.
- `n8n/workflows/IMP-215-scheduled-conversion-outbox-consumer.json` — consumidor novo, inativo e `dry_run=true`, com allowlist/cutoff obrigatórios, join por `events_normalized`, consulta somente-leitura e relatório; não contém `Execute Workflow` nem nó HTTP.
- `n8n/acceptance/imp215_contract_harness.py` — harness local de contrato com testes negativos de cutoff, allowlist, origem, terminalidade e limite de tentativas, além de preservação estrutural dos builders/retries.

O modo agendado não incrementa `attempts` no fechamento (o claim já incrementou) e fecha somente se `status='processing'`, `attempts=claimed_attempt` e lease ainda válido. Resultado velho retorna zero linhas. O caminho `inline` continua usando os predicados e o fechamento/retry do export.

## 7. Gates que não podem ser provados sem execução n8n

- O SQL de claim transacional (`UPDATE ... RETURNING`) e a concorrência efetiva `SKIP LOCKED` ainda precisam de prova em ambiente seguro; o consumidor versionado permanece somente dry-run até essa prova.
- A compatibilidade do estado `processing` com o dispatcher vivo, o timeout real para calibrar o lease de 30 minutos e a resolução dos IDs de `Execute Workflow` precisam ser confirmados por import/execução controlada. Não foram inferidos nem publicados.
- Não há teste de API Meta/Google, credencial, flag, escrita em staging/produção ou envio real nesta etapa. Esses são gates de ativação, não resultados alegados.

## 8. Gatilhos de parada

Parar e pedir decisão do Head se surgir qualquer requisito de: coluna/token de lease, retry automático após estado externo ambíguo, alteração do cutoff, re-drive de `failed`, escrita fora de staging, publicação/ativação n8n ou teste que possa enviar Meta/Google. Este pacote deliberadamente não executa nenhum desses efeitos.
