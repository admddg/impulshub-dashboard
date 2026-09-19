-- Corrige v_crm_owners_v1: o seletor de dono mostrava apenas o usuario logado.
--
-- public.client_users tem RLS "user_id = auth.uid()": cada pessoa so enxerga a
-- propria linha. A view calculava can_write com left join nessa tabela, entao
-- para qualquer outro membro o join voltava nulo, can_write virava false, e a
-- pessoa sumia do seletor. Na Royal, Caio via apenas Caio -- Igor nunca
-- aparecia, apesar de ter membership ativa e permissao de escrita.
--
-- A autoridade continua sendo public.client_users, que e de onde o trigger le.
-- So o caminho de leitura muda: uma funcao security definer, que responde
-- somente para quem ja e membro do cliente perguntado.

set local lock_timeout = '5s';

create function crm.can_write(p_tenant_id uuid, p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select case
    when not crm.is_member(p_tenant_id) then false
    else coalesce((
      select cu.is_active and pg_catalog.lower(cu.role) <> 'viewer'
        from public.client_users cu
       where cu.client_id = p_tenant_id
         and cu.user_id = p_profile_id
       limit 1
    ), false)
  end
$fn$;

revoke all on function crm.can_write(uuid, uuid) from public, anon;
grant execute on function crm.can_write(uuid, uuid) to authenticated;

create or replace view public.v_crm_owners_v1
with (security_invoker = true) as
select tm.tenant_id as client_id,
       tm.profile_id,
       p.display_name,
       tm.role as membership_role,
       crm.can_write(tm.tenant_id, tm.profile_id) as can_write
  from crm.tenant_memberships tm
  join crm.profiles p on p.id = tm.profile_id
 where tm.status = 'active';
