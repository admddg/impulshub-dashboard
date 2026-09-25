# IMP-229 — medição final do Overview em staging

Data: 25/09/2026 (UTC-03). Ref do código: `origin/main` em `d4f37a42c80c67d7ced6ad4a9bc72336d23c2464`.

## Alinhamento

- Alvo: Supabase staging `nfratueiutxnypbxfnmi`.
- Produção protegida: `mtxnwtqwfagjzkvgsncs`.
- Aplicada no staging, com o alvo explicitamente confirmado, a migration
  `20260927000000_imp229_rls_client_ids.sql` de `origin/main`.
- Não houve escrita em produção.

## Medição somente leitura

A medição executou `BEGIN READ ONLY`, papel `authenticated`, claims da agência
sintética `d036c4d6-0969-4175-b917-ff7e4dd3b376`, e terminou em `ROLLBACK`.
A chamada foi:

```sql
select * from public.get_client_overview_v2(
  '3ec294db-a64a-4420-9b4a-0d917f65d399'::uuid,
  '2026-01-01'::date, '2026-12-31'::date
)
```

Resultados observados via `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`:

| execução | actual rows | execution time |
|---|---:|---:|
| medição com buffers | 1 | 157.419 ms |
| repetição | 1 | 61.458 ms |

Ambas ficaram abaixo do limite de 8 s. Não foram executados `INSERT`, `UPDATE`
ou `DELETE` na medição; a única escrita anterior foi a migration autorizada no
staging para alinhar o ambiente ao `origin/main`.

## Decisão

O gate técnico de IMP-229 está verificado: staging alinhado ao código vigente e
Overview abaixo de 8 s em medição read-only. Pode ser preparado para fechamento.
