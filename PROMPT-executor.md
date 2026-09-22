Retome a IMP-217 (branch feat/imp-217-outcome-value-reason). NOVA EXECUCAO AUTORIZADA, contador
zerado. Leia STATUS.md (bloqueio anterior) e o arquivo ja gerado
supabase/migrations/20261003000000_imp217_outcome_value_reason.sql: ele esta quase certo, mas tem
um bug de ordem que o Head encontrou na revisao.

O BUG: em crm.emit_opportunity_stage_event, o SELECT que le crm.commercial_outcomes (is_current)
roda dentro do gatilho AFTER UPDATE de crm.opportunities. Em public.crm_register_won e
public.crm_register_lost, o UPDATE em crm.opportunities acontece ANTES do INSERT em
crm.commercial_outcomes — ou seja, quando o gatilho dispara e le commercial_outcomes, a linha do
outcome atual (com o valor/motivo de verdade) AINDA NAO EXISTE. O evento nasce sem valor de novo,
exatamente o defeito que a IMP-217 devia corrigir.

A CORRECAO (confirmada segura pelo Head: crm.validate_commercial_outcome nao depende do status da
oportunidade ja estar 'won'/'lost', so exige ator ativo e evidence — ver
docs/imp217-production-read.txt linhas ~181-220): em AMBAS as funcoes, mova o bloco
"insert into crm.commercial_outcomes (...) values (...)" para ANTES do bloco
"update crm.opportunities o set current_stage_id = ..." — sem mudar mais nada na ordem (o insert em
crm.opportunity_stage_history continua onde esta, antes de tudo). Depois do UPDATE, o restante
(milestones etc.) continua igual. NAO mude a funcao crm.emit_opportunity_stage_event alem do que ja
esta la (a leitura de commercial_outcomes por is_current ja esta correta — so a ORDEM nas duas RPCs
estava errada).

Faca essa correcao por edicao direta do arquivo .sql ja gerado (nao reescreva do zero, nao use script
de pattern-matching fragil — edite as duas funcoes manualmente, com cuidado). Confira depois, lendo o
arquivo, que a ordem ficou: stage_history insert -> commercial_outcomes insert -> opportunities
update -> milestones (won) / (nada extra no lost).

Depois de corrigir:
1. Gere/ajuste o rollback (.rollback.sql) para bater com a versao final.
2. Prove no staging (nfratueiutxnypbxfnmi) com scripts/staging-run.py: migration + imp217-acceptance
   + imp217-isolation + rollback, numa transacao com ROLLBACK. Preste atencao especial ao criterio
   "Ganho com valor" (delta exato no dashboard) — e o teste que teria pego este bug.
3. `APLICAR-imp217.sql` autocontido (sem \\ir).
4. Commit por etapa. Abra PR draft com gh pr create --draft. Relatorio em 3 blocos.

NAO execute nada em producao. Se travar duas vezes na MESMA etapa desta execucao, pare e escreva
STATUS.md com o bloqueio exato.
