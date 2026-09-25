# IMP-215 — desenho seguro do consumidor da `conversion_outbox`

**Base da análise:** `origin/main` em `d1ac1ae`, ADR-0026, `TASK-IMP-215.md`, migration `20260924000000_crm_event_bridge.sql`, acceptance de IMP-216/217/218, `production-schema.sql` local e documentação n8n. Esta entrega é somente desenho/documentação; não publica n8n, não liga flags, não escreve banco e não envia eventos.

## Veredicto

A forma implementável é **um workflow n8n novo, agendado, separado do `1.1`/`1.2`/`1.3`**, que varre em lotes pequenos e chama os dispatchers existentes por `Execute Workflow`.

O workflow deve ter dois filtros independentes e obrigatórios:

1. **cliente permitido:** `events_normalized.source_system = 'impuls_crm'` e `events_normalized.client_id` pertence à allowlist explícita do workflow;
2. **corte por cliente:** `conversion_outbox.created_at >= cutoff_at[client_id]`, com um `cutoff_at` imutável, registrado na versão do workflow antes da ativação de cada cliente.

Apenas `status='pending'` e `status='failed'` recentes, com `next_attempt_at <= now()` e abaixo do limite de tentativas, são elegíveis. Linhas anteriores ao corte são sempre excluídas, mesmo que `pending` ou `failed`. O workflow deve falhar fechado se qualquer cliente configurado estiver sem cutoff.

Não se deve varrer apenas por `status`. A tabela não possui `source_system` nem `client_id`; ambos são resolvidos pelo join `conversion_outbox.normalized_event_id -> events_normalized`.

## Fluxo proposto

1. **Schedule Trigger** a cada 1 minuto, com concorrência efetiva 1 e limite de lote (sugestão inicial: 10 por plataforma).
2. **Run metadata / log opening:** criar uma linha `workflow_execution_logs` no mesmo padrão dos workflows existentes, com workflow name/version, `n8n_execution_id`, início, modo `dry_run=false` somente quando autorizado, allowlist e contadores zerados. Nunca registrar payload sensível.
3. **Read-only candidate query:** por plataforma (`meta`, `google_ads`), fazer o join com `events_normalized`, aplicar `source_system`, allowlist, cutoff, status, `next_attempt_at`, `attempts < MAX_ATTEMPTS`, ordenando por `created_at, id`, com limite pequeno.
4. **Atomic claim:** em transação Postgres, selecionar com `FOR UPDATE SKIP LOCKED` e mudar somente as linhas retornadas para `status='processing'`, incrementando `attempts` e definindo `next_attempt_at` como lease curto. O `UPDATE ... WHERE id=? AND status IN ('pending','failed') RETURNING id` é a segunda barreira. Se a linha não retornar, ela foi perdida para outra execução e não pode ser enviada.
5. **Platform split:** para cada linha reclamada, chamar **somente** o dispatcher correspondente: `meta -> 1.2`; `google_ads -> 1.3`. Passar `outbox_id` e os campos necessários, não fabricar um payload de outra plataforma.
6. **Reuse dispatch:** `1.2`/`1.3` devem reler a linha pelo ID, montar a requisição usando os campos existentes (`platform_event_name`, `platform_conversion_action`, IDs de conta, `dispatch_method`, `destination_config`, `payload`, `match_keys`) e manter o vocabulário atual `sent`/`skipped`/`failed`, preenchendo os campos de resultado já existentes.
7. **Failure recovery:** timeout/erro do dispatcher deixa `failed`, `last_error`, `http_status`/códigos/detalhes e `next_attempt_at` em backoff exponencial com teto. Após `MAX_ATTEMPTS`, permanece `failed` como DLQ operacional; o workflow não tenta novamente até intervenção/rotina de re-drive explicitamente autorizada.
8. **Lease recovery:** no início de cada execução, devolver `processing` cujo lease venceu para `failed` com erro `claim_lease_expired`, sem reenviar diretamente. Isso evita perda silenciosa após queda do n8n.
9. **Close log:** atualizar `workflow_execution_logs` com `success`, `partial`, `skipped` ou `error`, quantidade lida/reclamada/enviada/falha/fora do corte e timestamps. A saúde também deve continuar sendo observável diretamente por `conversion_outbox` por status/plataforma; log não substitui a outbox.

### Ponto que bloqueia a implementação do JSON

`processing` não aparece na documentação como status aceito pelo dispatcher e os exports reais não estão disponíveis. Antes de criar o workflow, confirmar no JSON/execução controlada de `1.2`/`1.3` que eles não dependem de a linha estar `pending` e que o update final é condicional ao `outbox_id`. Se não for seguro introduzir `processing`, usar um objeto/função de claim transacional aprovado pelo Head; não improvisar claim só com leitura + update posterior.

## Corte temporal e por cliente

- O corte é **por `client_id`**, não uma janela móvel e não uma data global inferida das 512 linhas.
- Para cada cliente, registrar `cutoff_at` como o instante imediatamente anterior à habilitação do consumidor para aquele cliente. A configuração deve ser versionada junto do workflow e não pode ser alterada retroativamente.
- Predicado mínimo:

```sql
co.status in ('pending', 'failed')
and co.created_at >= cutoff_at_for_client
and co.next_attempt_at <= now()
and co.attempts < max_attempts
and en.source_system = 'impuls_crm'
and en.client_id = any(allowlisted_client_ids)
```

- A primeira execução deve ser **dry-run de leitura**, produzindo contagem por cliente/plataforma/status e amostras de IDs, sem claim e sem `Execute Workflow`.
- A primeira execução real deve operar com uma única linha sintética elegível por plataforma, depois com lote pequeno. Não há backfill.
- A consulta de proteção negativa deve comprovar que nenhuma linha com `created_at < cutoff_at_for_client` aparece nos itens reclamados. As 512 `pending` e 43 `failed` históricas permanecem intactas.
- `crm_emits_conversions` continua `false`; a criação de novas linhas e a habilitação de cliente pertencem ao fluxo de ativação posterior, não a esta preparação.

## Idempotência e concorrência

- O índice único existente `conversion_outbox_event_platform_uidx` protege uma linha por evento/plataforma, mas **não** impede dois envios da mesma linha; o claim é obrigatório.
- Duas execuções concorrentes devem disputar a mesma linha com `SKIP LOCKED`/predicado condicional; somente a que recebe `RETURNING` pode chamar `1.2`/`1.3`.
- `sent` e `skipped` nunca são candidatos. Reexecução após sucesso deve produzir zero chamadas.
- A janela de lease deve ser maior que o timeout máximo do dispatcher. Em caso de crash, a recuperação produz `failed` e aguarda o próximo backoff; nunca envia automaticamente uma linha cujo estado de entrega é ambíguo sem a política de retry aprovada.
- O dispatcher deve manter `external_request_id`/`external_job_id` e resposta para reconciliação. Não criar outra linha para retry.

## Falhas, retry e DLQ

Política recomendada para o primeiro piloto: `MAX_ATTEMPTS=3`, delays 1, 5 e 30 minutos, teto de 1 hora; somente erros transitórios (timeout, 429, 5xx) entram no retry. Erros de payload, credencial, conta, ação ou evento inválido vão direto para `failed` terminal operacional. O valor final precisa ser registrado no workflow antes da ativação.

`failed` anterior ao cutoff nunca entra no retry. Toda falha terminal gera alerta/consulta operacional por cliente, plataforma, `outbox_id`, attempts, último erro sanitizado e idade; não mascarar falha como `skipped`.

## Observabilidade mínima

- `workflow_execution_logs`: uma linha por execução, com estágio e contadores de `candidate`, `claimed`, `sent`, `skipped`, `failed`, `lease_recovered` e `cutoff_rejected`.
- `conversion_outbox`: manter `attempts`, `next_attempt_at`, `last_error`, `response`, `http_status`, códigos/detalhes, IDs externos, `sent_at` e `updated_at`.
- Painel/consulta de saúde: por `client_id` resolvido via `events_normalized`, plataforma e status; idade do candidato mais antigo; falhas acima do limite; leases expirados; delta de linhas fora do corte.
- Alertas: execução ausente, lote parcial, crescimento de `failed`, qualquer candidato sem cliente/cutoff e qualquer tentativa de seleção fora do corte (deve ser zero e abortar).

## Critérios de aceite do pacote

1. Uma linha sintética `pending`, dentro do corte e com `platform='meta'` termina `sent`, `sent_at` preenchido, attempts incrementado e exatamente uma chamada ao dispatcher Meta.
2. Uma linha equivalente `google_ads` usa o dispatcher Google e prova literalmente `platform_event_name`/`platform_conversion_action`; não reutiliza payload Meta.
3. Varredura completa deixa o conjunto histórico `{pending, failed}` anterior ao cutoff com delta zero; nenhuma chamada externa é feita para ele.
4. Duas execuções simultâneas sobre a mesma linha resultam em exatamente um claim e uma chamada; repetir sobre `sent`/`skipped` resulta em zero chamadas.
5. Erro transitório atualiza `failed`, attempts, `next_attempt_at` futuro e `last_error`; após N tentativas a linha fica visível como DLQ sem loop infinito.
6. Cliente fora da allowlist, `source_system` diferente de `impuls_crm`, ausência de cutoff ou cutoff inválido causa zero envio e execução abortada/alertada.
7. O rastro de uma entrega e de uma falha aparece em `workflow_execution_logs` e na própria outbox, sem segredo nem payload sensível em log.
8. O teste de isolamento mantém a resolução de `client_id` por tenant e não mistura clientes.
9. Nenhuma flag é ligada, nenhum evento é enviado e nenhum workflow de produção é alterado durante a preparação.

## Evidência e bloqueios encontrados

- `origin/main` em `d1ac1ae` contém ADR-0026 e `docs/task-files/TASK-IMP-215.md`; o checkout de trabalho original estava em outro branch, por isso a análise foi feita contra `origin/main` e este documento está em worktree separado.
- O schema local confirma 31 colunas da outbox, índices de varredura, unicidade por evento/plataforma e ausência de `source_system`/`client_id` físicos. Não há constraint local de status da outbox no dump; a compatibilidade de `processing` precisa ser confirmada no ambiente vivo/JSON antes de usar.
- A migration da ponte cria a outbox com `status='pending'` e não entrega nada; `crm_emits_conversions` permanece inerte por default.
- Acceptance de IMP-216/217/218 existe em `origin/main` e cobre a criação/matriz/isolamento, mas não existe acceptance de IMP-215.
- **Não há export local dos workflows reais `1.2`/`1.3` nem do `1.1` para revisão.** O repositório `Impuls-Platform` contém somente `n8n/workflows/IMP-033-smoke-sintetico.json`, explicitamente sintético; a documentação de inteligência acumulada descreve os nós, mas não prova o JSON vivo.
- Portanto, ainda não é possível confirmar: IDs reais usados em `Execute Workflow`, campos exatos lidos por `Get Single Meta/Google Outbox`, compatibilidade com `processing`, mapeamento de retry/status e o padrão efetivo de log. O pacote está pronto para receber os JSONs; sem eles, implementar seria operar no escuro.

## Não fazer nesta etapa

Não publicar/importar/ativar n8n; não ligar `crm_emits_conversions`; não executar claim ou dispatch; não enviar Meta/Google; não alterar production; não criar coluna em `conversion_outbox` sem decisão explícita do Head.
