-- IMP-231 rollback.
-- ATENÇÃO: este rollback NÃO restaura os dados apagados. Os valores jsonb
-- zerados pela retenção são irrecuperáveis. Ele só remove a definição do job
-- pg_cron criada pela migration; não remove a extensão pg_cron compartilhada.

select cron.unschedule('meta-ads-raw-retention-daily');
