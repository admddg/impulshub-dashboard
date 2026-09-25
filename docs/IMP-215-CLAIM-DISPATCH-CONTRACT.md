# IMP-215 — contrato fechado `claim → dispatcher`

**Status:** implemented inactive artifact. Claim, lease, protected closure, and platform-routed child dispatch are versioned, but default `dry_run=true` and `dispatch_enabled=false` remain in force; no workflow is activated and no external send occurs.

**Base:** commit `85451ac`; exports reais em `C:/Users/caiop/Downloads/`:

- `1.1 - Inbound Events - Normalize + Conversion Router - Observability V2.1 - Meta Attribution Fix.json`
- `1.2 - Dispatch Single Meta Conversion - Observability V2.4 - Standard Route Scope Fix.json`
- `1.3 - Dispatch Single Google Ads Conversion - Observability V2.1 - Managed Node Errors.json`

## 1. Decisão recomendada

Adotar um contrato único em que **o dispatcher é a última barreira de claim antes da chamada externa**, inclusive no caminho síncrono do `1.1`. O consumidor agendado pode fazer um claim antecipado, mas o dispatcher só envia se confirmar que a linha continua pertencendo àquela tentativa.

Não criar outro registro de outbox nem reescrever a montagem das requisições Meta/Google. O menor patch é nos três workflows:

1. `1.1`: manter os dois `Execute Workflow` com `waitForSubWorkflow=false`; passar explicitamente `dispatch_mode='inline'` (ou equivalente) e `outbox_id`.
2. `1.2` e `1.3`: aceitar dois modos de entrada e fazer claim/validação condicional; proteger o `UPDATE` final por estado e número da tentativa.
3. Novo consumidor agendado: selecionar apenas linhas permitidas, em `pending` elegível, e fazer `pending → processing` atomicamente antes de chamar o dispatcher, passando `dispatch_mode='scheduled'` e `claimed_attempt`.

O status `processing` é necessário para tornar a posse observável. Antes de implementar, confirmar na definição viva de `public.conversion_outbox` que não existe `CHECK` que o rejeite. Se existir, parar: a alternativa exige função/alteração de schema aprovada, não um bypass no n8n.

### Contrato de entrada

```text
outbox_id: UUID obrigatório
platform: implícita pelo dispatcher; o dispatcher valida a plataforma da linha
 dispatch_mode: inline | scheduled
claimed_attempt: inteiro; obrigatório quando dispatch_mode=scheduled
```

O dispatcher sempre relê a linha pelo `outbox_id`. Campos de payload, rota, evento e configuração recebidos do chamador não são autoridade; servem apenas como contexto/log. A requisição deve continuar sendo montada pelos próprios nós `Build Meta Request`/`Build Data Manager Request` a partir da linha relida.

## 2. Fatos observados nos exports reais

### `1.1`

- `Prepare Platform Dispatch Input` só define `should_dispatch*` quando `outbox_status === 'pending'`.
- Os dois ramos chamam os workflows por `Execute Workflow`.
- `Call 03 - Dispatch Meta Conversion` usa workflow ID `6XuyBnwOVWOVl2g7`; `Call 04 - Dispatch Google Ads Conversion` usa `eIDYXgy90yGh3KPQ`.
- Ambos têm `options.waitForSubWorkflow=false` e `workflowInputs.value={}`. Portanto, o `1.1` não aguarda o resultado do dispatcher e seu fechamento não é confirmação de entrega externa.
- O `1.1` marca/loga o processamento principal como concluído sem depender do resultado Meta/Google.

### `1.2` Meta

- `Get Single Meta Outbox` relê por ID, exige `platform='meta'`, `status='pending'` e `next_attempt_at <= now()`.
- `Update Single Meta Outbox Result` faz `where id = ...` sem guarda de estado, sem guarda de tentativa e sem conferir quantidade de linhas afetadas.
- O update incrementa `attempts` (`attempts = attempts + 1`). Para resposta transitória, o fluxo retorna `pending`; após a quarta tentativa efetiva, o update converte a linha para `failed`.
- Erros 429/5xx são classificados para retry; rejeições não transitórias viram `failed`. Os atrasos observados são 15 minutos, 1 hora e 6 horas.
- O dispatcher monta a requisição Meta a partir da linha relida; não deve receber payload fabricado do consumidor.

### `1.3` Google Ads

- `Get Single Google Outbox` também relê por ID, exige `platform='google_ads'`, `status='pending'` e `next_attempt_at <= now()`.
- `Update Single Google Outbox Result` também faz `where id = ...` sem guarda de estado/tentativa e incrementa `attempts` no fechamento.
- HTTP 429/5xx e falhas de transporte retornam `pending`; erro de API não transitório retorna `failed`.
- Falha de credencial mantém `pending` mesmo após o limite, com retry de 6 horas; isso é uma exceção operacional existente e precisa permanecer explícita no contrato, não ser convertida silenciosamente em DLQ.
- `validateOnly` pode produzir `skipped`; `sent` não deve voltar a ser candidato.

## 3. Risco que o patch precisa eliminar

Há duas corridas independentes:

1. **Consumidor versus `1.1`:** ambos podem observar a mesma linha `pending` antes de qualquer atualização e disparar chamadas externas.
2. **Chamadas concorrentes versus fechamento:** uma resposta atrasada pode executar o `UPDATE ... WHERE id` depois que outra tentativa já mudou o estado, sobrescrevendo `sent`, `failed` ou uma nova tentativa.

O índice único por evento/plataforma não resolve nenhuma dessas corridas: ele impede uma segunda linha, não um segundo envio da mesma linha.

A corrida não é resolvida apenas trocando o filtro para `status in ('pending','processing')`. Sem uma identidade de tentativa (`claimed_attempt`) e sem `WHERE status='processing' AND attempts=...`, uma resposta velha ainda pode finalizar uma tentativa nova.

## 4. Patch mínimo nos dispatchers

### 4.1 Claim inline dentro de `1.2` e `1.3`

No caminho `dispatch_mode='inline'`, substituir a leitura simples por uma operação que, na mesma transação lógica do Postgres, faça:

```sql
with claimed as (
  update public.conversion_outbox
  set
    status = 'processing',
    attempts = attempts + 1,
    next_attempt_at = now() + interval '30 minutes',
    updated_at = now()
  where id = :outbox_id
    and platform = :expected_platform
    and status = 'pending'
    and next_attempt_at <= now()
    and attempts < 4
  returning id, attempts as claimed_attempt
)
select ... from claimed ...;
```

A seleção completa deve manter os joins e campos atuais de cada dispatcher. Se `RETURNING` não produzir linha, o dispatcher termina sem HTTP e registra `claim_lost`/`not_eligible`; não pode tratar isso como `sent`, `failed` ou novo retry.

O `1.1` continua fire-and-forget. A mudança é que cada child passa a disputar atomicamente a linha antes de enviar; o `1.1` não deve fazer um `UPDATE` posterior nem esperar o child.

### 4.2 Claim antecipado do consumidor agendado

O consumidor deve fazer, por lote, `pending → processing`, incrementando `attempts` uma única vez e retornando `id, attempts as claimed_attempt`. Deve usar `FOR UPDATE SKIP LOCKED` ou um `UPDATE` equivalente com predicado condicional e `RETURNING`.

Depois chama apenas:

- `platform='meta'` → `1.2`;
- `platform='google_ads'` → `1.3`.

O child em `dispatch_mode='scheduled'` **não** incrementa novamente. Ele lê a linha por ID apenas se:

```sql
where co.id = :outbox_id
  and co.platform = :expected_platform
  and co.status = 'processing'
  and co.attempts = :claimed_attempt
  and co.next_attempt_at > now() -- lease ainda válido
```

O predicado do lease pode usar uma janela/coluna existente equivalente; se a tabela não permitir distinguir lease, o consumidor precisa manter a posse curta e o dispatcher deve ao menos validar `status` + `attempts`. Não adicionar coluna sem decisão do Head.

### 4.3 Update final condicional

Nos dois dispatchers, o update final deve deixar de incrementar `attempts` e usar a tentativa já registrada no claim:

```sql
update public.conversion_outbox
set
  status = :computed_status,
  response = :sanitized_response,
  last_error = :last_error,
  sent_at = case when :computed_status = 'sent' then now() else sent_at end,
  next_attempt_at = :next_attempt_at,
  updated_at = now()
where id = :outbox_id
  and status = 'processing'
  and attempts = :claimed_attempt
returning id, status, attempts, next_attempt_at;
```

Se retornar zero linhas, não há autorização para considerar o resultado aplicável. Registrar `stale_result` sem tentar outro HTTP. Esta guarda é obrigatória mesmo que o workflow esteja configurado com concorrência 1.

A transição de resultado é:

| Resultado do dispatcher | Status | Próxima ação |
|---|---|---|
| sucesso externo | `sent` | `sent_at`, sem retry |
| validação deliberada (`validateOnly`) | `skipped` | sem retry |
| erro transitório (429, 5xx, timeout/rede) e tentativas restantes | `pending` | `next_attempt_at` em backoff |
| erro permanente de payload/conta/ação/API | `failed` | terminal operacional |
| credencial Google indisponível | `pending` | exceção atual: próxima tentativa em 6h, alerta |
| claim perdido ou resultado velho | estado já existente | nenhum HTTP adicional |

Para preservar o comportamento real e reduzir escopo, o limite atual continua sendo **4 tentativas efetivas** (`attempts < 4` no claim; a quarta resposta transitória vira `failed`). Os delays atuais dos dispatchers permanecem: Meta 15m/1h/6h; Google 15m/1h/6h, com credencial em 6h contínuas. A política geral do consumidor não deve selecionar `failed` automaticamente; re-drive de `failed` é operação separada e explícita.

## 5. Comportamento do `1.1` fire-and-forget

Manter `waitForSubWorkflow=false` é compatível com o consumidor agendado e é o menor patch. O contrato muda a semântica de observabilidade, não o modo de chamada:

- o webhook/`1.1` responde após normalização e enfileiramento/disparo do child;
- `workflow_execution_logs` do `1.1` significa processamento do evento, não confirmação de `sent`;
- `1.2`/`1.3` são responsáveis por atualizar a outbox e seus próprios logs;
- uma linha que o `1.1` tentou enquanto o consumidor ganhou o claim deve produzir zero chamada externa no child que perdeu o claim;
- não alterar `waitForSubWorkflow` para `true`: isso aumenta latência, acopla disponibilidade do webhook à Meta/Google e não remove a necessidade do claim.

O consumidor agendado deve operar sobre `pending` elegível, incluindo apenas linhas dentro do corte/allowlist. `failed`, `sent` e `skipped` ficam fora; `processing` só aparece como estado de lease e recuperação operacional.

## 6. Recuperação de lease e duplicidade residual

Se n8n cair depois da chamada externa e antes do update, o estado externo é ambíguo. A recuperação automática não deve reenviar essa linha: marcar `processing` expirado como `failed` com `last_error='claim_lease_expired_external_state_unknown'`, alertar e exigir reconciliação/re-drive explicitamente autorizado. Rebaixar automaticamente para `pending` preserva disponibilidade, mas reabre o risco de conversão duplicada.

Esse é o limite honesto do contrato sem idempotency key confirmada pelo provedor. O dispatcher deve preservar `external_request_id`/`external_job_id` quando disponível. Para o piloto, a decisão recomendada é privilegiar não duplicar evento sobre retry automático de estado ambíguo.

## 7. Aceite técnico da implementação futura

1. Dois claims concorrentes na mesma linha retornam no máximo um `RETURNING`; somente esse claim chama Meta/Google.
2. O `1.1` dispara em fire-and-forget e uma linha já reclamada pelo agendado não recebe segundo HTTP.
3. O child agendado aceita `processing` somente com `dispatch_mode='scheduled'` e `claimed_attempt` correspondente.
4. Todo fechamento usa `WHERE id + status='processing' + attempts=claimed_attempt`; resposta velha afeta zero linhas.
5. `sent`/`skipped` nunca são selecionados; `failed` não entra em retry automático.
6. 429/5xx/timeout seguem `pending` + backoff existente; quarta tentativa transitória vira `failed`; credencial Google conserva a exceção de 6h.
7. Expiração de lease não dispara novo HTTP automaticamente.
8. A consulta do consumidor mantém corte, allowlist, `source_system='impuls_crm'`, plataforma correta e `next_attempt_at <= now()`.
9. Os exports baixados permanecem intactos; qualquer alteração posterior deve ser feita em cópia versionada dentro do repositório, nunca no arquivo original em Downloads.

## 8. Decisões que ainda exigem confirmação antes de aplicar

- confirmar na definição viva se `processing` é permitido por constraint/status trigger;
- confirmar a forma exata de lease disponível sem adicionar coluna;
- definir o mecanismo de re-drive manual de `failed` após reconciliação;
- testar em ambiente seguro/sem destino real antes de qualquer ativação. Esta entrega não autoriza publicação, ativação, flag ou envio.
