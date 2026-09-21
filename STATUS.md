# TASK-STAGING — bloqueio

A execução foi interrompida na etapa 1 (dump schema-only).

## Tentativas

1. `npx supabase db dump --project-ref mtxnwtqwfagjzkvgsncs --schema public,crm,private --file supabase/staging/production-schema.sql`
   - Falhou antes de gerar o arquivo porque o Supabase CLI depende do Docker Desktop Linux Engine.
   - Erro: `failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine`.
2. Alternativa equivalente com `pg_dump` direto.
   - Não executável neste ambiente: `pg_dump` não está instalado/disponível no PATH e não foi encontrado em `C:/Program Files` nem em `C:/Users/caiop/AppData/Local`.

## Segurança e escopo

- Nenhuma escrita foi feita em produção ou staging.
- Nenhum arquivo de dump foi gerado.
- O comando de dry-run do Supabase CLI foi executado previamente apenas para inspecionar o comando de leitura; não houve DDL, INSERT, UPDATE, DELETE ou COMMIT.
- As etapas 2, 3 e 4 não foram iniciadas porque dependem do dump da etapa 1.

## Retomada

Iniciar Docker Desktop com o Linux Engine disponível, ou disponibilizar `pg_dump` compatível com PostgreSQL 17. Depois repetir somente a etapa 1 e validar o dump antes de restaurar qualquer coisa em staging.
