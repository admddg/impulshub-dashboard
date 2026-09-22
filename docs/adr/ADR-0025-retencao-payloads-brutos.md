# ADR-0025 — Retenção de payloads brutos de mídia

- **Status:** proposta para a IMP-231
- **Data:** 22/09/2026
- **Decide:** Caio

## Contexto

O plano free atingiu a cota de disco: a limpeza manual do Head removeu payloads
brutos antigos de `public.meta_ads_daily` e reduziu o uso observado de
aproximadamente 636 MB para 452 MB. A tabela mantém colunas estruturadas para
métricas e criativo, portanto os jsonb antigos são uma cópia operacionalmente
redundante depois da janela inicial.

A investigação somente-leitura também encontrou payloads grandes em
`stevo_events_raw`, `events_raw` e `events_normalized`, mas não decidiu sua
retenção. Em particular, `stevo_events_raw.payload_hash` participa do parser e
da deduplicação.

## Decisão

1. `meta_ads_daily` retém os nove payloads brutos por 14 dias. Depois disso, a
   rotina diária zera somente os jsonb, preservando métricas e campos
   estruturados.
2. A rotina é um job `pg_cron` diário às 03:15 UTC, com predicado idempotente.
   `VACUUM FULL` não é automático; é ação manual a ser avaliada pelo Head/Caio
   quando o TOAST continuar inchado.
3. `stevo_events_raw`, `events_raw` e `events_normalized` não são alteradas por
   esta ADR. São candidatos futuros apenas após confirmar dependências de
   replay/auditoria e equivalência do dado estruturado.

## Motivo e extensão futura

A janela de 14 dias reproduz a contenção já aplicada e limita perda de contexto
recente sem criar uma fila ou serviço novo. Para estender a política a outra
tabela, exigir: (a) idade mínima explicitamente medida; (b) confirmação de que
o dado estruturado equivalente existe; (c) inventário de uso em parsing,
replay, dedupe e auditoria; (d) migration idempotente, rollback documentando a
irreversibilidade e gate de segurança.

## Consequências

A cota deixa de depender de limpeza manual recorrente para `meta_ads_daily`, mas
os valores jsonb antigos não podem ser restaurados pelo rollback. As três
tabelas de eventos continuam ocupando espaço até existir decisão específica;
isto é intencional para não quebrar dedupe, auditoria ou reprocessamento.
