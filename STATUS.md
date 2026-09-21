IMP-216 — BLOQUEADA NO PASSO 0

Objetivo do sprint: separar alimentar o dashboard de enviar conversão para que clientes novos sem GHL tenham dashboard sem ligar crm_emits_conversions.

Estado: bloqueada antes de escrever qualquer SQL, conforme TASK-IMP216.md.

Leituras somente leitura executadas no projeto mtxnwtqwfagjzkvgsncs dentro de BEGIN READ ONLY, com SET ROLE postgres:

1. Definição viva de crm.emit_opportunity_stage_event:
- SECURITY DEFINER
- SET search_path TO ''
- guarda atual retorna imediatamente quando crm_emits_conversions é false
- lança `IMP-205 ghl_location_id is required for tenant %` quando ghl_location_id está vazio
- lê template de evento GHL em public.events_normalized
- escreve events_raw, events_normalized e conversion_outbox
- não há origem Google nas colunas de crm.opportunities usadas pela função atual

2. Nulabilidade viva de public.events_normalized:
- client_id: YES
- ghl_location_id: NO
- ghl_location_name: YES
- client_name: YES
- location_id: YES
- location_name: YES

Bloqueios objetivos:
- A decisão da IMP-216 exige que cliente sem GHL escreva events_normalized com ghl_location_id NULL. A coluna viva é NOT NULL. Não existe adaptação autorizada por analogia.
- As colunas de origem Google exigidas (gclid, gbraid, wbraid, utm_source, utm_medium, utm_campaign, utm_content, utm_term) existem em public.events_normalized, mas não existem em crm.opportunities. A origem Google depende da IMP-230 e não pode ser inventada nesta IMP.

Ação: parar e escalar ao Coordenador/Head para decisão sobre a incompatibilidade de schema e a dependência da IMP-230. Nenhuma migration, rollback, APLICAR ou aceite foi criado. Nenhuma migration foi executada em staging ou produção. Nenhuma flag foi alterada.

Verificação executada:
- `python scripts/db-prova.py --dry-run` → passed; crm.opportunities 21 colunas/439 linhas, crm.contacts 9/901, crm.activities 12/12578, crm.processed_events 10/12578, public.stevo_events_raw 15/48897; writes=0, ddl=0, commit=0.
- leitura adicional de produção → BEGIN READ ONLY; função, trigger, nulabilidade e colunas Google consultados; rollback da transação somente leitura.

Os resultados literais completos das consultas e a saída completa do dry-run estão no corpo do PR draft.


ATUALIZAÇÃO APÓS DECISÃO DO HEAD

A decisão do Head desbloqueou o passo 0 e a implementação foi entregue nos commits da branch feat/imp-216-conversion-bridge. Migration, rollback, APLICAR, aceite e isolamento foram criados; nenhum deles foi executado em banco.

Gate pendente: `npx tsc --noEmit` não rodou porque TypeScript não está instalado e o npx recusou instalar o pacote ausente. `node --test lib/*.test.mjs` passou com 35/35; `scripts/db-prova.py --dry-run` passou com writes=0, ddl=0, commit=0.

Aplicação continua bloqueada até revisão do Head e autorização do Caio.
