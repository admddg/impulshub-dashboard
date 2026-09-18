-- IMP-204: agenda o parser.
--
-- crm.stevo_parse_messages e uma funcao e ninguem a chamava. Sem agendamento, contato
-- novo nao aparece sozinho e a clinica piloto nao consegue operar.
--
-- O lote e limitado de proposito: cada execucao termina rapido e a proxima pega o
-- resto. Com o volume atual (cerca de 1.200 mensagens por dia entre tres clientes),
-- um minuto de intervalo deixa a fila praticamente sempre vazia.
--
-- A funcao ja e idempotente por crm.processed_events, entao execucoes sobrepostas
-- nao produzem efeito duplicado.

create extension if not exists pg_cron;

select cron.schedule(
  'crm-stevo-parser',
  '* * * * *',
  $job$select crm.stevo_parse_messages(2000);$job$
);
