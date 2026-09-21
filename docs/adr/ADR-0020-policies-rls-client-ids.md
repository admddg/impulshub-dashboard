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

## Motivo

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

## Regra para funções escalares

Uma migration que cria uma view sobre uma função escalar deve nomear a linha no próprio `FROM` e comparar com o alias escalar: `where gated.client_id in (select m from private.my_client_ids() as m)`. Não se deve escrever `select client_id from private.my_client_ids()` nem comparar `ids.client_id`: `my_client_ids()` retorna `SETOF uuid`, não uma tabela com coluna `client_id`. Funções que retornam `TABLE (client_id uuid)`, como `financial_client_ids()`, são uma forma diferente e podem expor essa coluna nomeada.

O caso real que motivou a regra foi `public.v_crm_card_history_v1`: a definição antiga usava `select client_id from private.my_client_ids()` no filtro externo. PostgreSQL resolveu `client_id` como a coluna da própria view, tornando o predicado verdadeiro para qualquer membro e vazando histórico entre clientes. O hotfix `20260928000001_imp213_hotfix_card_history_tenant_filter` usa `select m from private.my_client_ids() as m` e adiciona aceite de isolamento por view e por papel.
