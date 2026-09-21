#!/usr/bin/env bash
set -euo pipefail

readonly STAGING_REF="nfratueiutxnypbxfnmi"
readonly PRODUCTION_REF="mtxnwtqwfagjzkvgsncs"
readonly TARGET_REF="${SUPABASE_TARGET_REF:-$STAGING_REF}"
readonly DUMP_FILE="${1:-supabase/staging/production-schema.sql}"

# Guard must run before every remote operation. Only staging is writable.
if [[ "$TARGET_REF" == "$PRODUCTION_REF" ]]; then
  printf 'ABORT: produção (%s) é somente leitura; nenhuma escrita foi iniciada.\n' "$PRODUCTION_REF" >&2
  exit 10
fi
if [[ "$TARGET_REF" != "$STAGING_REF" ]]; then
  printf 'ABORT: alvo não autorizado: %s (esperado somente %s).\n' "$TARGET_REF" "$STAGING_REF" >&2
  exit 11
fi
if [[ ! -s "$DUMP_FILE" ]]; then
  printf 'ABORT: dump ausente ou vazio: %s\n' "$DUMP_FILE" >&2
  exit 12
fi

printf 'Preflight somente leitura no alvo autorizado %s...\n' "$TARGET_REF"
npx supabase db query --linked --project-ref "$TARGET_REF" \
  "select current_database() as database, current_user as role;"

printf 'Aplicando schema-only em %s...\n' "$TARGET_REF"
npx supabase db query --linked --project-ref "$TARGET_REF" --file "$DUMP_FILE"
printf 'Restore concluído em %s.\n' "$TARGET_REF"
