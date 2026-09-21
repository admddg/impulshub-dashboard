# ADR-0020 — Policies de leitura não consultam `client_users` diretamente

- **Status:** aceito para a IMP-229
- **Data:** 21/09/2026

## Decisão

Policies de `SELECT` que autorizam por cliente não devem consultar
`public.client_users` diretamente. A membership deve ser encapsulada em uma
função `STABLE SECURITY DEFINER`, com `search_path = ''`, privilégios explícitos
e retorno do conjunto de `client_id` acessível ao usuário atual.

A policy usa `client_id IN (SELECT ... do helper ...)`, permitindo que o
PostgreSQL materialize o conjunto de clientes uma vez por consulta sem executar
uma função de autorização para cada linha protegida.

A policy, view ou subconsulta que consuma uma função que retorna `setof uuid` deve sempre dar alias à função e à sua coluna: `from f() as m`, comparando com `m`.
Nunca use `select client_id from f()` quando existe uma coluna `client_id` no escopo externo: o PostgreSQL pode resolver o nome como correlacionado e transformar o filtro em uma condição sempre verdadeira.

O caso que motivou esta regra foi `public.v_crm_card_history_v1`: o filtro
antigo permitiu ao atendente da Central ver o histórico de 3 clientes, 1.436
linhas no total (Royal 948, QuickClean 398, Central 90). O hotfix
`20260928000001_imp213_hotfix_card_history_tenant_filter` usa `from
private.my_client_ids() as m` e compara com `m`.


A função original `private.user_can_access_client(uuid)` era correta, mas era
avaliada linha a linha nas tabelas de mídia e eventos. Uma subconsulta direta em
`client_users` também não é equivalente: ela executa sob o papel da API e pode
reintroduzir a RLS de `client_users` no caminho de cada policy. O helper definidor
preserva a autoridade da membership e reduz o custo da avaliação.

## Escopo

A decisão foi aplicada inicialmente às policies de leitura de `meta_ads_daily`,
`google_ads_daily`, `google_ads_campaign_daily`, `google_ads_keywords_daily` e
`events_normalized` pela IMP-229. A migration da IMP-213 será regenerada depois
para incorporar essa fronteira.
