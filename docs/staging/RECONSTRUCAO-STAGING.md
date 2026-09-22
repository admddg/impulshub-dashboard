# Plano de reconstrução do staging

Data da investigação: 2026-09-22
Branch desta documentação: `docs/staging-rebuild-plan`
Projeto staging documentado: `nfratueiutxnypbxfnmi`
Projeto produção: `mtxnwtqwfagjzkvgsncs`

## Resumo executivo

O repositório já contém um dump schema-only, um guard de restore, seed sintético e um runner de prova. A reconstrução deve ser feita no projeto existente `nfratueiutxnypbxfnmi`; não há base documental para criar projeto novo, ativar `pg_cron` ou contratar plano novo.

A evidência versionada mostra que o staging foi restaurado estruturalmente e que houve uma prova anterior de seed/aceites para IMP-213, IMP-214 e IMP-216. Porém, os próprios artefatos também registram duas falhas no seed e afirmam que ele não está aplicado no estado documentado. Como esta investigação foi estritamente somente-leitura e não conectou ao Supabase, o estado atual do banco não foi revalidado.

Conclusão operacional: antes de qualquer nova escrita, o Coordenador deve fazer uma consulta de catálogo somente-leitura no staging, reconciliar o ledger de migrations e confirmar se o banco ainda tem a fixture. Só então pode decidir se executa restauração do zero ou apenas repara/reaplica o seed. O Caio não precisa decidir um novo projeto; precisa autorizar, separadamente, qualquer custo ou ação fora do projeto existente.

## Escopo e limites respeitados

- Nenhum comando de escrita, DDL, migration, seed, deploy ou flag foi executado nesta investigação.
- Nenhuma conexão ao Supabase foi aberta.
- Não foi executado `scripts/staging-run.py`, pois o modo `commit` escreve e o modo `rollback` também executa SQL dentro de uma transação no staging; ambos estão fora do escopo somente-leitura deste turno.
- Não foi alterada a branch `feat/staging-restore-v2`.
- O único artefato novo desta entrega é este documento.

## Estado observado no repositório

### Git e branches

- Branch atual: `docs/staging-rebuild-plan`.
- HEAD atual: `0253ae7` (`origin/main` também aponta para este commit).
- A branch de reconstrução é `feat/staging-restore-v2`, apontando para `c59f68d`.
- `feat/staging-restore-v2` diverge de `origin/main` por 10 arquivos e 12.208 linhas adicionadas; é o histórico do trabalho de staging, não uma branch a ser mesclada nesta tarefa.
- A branch de staging contém o commit `e8f5772`, descrito como “seed aplicado e provado (213/214/216 verdes)”.
- O commit posterior `29099bf`, que chegou a `origin/main`, substitui/atualiza a documentação e registra duas falhas do seed; a documentação vigente diz que o seed não está aplicado e que não houve terceira tentativa.

### Artefatos existentes

- `supabase/staging/production-schema.sql`: dump schema-only versionado, com 11.766 linhas.
- `supabase/staging/restore-schema.sh`: restaura somente quando `SUPABASE_TARGET_REF` é exatamente `nfratueiutxnypbxfnmi`; rejeita produção e qualquer outro alvo antes de operar.
- `supabase/staging/seed-synthetic.sql`: fixture sintética com IDs fixos e sem PII real.
- `scripts/db-prova.py`: preflight somente-leitura para o projeto de produção configurado no arquivo; abre `BEGIN READ ONLY`, verifica colunas/contagens, analisa SQL e termina com rollback. Não é uma prova do staging atual.
- `scripts/staging-run.py`: runner do staging; permite `commit` ou `rollback`, portanto não foi executado.
- `supabase/staging/README.md`: documenta o layout, os IDs sintéticos, o conteúdo do seed e os erros anteriores.

### Contagens estruturais documentadas anteriormente

O `supabase/staging/README.md` registra, após o restore, os seguintes números medidos:

| Verificação | Staging | Produção | Observação |
|---|---:|---:|---|
| Tabelas em `public`, `crm`, `private` | 34 | 33 | diferença fora do conjunto de negócio; precisa reconciliação |
| Views/materialized views | 46 | 46 | igual |
| Funções | 42 | 42 | igual |
| Policies RLS | 39 | 39 | igual |
| `to_regclass('cron.job') is not null` | false | true | ausência de `pg_cron` no staging é intencional |

Esses números são evidência versionada de uma execução anterior, não uma medição nova deste turno.

## Migrations: o que é conhecido e o que falta medir

### Inventário estático do repositório

Foi contado no checkout atual:

- 20 migrations de avanço (`*.sql` sem `.rollback.sql`).
- 8 arquivos de rollback.
- 28 arquivos SQL de migration no total.

As 20 migrations de avanço são:

1. `20260922000000_crm_baseline.sql`
2. `20260922000001_crm_opportunity_attribution.sql`
3. `20260923000000_crm_stevo_parser.sql`
4. `20260923000001_crm_schedule_stevo_parser.sql`
5. `20260923000002_crm_public_read_views.sql`
6. `20260923000003_crm_public_write_rpcs.sql`
7. `20260923000004_client_users_attendant_role.sql`
8. `20260924000000_crm_event_bridge.sql`
9. `20260925000000_crm_fix_owners_can_write.sql`
10. `20260925000001_crm_board_counts_filtered.sql`
11. `20260925000002_crm_stage_version_guard.sql`
12. `20260925000003_crm_contacts_view_filters.sql`
13. `20260927000000_imp229_rls_client_ids.sql`
14. `20260928000000_imp213_role_visibility.sql`
15. `20260928000001_imp213_hotfix_card_history_tenant_filter.sql`
16. `20260928000002_imp226a_open_card_on_individual_conversation.sql`
17. `20260929000001_imp214_two_owners.sql`
18. `20260930000000_imp216_split_flags.sql`
19. `20261001000000_imp230_form_intake.sql`
20. `20261002000000_imp231_meta_ads_raw_retention.sql`

### Gap de evidência

O `scripts/staging-run.py` fixa apenas o ref `nfratueiutxnypbxfnmi`; ele não consulta `supabase_migrations.schema_migrations`, não compara hashes e não lista migrations aplicadas. Portanto, não é possível, somente pela leitura dos arquivos, classificar com segurança cada uma das 20 migrations como aplicada ou pendente no banco atual.

A documentação permite afirmar apenas:

- houve uma prova anterior envolvendo IMP-213, IMP-214 e IMP-216;
- o dump de esquema é um snapshot de produção e pode já conter objetos equivalentes a migrations que não estão registradas no ledger do staging;
- IMP-230 e IMP-231 estão no checkout atual e devem ser comparadas ao estado real antes de qualquer prova;
- não se deve inferir “aplicada” pela simples existência de tabela/função, nem inferir “pendente” pela ausência de um arquivo de ledger no repositório.

A primeira consulta do próximo passo deve ser somente-leitura e registrar, no staging, pelo menos:

```sql
select version, name
from supabase_migrations.schema_migrations
order by version;
```

Depois, o Coordenador deve comparar `version`/`name` com os 20 arquivos de avanço e também conferir os objetos alterados por cada migration. Se o ledger não existir ou não refletir o schema dump, isso é um bloqueio de reconciliação, não autorização para reaplicar SQL por tentativa.

## Dados sintéticos necessários

O seed versionado foi desenhado para criar ou atualizar:

- 4 clientes/tenants: Royal, Central, QuickClean e ImpulsHub;
- 4 usuários e identidades sintéticas;
- 10 vínculos de cliente/membership;
- catálogo global com 6 etapas do pipeline;
- 8 oportunidades abertas, 2 por cliente;
- 4 contatos;
- 8 atividades;
- 6 pares `events_raw`/`events_normalized` com `source_system = 'ghl'`;
- IDs canônicos definidos em `supabase/staging/README.md`.

O preflight de auth documentado deve ser repetido antes de um seed novo, porque `auth.users.confirmed_at` e `auth.identities.email` são colunas geradas e não podem entrar no `INSERT`.

### Falhas históricas a tratar antes de nova execução

A documentação vigente registra duas falhas, ambas sem commit:

1. `42601` em `auth.identities`: listas `VALUES` com comprimentos diferentes.
2. `23514` em `crm.opportunity_stage_history_origin_check`: o seed usava `origin='system'`, enquanto a definição aceita `origin='sistema'`.

O arquivo foi registrado como corrigido para `origin='sistema'`, mas isso não substitui uma nova execução autorizada. O contrato operacional manda não fazer uma terceira tentativa automática após duas falhas na mesma etapa; a retomada deve ser uma nova execução, com preflight e revisão do diff do seed.

## Plano de execução proposto

### Fase 0 — reconciliação somente-leitura

Responsável: Coordenador ou Head.

1. Confirmar que o alvo é exatamente `nfratueiutxnypbxfnmi` e que produção continua `mtxnwtqwfagjzkvgsncs`.
2. Consultar `supabase_migrations.schema_migrations` no staging.
3. Consultar `information_schema`, `pg_class`, `pg_proc`, `pg_policies` e `to_regclass('cron.job')` no staging.
4. Comparar o ledger, o dump e os 20 arquivos de avanço.
5. Medir as contagens da fixture: clientes, usuários, memberships, oportunidades, contatos, atividades e eventos.
6. Confirmar que `to_regclass('cron.job') is null`; não criar a extensão `pg_cron`.

Saída obrigatória: tabela “migration / ledger / objeto presente / decisão”, sem executar DDL.

### Fase 1 — decidir entre reparar e reconstruir

Responsável pela decisão: Coordenador; escalar ao Caio se houver custo, novo projeto ou mudança de escopo.

- Se o schema estrutural estiver íntegro e o ledger for reconciliável: não fazer restore; corrigir apenas o seed sintético e executar a etapa de seed no projeto existente.
- Se o schema estiver ausente, inconsistente ou impossível de reconciliar: reconstruir a partir de `production-schema.sql` usando `restore-schema.sh`, com `SUPABASE_TARGET_REF=nfratueiutxnypbxfnmi`.
- Se aparecer qualquer referência ao projeto de produção como destino: abortar antes da operação.
- Não usar dados reais, não copiar tabelas de negócio com dados e não ativar jobs de produção.

### Fase 2 — restore do schema, somente se aprovado na Fase 1

Responsável: Coordenador ou Head, no projeto staging.

1. Obter um novo dump schema-only de produção, sem dados, se a equivalência do dump versionado não puder ser comprovada.
2. Conferir o alvo e executar o guard do restore.
3. Repetir a contagem estrutural: tabelas, views, funções, policies e ausência de `cron.job`.
4. Registrar a diferença esperada de uma tabela antes de declarar equivalência.

Esta fase escreve DDL no staging. Não é parte da execução deste documento.

### Fase 3 — seed sintético

Responsável: Coordenador ou Head; requer nova execução autorizada no staging.

1. Rodar `scripts/db-prova.py --dry-run` conforme o ambiente e registrar `writes=0`, `ddl=0`, `commit=0`; se o script continuar apontando para produção, tratá-lo como preflight do contrato, não como prova do staging.
2. Repetir a leitura de colunas geradas de `auth.users` e `auth.identities`.
3. Revisar o diff do `seed-synthetic.sql`, especialmente `auth.identities` e `origin='sistema'`.
4. Executar o seed uma única vez em transação controlada no staging.
5. Ler de volta as contagens esperadas: 4 clientes, 4 usuários, 10 vínculos client/membership, 8 cards, 4 contatos, 8 atividades e 6 eventos normalizados.
6. Em caso de falha, rollback e relatório; não repetir a mesma etapa automaticamente pela terceira vez.

### Fase 4 — aceites

Responsável: Coordenador ou Head.

1. Executar `imp213-acceptance.sql` e `imp213-isolation.sql`.
2. Executar `imp214-acceptance.sql`.
3. Executar os aceites das migrations posteriores somente depois de confirmar dependências e ledger.
4. Todo aceite que criar ou alterar fixture deve usar `set local statement_timeout='8s'` e terminar em `ROLLBACK`.
5. Confirmar isolamento entre clientes: atendente da Central não vê Royal/QuickClean; gestor Royal não vê Central; agência vê os quatro conforme contrato.
6. Confirmar novamente `to_regclass('cron.job') is null`.

## Segurança e riscos

- Risco máximo: apontar qualquer escrita para `mtxnwtqwfagjzkvgsncs`. O guard deve abortar antes de qualquer operação.
- O dump é schema-only, mas precisa permanecer sem dados reais e sem segredos.
- Reaplicar migrations em um schema já restaurado pode falhar, duplicar objetos ou produzir estado divergente; reconciliar o ledger antes é obrigatório.
- A ausência de `pg_cron` no staging é intencional. Consultar `cron.job` diretamente pode falhar; usar `to_regclass('cron.job') is null`.
- Seed parcialmente aplicado pode deixar fixtures inconsistentes; qualquer retomada deve começar com contagens e estado transacional conhecidos.
- O runner tem modo `commit`; ele é proibido para esta investigação e só pode ser usado pelo responsável autorizado na fase de seed.
- `scripts/db-prova.py` tem projeto de produção fixado em `PROJECT`; não confundir seu dry-run com uma autorização ou prova de escrita em staging.
- A diferença registrada de 34 tabelas no staging contra 33 na produção precisa ser explicada antes de chamar o ambiente de equivalente.
- Não ligar flags, não criar deploy, não criar projeto novo e não ativar parser/cron com dados sintéticos.

## Custo e decisão do Caio

Não foi encontrado no task file nenhum custo novo obrigatório: o plano pressupõe reutilizar `nfratueiutxnypbxfnmi`. Não há base para solicitar projeto Supabase novo, plano pago, nova VPS ou n8n de staging.

Se o projeto staging estiver aposentado, inacessível, exceder cota ou exigir alteração de plano, isso deve ser medido pelo Coordenador e levado ao Caio antes de qualquer criação ou contratação. Esta documentação não decide essa compra.

## Critérios para declarar staging reconstruído

Somente declarar pronto quando houver evidência atual, não apenas documentação histórica, de todos os itens:

1. alvo confirmado como `nfratueiutxnypbxfnmi`;
2. schema comparado com produção e a diferença de tabela explicada;
3. ledger reconciliado com as migrations realmente aplicadas;
4. seed sintético lido de volta com as contagens esperadas;
5. `cron.job` ausente por `to_regclass`;
6. aceites 213/214 e os aceites relevantes da base atual verdes;
7. isolamento entre clientes verde;
8. nenhum dado real, flag, deploy ou escrita em produção;
9. relatório com comandos e números medidos.

## Estado final desta investigação

VERIFICADO RODANDO:

- `git status --short --branch` → branch `docs/staging-rebuild-plan`, inicialmente limpa exceto `PROMPT-executor.md` fornecido para a sessão.
- `git log`/`git diff` → histórico e divergência de `feat/staging-restore-v2` verificados.
- inventário estático → 20 migrations de avanço, 8 rollbacks, 28 arquivos SQL.
- leitura dos artefatos → dump de 11.766 linhas, guard de ref, seed sintético e evidência histórica de 34/33 tabelas, 46/46 views, 42/42 funções e 39/39 policies.

CORRETO POR CONSTRUÇÃO, NÃO TESTADO NESTE TURNO:

- `restore-schema.sh` possui bloqueio de produção conforme leitura do arquivo.
- O seed declara IDs sintéticos e não dados reais.
- O desenho mantém `pg_cron` ausente no staging.
- O plano separa reconciliação, restore, seed e aceites, com responsáveis e gates.

NÃO BATEU / BLOQUEIO:

- Não foi possível listar migrations realmente aplicadas no staging: isso exige consulta somente-leitura ao ledger do projeto, e o `staging-run.py` não faz essa consulta.
- Não foi possível confirmar o estado atual do seed, contagens ou isolamento: não houve conexão nesta tarefa.
- Há evidência documental conflitante entre o commit que descreve seed/aceites verdes e a documentação posterior que registra duas falhas e seed não aplicado. O Coordenador deve resolver a divergência com leitura do banco antes de escrever.

PRÓXIMO RESPONSÁVEL:

O Coordenador deve revisar este plano, executar apenas a Fase 0 em leitura e decidir reparo versus reconstrução. Qualquer escrita no staging, mesmo transacional, fica fora desta entrega e precisa de execução separada, com o alvo validado e relatório próprio.
