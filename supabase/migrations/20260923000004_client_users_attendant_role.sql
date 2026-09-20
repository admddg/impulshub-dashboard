-- IMP-208: papel de atendente de clinica em public.client_users.
--
-- O CHECK so aceitava owner/admin/viewer/agency. Nenhum desses serve para a
-- equipe de uma clinica operar o CRM: 'viewer' e bloqueado por trigger e
-- 'admin' daria a entender permissao de gestao da conta.
--
-- Conferido antes de alterar: todos os leitores de client_users.role no banco
-- comparam contra 'viewer' (validate_stage_history, validate_commercial_outcome,
-- crm_guard, v_crm_my_role_v1, v_crm_owners_v1). O app pergunta apenas
-- "sou agency?" via am_i_agency_user(). Um attendant nao e agency, que e o
-- comportamento correto: equipe de clinica nao ve o painel interno.
--
-- NOTA DE PROCEDENCIA: aplicado direto em producao em 18/09/2026 e registrado
-- no ledger como 20260918203014. Este arquivo foi escrito depois, a partir do
-- texto exato guardado em supabase_migrations.schema_migrations, para o repo
-- voltar a descrever o banco. Ver 20260925000003_realign_migration_ledger.sql.

set local lock_timeout = '5s';

alter table public.client_users drop constraint client_users_role_check;

alter table public.client_users add constraint client_users_role_check
  check (role = any (array['owner','admin','viewer','agency','attendant']));
