IMP-218 — BLOQUEIO após duas falhas na etapa staging-run

Branch: feat/imp-218-event-platform-matrix
Base: origin/main b3d16a0
Último commit antes do bloqueio: 28c9c2a

Etapa: scripts/staging-run.py rollback migration + imp218-acceptance + imp218-isolation + rollback.

Tentativa 1:
- Resultado: falhou em imp218-acceptance.sql #18.
- SQLSTATE: 42703.
- Erro exato: column "currency" of relation "events_normalized" does not exist.
- Correção aplicada: migration passou a executar `alter table public.events_normalized add column if not exists currency text`, mantendo a lógica pós-IMP-217.
- Commit: 28c9c2a.

Tentativa 2:
- Resultado: falhou na mesma etapa, em imp218-acceptance.sql #19.
- SQLSTATE: 42883.
- Erro exato: function pg_catalog.nullif(text, unknown) does not exist.
- Ponto: condição do emissor Google em `crm.emit_opportunity_stage_event`, que usa `pg_catalog.nullif(...)`; PostgreSQL expõe `nullif` como construção/rotina não qualificada, não como `pg_catalog.nullif`.

Estado de segurança:
- O staging-run encerrou com rollback; não houve COMMIT da prova.
- Produção não foi alterada.
- `scripts/db-prova.py --dry-run` passou com writes=0, ddl=0, commit=0, mas é o harness legado da IMP-226.
- Não foi aberto PR draft devido ao bloqueio obrigatório da prova.

Próxima ação autorizada: corrigir a qualificação de `nullif` e repetir a prova completa em staging, somente em nova etapa autorizada.
