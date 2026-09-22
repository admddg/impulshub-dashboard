IMP-217 — BLOQUEIO após duas falhas na etapa de geração/reordenação SQL

Data da execução: 2026-09-22
Branch: feat/imp-217-outcome-value-reason

Etapa bloqueada: geração da migration a partir das definições vivas de produção.

Falha 1: a primeira geração inseriu o ACL dentro do corpo PL/pgSQL e duplicou a lista de colunas de events_normalized. A falha foi detectada por inspeção estática antes de qualquer conexão de escrita.

Falha 2: a tentativa de corrigir a reordenação das RPCs para gravar commercial_outcomes antes do UPDATE falhou porque o padrão de texto usado para crm_register_lost não correspondeu à definição capturada. O script abortou com AssertionError: lost reorder pattern absent. Nenhum arquivo foi alterado por essa segunda tentativa.

Evidências já executadas:
- python scripts/db-prova.py --dry-run: passou; writes=0, ddl=0, commit=0.
- leitura read-only em produção: pg_get_functiondef de crm.emit_opportunity_stage_event, public.crm_register_won, public.crm_register_lost, crm.validate_commercial_outcome, crm.validate_opportunity e crm.validate_stage_history; triggers, colunas, índices, ACLs e motivos canônicos foram consultados.
- staging nfratueiutxnypbxfnmi: dry-run do dump alcançável.

Não executado:
- nenhuma migration, DDL, INSERT, UPDATE ou COMMIT em produção/staging;
- nenhum commit, push ou PR draft;
- nenhum aceite transacional.

Próximo passo necessário: revisão humana/Coordenador da definição exata de crm_register_lost e correção manual ou novo executor; não prosseguir automaticamente nesta execução.
