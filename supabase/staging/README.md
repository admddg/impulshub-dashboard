# Staging ImpulsHub

Projeto Supabase autorizado para escrita nesta entrega: `nfratueiutxnypbxfnmi` (ImpulsHub Staging).
Produção `mtxnwtqwfagjzkvgsncs` foi usada somente para leitura de schema e do catálogo global.

## Escopo e guarda de segurança

- Nenhum comando de escrita foi direcionado à produção.
- `restore-schema.sh` rejeita produção e qualquer ref diferente do staging antes de operar.
- O dump é schema-only; o seed é sintético e não contém dados reais, PII ou segredos.
- O staging não cria nem ativa `pg_cron`; a ausência de `cron.job` é esperada.
- Antes de qualquer seed, `scripts/db-prova.py --dry-run` deve terminar com `writes=0`, `ddl=0` e `commit=0`.

## IDs canônicos da fixture

Clientes/tenants:

- Royal: `fa6fc071-7529-4317-93cb-9b0bfea3bca3`
- Central: `19c9d8c6-1a6d-499b-95fd-cc23d1cd555b`
- QuickClean: `3bc0e6a4-6438-420d-b603-ec91bf296f4e`
- ImpulsHub: `3ec294db-a64a-4420-9b4a-0d917f65d399`

Usuários:

- Agency: `d036c4d6-0969-4175-b917-ff7e4dd3b376`
- Igor: `4848733f-a369-4c8c-87cd-e62bbaa7b8f5`
- Atendente Central: `bb04435c-fabb-4ba8-b5b5-e0175d9ca17d`
- Gestor Royal/viewer: `7c3296f4-13c7-42d1-89eb-72aecec905ba`

Agency e Igor são membros administrativos dos quatro tenants. O atendente é exclusivo da Central e `is_assignable=true`; o gestor é exclusivo da Royal e `viewer`/não assignable. `client_users` contém os mesmos vínculos com os papéis da API.

## Auth: preflight e colunas mínimas

Antes do primeiro INSERT foi executada, no staging, esta consulta de leitura:

```sql
select table_schema, table_name, column_name, is_generated, column_default
from information_schema.columns
where table_schema = 'auth'
  and table_name in ('users', 'identities')
order by table_name, ordinal_position;
```

Resultado relevante medido:

- `auth.users.confirmed_at`: `is_generated = ALWAYS`; não é inserida.
- `auth.identities.email`: `is_generated = ALWAYS`; não é inserida.
- `auth.users.id` tem default `gen_random_uuid()`; o seed fornece o UUID canônico.
- `auth.identities.id` tem default `gen_random_uuid()`; o seed fornece IDs sintéticos.

O seed usa em `auth.users` somente: `id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at`. Em `auth.identities`, usa somente as colunas não geradas necessárias e omite `email` gerada.

## Conteúdo do seed

`seed-synthetic.sql` cria/atualiza:

- quatro `clients_base` com `ghl_location_id` sintético, inclusive ImpulsHub;
- quatro `crm.tenants` com os mesmos UUIDs;
- quatro usuários, identidades e perfis sintéticos;
- `client_users` e `crm.tenant_memberships` conforme os papéis acima;
- catálogo global de pipeline copiado por SELECT da produção: versão 1 e seis etapas, com Lead/Atendimento/Agendado/Compareceu não terminais e Ganho/Perdido terminais;
- oito cards CRM abertos, dois por cliente, nas etapas consecutivas Lead e Atendimento;
- quatro contatos e oito atividades sintéticas;
- seis pares `events_raw`/`events_normalized` sintéticos, com `source_system='ghl'` e códigos `lead`, `primeira_conversa`, `agendado`, `compareceu`, `ganho` e `perdido`.

## Reconstrução do zero

1. Obter novamente o schema-only de produção para `supabase/staging/production-schema.sql`, sem dados.
2. Conferir que o alvo é exatamente `nfratueiutxnypbxfnmi` e executar `supabase/staging/restore-schema.sh`.
3. Rodar `python scripts/db-prova.py --dry-run`; não prosseguir se `writes`, `ddl` ou `commit` forem diferentes de zero.
4. Consultar `information_schema.columns` de `auth.users`/`auth.identities` no staging e confirmar as colunas geradas antes do seed.
5. Executar `npx supabase db query --linked --project-ref nfratueiutxnypbxfnmi --file supabase/staging/seed-synthetic.sql`.
6. Validar contagens de quatro clientes, quatro usuários, dez client/membership links, oito cards, quatro contatos, oito atividades e seis eventos normalizados.
7. Executar `supabase/acceptance/imp213-isolation.sql` e `supabase/acceptance/imp214-acceptance.sql`; ambos devem usar `set local statement_timeout='8s'` e terminar com `ROLLBACK`.
8. Confirmar `select to_regclass('cron.job') is null`.

## Evidência deste turno

Preflight executado com sucesso:

`python scripts/db-prova.py --dry-run` → `dry_run=passed`, `writes=0`, `ddl=0`, `commit=0`.

Tentativa 1 do seed, após a consulta obrigatória de colunas → abortou com `42601` em `auth.identities` (`VALUES lists must all be the same length`); sem commit.

Tentativa 2 → abortou com `23514`: `crm.opportunity_stage_history_origin_check` rejeitou `origin='system'`. A definição lida no staging é:

`CHECK ((origin = ANY (ARRAY['frase_configurada', 'manual', 'integracao', 'sistema'])))`

O arquivo já foi corrigido para `origin='sistema'`, mas não foi feita uma terceira execução nesta etapa: o contrato operacional manda parar após duas falhas na mesma etapa. Por isso o seed não está aplicado e os aceites IMP-213/IMP-214 não foram executados neste turno.

## Arquivos

- `production-schema.sql`: dump schema-only versionado.
- `restore-schema.sh`: restore com bloqueio de produção.
- `seed-synthetic.sql`: fixture sintética corrigida, aguardando nova execução autorizada.
- `TASK-STAGING.md`: escopo e sequência de etapas.
- `STATUS.md`: estado e evidências da retomada.

## Provar uma migration no staging (runner do Head)

`python scripts/staging-run.py rollback <arquivos.sql...>` roda os arquivos em UMA transação no staging (`nfratueiutxnypbxfnmi`, aborta se o alvo for produção) e termina em ROLLBACK; `commit` só para o seed. Padrão de prova: migration + aceite + (reset role) + isolamento + rollback da migration, tudo em `rollback`. A migration deixa `set constraints all immediate`; o aceite deve começar com `set constraints all deferred`. Aceites 213, 214 e 216 rodam aqui sem adaptação (UUIDs iguais aos de produção, dados sintéticos).
Os achados do seed: `opportunity_stage_history.transition_type` aceita `automatic|manual|undo|correction`; `origin` aceita `frase_configurada|manual|integracao|sistema`; a tabela é append-only.

## Reconstrução executada em 2026-09-22

- Fase 2: dump schema-only renovado da produção e restore no ref `nfratueiutxnypbxfnmi`. O primeiro restore sobre o schema existente falhou com `42P16` por tabela já existente; não houve commit parcial. O segundo caminho, após reset transacional dos schemas `crm`, `private` e `public`, passou.
- Estrutura medida após restore: 35 tabelas, 46 views/materialized views, 43 funções e 39 policies em `public`, `crm` e `private`; `to_regclass('cron.job') is null` retornou `true`; ledger staging contém 2 linhas.
- Fase 3: preflight de `auth.users`/`auth.identities` confirmou `auth.users.confirmed_at` e `auth.identities.email` como `GENERATED ALWAYS`. O seed foi executado uma vez e sofreu rollback com `P0001 IMP-216 cannot map CRM stage ...0201 to an event code`, porque `crm.event_map` estava vazio no dump e não era populado pelo seed.
- Correção versionada: o seed agora popula os seis mapeamentos canônicos de `crm.event_map`. A correção não foi reaplicada ao staging nesta sessão, conforme a regra de parar após falha da etapa.
- Fase 4: não executada; depende de uma nova execução autorizada do seed corrigido e da leitura de volta das contagens esperadas: 4 clientes, 4 usuários, 10 vínculos, 8 cards, 4 contatos, 8 atividades e 6 eventos normalizados.
- `scripts/db-prova.py --dry-run` passou como preflight somente-leitura do contrato (`writes=0`, `ddl=0`, `commit=0`), mas permanece fixado no projeto de produção e suas contagens não são evidência do staging.
