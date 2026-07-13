-- ============================================================================
-- ImpulsHub — Reforço de segurança: v_workflow_health_daily
-- Achado: a view foi criada de propósito sem filtro por client_id (é uma
-- visão agregada "cross-cliente" para a agência), mas isso a deixava aberta
-- para QUALQUER usuário autenticado (inclusive um usuário de cliente único)
-- consultá-la direto via supabase-js e ver dados de outros clientes.
--
-- Correção: adiciona uma trava "tudo ou nada" na própria view — só retorna
-- linhas se o usuário logado tiver acesso a MAIS DE 1 cliente ativo em
-- client_users (o mesmo critério que já usamos no frontend para "é da
-- agência", agora imposto de verdade pelo banco, não só escondido na tela).
-- Um usuário de cliente único (o caso real de produção) recebe lista vazia,
-- não erro — o app trata isso normalmente.
--
-- Nenhuma coluna muda — CREATE OR REPLACE é seguro, não quebra nada que já
-- consulta esta view pelas colunas de sempre.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_workflow_health_daily
WITH (security_invoker = false) AS
SELECT
  date_trunc('day', (started_at AT TIME ZONE 'America/Sao_Paulo')) AS day,
  workflow_key,
  workflow_name,
  workflow_category,
  client_id,
  client_name,
  count(*) AS total_executions,
  count(*) FILTER (WHERE (status = 'success')) AS success_count,
  count(*) FILTER (WHERE (status = 'error')) AS error_count,
  count(*) FILTER (WHERE (status = 'partial')) AS partial_count,
  round(avg(duration_ms)) AS avg_duration_ms,
  max(started_at) AS last_execution_at
FROM workflow_execution_logs
WHERE (
  -- trava: só passa se o usuário logado tiver mais de 1 cliente ativo
  SELECT count(*) FROM public.client_users cu
  WHERE cu.user_id = auth.uid() AND cu.is_active = true
) > 1
GROUP BY
  date_trunc('day', (started_at AT TIME ZONE 'America/Sao_Paulo')),
  workflow_key, workflow_name, workflow_category, client_id, client_name;

GRANT SELECT ON public.v_workflow_health_daily TO authenticated;


-- ============================================================================
-- VALIDAÇÃO — rodar depois de aplicar
-- ============================================================================

-- 1. Como admin (ignora tudo, sempre vê) — confirma que a view ainda funciona
select day, workflow_key, client_name, total_executions
from v_workflow_health_daily
order by day desc limit 5;

-- 2. Simula um usuário de CLIENTE ÚNICO (deve retornar VAZIO)
--    Troque o uuid abaixo por um user_id que hoje só tem 1 cliente ativo
--    em client_users, se quiser testar com um caso real.
-- set role authenticated;
-- set request.jwt.claims = '{"sub": "UUID_DE_USUARIO_CLIENTE_UNICO"}';
-- select count(*) from v_workflow_health_daily;
-- reset role;

-- 3. Confirma quantos usuários hoje se qualificam como "multi-cliente"
--    (só eles vão enxergar esta view)
select user_id, count(*) as clientes_ativos
from client_users
where is_active = true
group by user_id
having count(*) > 1;
