# TASK-STAGING — retomada

## Etapa 1 — dump schema-only

- Estado: concluída.
- Fonte somente leitura: projeto `mtxnwtqwfagjzkvgsncs`.
- Comando: `npx supabase db dump --project-ref mtxnwtqwfagjzkvgsncs --schema public,crm,private --file supabase/staging/production-schema.sql`
- Resultado medido: exit `0`; arquivo com `498797` bytes e `11773` linhas.
- Validação do conteúdo: `3` schemas (`crm`, `private`, `public`), `33` tabelas, `0` ocorrências de `COPY`, `INSERT`, `UPDATE` ou `DELETE` no início de linha.
- Docker validado: engine Linux `29.8.0`.
- Nenhuma escrita foi feita em produção.

## Regra de ouro

Toda escrita deve validar previamente que o alvo é exatamente `nfratueiutxnypbxfnmi` e abortar se for `mtxnwtqwfagjzkvgsncs`. Produção permanece somente leitura.

## Próxima etapa

Restaurar o schema em `nfratueiutxnypbxfnmi`, com validação do alvo antes do primeiro comando de escrita.
