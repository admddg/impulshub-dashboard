# Fase 0 — reconciliação somente-leitura do staging

Data da execução: 2026-09-22
Branch: `docs/staging-fase0-reconciliacao`
Alvo confirmado: `nfratueiutxnypbxfnmi`
Produção protegida: `mtxnwtqwfagjzkvgsncs`

## Escopo executado

A reconciliação foi executada exclusivamente no staging. O script abriu `BEGIN READ ONLY`, confirmou o papel antes/depois de `SET LOCAL ROLE postgres` e terminou com `ROLLBACK`. Não foram executados DDL, `INSERT`, `UPDATE` ou `DELETE`.

Comando executado:

    python scripts/staging-fase0-readonly.py

O endpoint resolvido pelo dry-run da CLI foi `db.nfratueiutxnypbxfnmi.supabase.co`. Nenhuma credencial é registrada neste documento.

## Ledger observado

A relação `supabase_migrations.schema_migrations` existe, mas contém somente 2 registros:

| version | name |
|---|---|
| `20260916190000` | `m0_staging_smoke` |
| `20260930000000` | `imp216_split_flags` |

O checkout contém 20 migrations de avanço. Portanto, apenas a migration `20260930000000_imp216_split_flags.sql` tem correspondência direta no ledger; o registro `m0_staging_smoke` não corresponde a uma migration de avanço do checkout.

## Tabela obrigatória de reconciliação

“Objeto presente” significa que o catálogo atual contém objetos do domínio; não significa que seja possível atribuí-los com segurança à migration indicada. A presença de um objeto não substitui o ledger.

| migration | ledger | objeto presente | decisão |
|---|---|---|---|
| `20260922000000_crm_baseline.sql` | ausente | sim, objetos CRM existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260922000001_crm_opportunity_attribution.sql` | ausente | sim, schema CRM existe; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260923000000_crm_stevo_parser.sql` | ausente | sim, funções/views existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260923000001_crm_schedule_stevo_parser.sql` | ausente | sim, funções/views existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260923000002_crm_public_read_views.sql` | ausente | sim, views públicas existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260923000003_crm_public_write_rpcs.sql` | ausente | sim, funções públicas existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260923000004_client_users_attendant_role.sql` | ausente | sim, `client_users` existe; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260924000000_crm_event_bridge.sql` | ausente | sim, objetos de eventos existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260925000000_crm_fix_owners_can_write.sql` | ausente | sim, objetos CRM existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260925000001_crm_board_counts_filtered.sql` | ausente | sim, views CRM públicas existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260925000002_crm_stage_version_guard.sql` | ausente | sim, objetos CRM existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260925000003_crm_contacts_view_filters.sql` | ausente | sim, views CRM públicas existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260927000000_imp229_rls_client_ids.sql` | ausente | sim, policies/helpers existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260928000000_imp213_role_visibility.sql` | ausente | sim, policies/views/functions existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260928000001_imp213_hotfix_card_history_tenant_filter.sql` | ausente | sim, views/functions existem; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260928000002_imp226a_open_card_on_individual_conversation.sql` | ausente | sim, parser CRM existe; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260929000001_imp214_two_owners.sql` | ausente | sim, schema CRM existe; atribuição não determinável | não reaplicar isoladamente; reconstrução necessária |
| `20260930000000_imp216_split_flags.sql` | presente (`20260930000000`, `imp216_split_flags`) | sim, objetos públicos/CRM existem; correspondência estrutural não prova conteúdo | não reaplicar; ainda exige reconstrução do estado completo |
| `20261001000000_imp230_form_intake.sql` | ausente | não determinável pelo catálogo agregado | não reaplicar isoladamente; reconstrução necessária |
| `20261002000000_imp231_meta_ads_raw_retention.sql` | ausente | não determinável pelo catálogo agregado | não reaplicar isoladamente; reconstrução necessária |

## Catálogo medido no staging

| verificação | resultado medido |
|---|---:|
| relações `crm` com `relkind = r` | 15 |
| relações `public` com `relkind = r` | 20 |
| views públicas | 46 |
| funções em `crm` | 17 |
| funções em `private` | 5 |
| funções em `public` | 20 |
| policies em `crm` | 28 |
| policies em `public` | 11 |
| total de policies nos três schemas consultados | 39 |
| `to_regclass('cron.job')` | `NULL` |
| `to_regclass('cron.job_run_details')` | `NULL` |

A ausência de `cron.job` foi confirmada. Nenhuma extensão ou job foi criada.

## Fixture medida

| entidade | relação | presente | linhas |
|---|---|---:|---:|
| clientes | `public.clients_base` | sim | 4 |
| usuários | `auth.users` | sim | 4 |
| vínculos de produto | `public.client_users` | sim | 10 |
| memberships CRM | `crm.tenant_memberships` | sim | 10 |
| oportunidades | `crm.opportunities` | sim | 8 |
| contatos | `crm.contacts` | sim | 4 |
| atividades | `crm.activities` | sim | 8 |
| eventos brutos | `public.events_raw` | sim | 6 |
| eventos normalizados | `public.events_normalized` | sim | 6 |

Tenants encontrados: Central, QuickClean, ImpulsHub e Royal, com os quatro UUIDs canônicos documentados no README do staging.

## Decisão da Fase 1

Caminho recomendado: **reconstruir**, não reparar/reaplicar apenas o seed.

Motivo verificável: o schema e a fixture estão estruturalmente presentes, mas o ledger contém somente 2 registros para 20 migrations de avanço e não permite classificar o estado real de 19 migrations. Como reaplicar migrations sobre um schema já existente pode duplicar objetos ou produzir divergência, o ledger não é reconciliável com segurança para um caminho de reparo.

Próximo passo, fora desta entrega: o Coordenador/Head deve aprovar a Fase 2 no staging, obter ou validar um dump schema-only atual, conferir novamente o alvo e usar `supabase/staging/restore-schema.sh`. Depois do restore, a Fase 3 poderá revisar e executar o seed sintético uma única vez, precedida pelo dry-run obrigatório. Esta entrega não executou restore, seed nem aceites.

## Relatório em três blocos

VERIFICADO RODANDO:

- `python scripts/staging-fase0-readonly.py` → conexão no endpoint do staging, `BEGIN READ ONLY`, 2 registros no ledger, 15 tabelas CRM, 20 tabelas públicas, 46 views, 42 funções totais, 39 policies, `cron.job = NULL` e contagens da fixture `4/4/10/10/8/4/8/6/6`.
- comparação estática do checkout → 20 migrations de avanço.
- `production-schema.sql` → 11.766 linhas e 33 comandos `CREATE TABLE` no dump versionado.

CORRETO POR CONSTRUÇÃO, NÃO TESTADO:

- `scripts/staging-fase0-readonly.py` rejeita endpoint que não contenha o ref de staging ou contenha o ref de produção antes da conexão.
- a conexão usa `BEGIN READ ONLY` e finaliza com rollback;
- nenhuma etapa da Fase 2, Fase 3 ou Fase 4 foi chamada.

NÃO BATEU / BLOQUEIO:

- o ledger não reconcilia as 20 migrations: há somente 2 registros, dos quais 1 é o smoke inicial e 1 corresponde a `imp216_split_flags`;
- a presença atual de objetos não permite atribuir com segurança cada objeto a uma migration;
- a diferença entre o dump versionado e o catálogo atual não pode ser resolvida por reaplicação incremental sem uma reconstrução controlada.

PRECISA DO COORDENADOR/CAIO:

- autorização separada para a Fase 2, que escreverá DDL no staging;
- nenhum pedido de novo projeto ou custo foi identificado nesta Fase 0.
