-- Contagem do kanban com os mesmos filtros aplicados aos cards.
--
-- v_crm_board_counts_v1 nao aceita parametro, entao filtrar os cards por data
-- ou dono deixaria o numero no topo de cada coluna contando o conjunto inteiro.
-- O atendente veria "Atendimento 173" com 12 cards na tela e nao saberia qual
-- dos dois numeros acreditar.
--
-- Uma funcao, uma ida ao banco, e a contagem continua calculada no Postgres --
-- a regra numero um do projeto vale para contagem tambem.
--
-- Sem filtro, devolve exatamente o mesmo que a view. security invoker: a RLS
-- de crm.opportunities continua valendo.

set local lock_timeout = '5s';

create function public.crm_board_counts(
  p_client_id        uuid,
  p_opened_from      date default null,
  p_opened_to        date default null,
  p_owner_profile_id uuid default null,
  p_unassigned       boolean default false
)
returns table (
  client_id      uuid,
  stage_code     text,
  stage_label    text,
  stage_position smallint,
  is_terminal    boolean,
  opportunities  bigint
)
language sql
stable
security invoker
set search_path = ''
as $fn$
  select t.id, s.code, s.label, s.position, s.is_terminal, count(o.id)
    from crm.tenants t
   cross join crm.global_pipeline_stages s
    join crm.global_pipeline_versions v
      on v.id = s.pipeline_version_id and v.status = 'active'
    left join crm.opportunities o
      on o.tenant_id = t.id
     and o.current_stage_id = s.id
     and (p_opened_from is null or o.opened_at >= p_opened_from::timestamptz)
     and (p_opened_to   is null or o.opened_at <  (p_opened_to + 1)::timestamptz)
     and (case
            when p_unassigned then o.owner_profile_id is null
            when p_owner_profile_id is not null then o.owner_profile_id = p_owner_profile_id
            else true
          end)
   where t.id = p_client_id
   group by t.id, s.code, s.label, s.position, s.is_terminal
$fn$;

revoke all on function public.crm_board_counts(uuid, date, date, uuid, boolean) from public, anon;
grant execute on function public.crm_board_counts(uuid, date, date, uuid, boolean) to authenticated;

comment on function public.crm_board_counts(uuid, date, date, uuid, boolean) is
  'Contagem do kanban com os mesmos filtros dos cards. Sem filtro, equivale a v_crm_board_counts_v1. p_unassigned tem precedencia sobre p_owner_profile_id.';
