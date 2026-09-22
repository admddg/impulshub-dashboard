\set ON_ERROR_STOP on

-- Isolamento IMP-216. Executar somente em sessao autorizada; termina em ROLLBACK.
begin;
set local statement_timeout = '8s';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"bb04435c-fabb-4ba8-b5b5-e0175d9ca17d","role":"authenticated"}', true);
do $central$
declare
  leaked uuid;
  rows_returned bigint;
begin
  begin
    select distinct e.client_id into leaked
      from public.events_normalized e
     where e.client_id is distinct from '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid
     limit 1;
    if leaked is not null then raise exception 'IMP216_ISOLATION: Central recebeu %', leaked; end if;
  exception when insufficient_privilege then null;
  end;
  begin
    select count(*) into rows_returned
      from public.crm_board_counts('fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid, current_date - 30, current_date, null, null, false, null);
    if rows_returned <> 0 then raise exception 'IMP216_ISOLATION: RPC de Royal retornou % linhas para Central', rows_returned; end if;
  exception when insufficient_privilege then null; end;
end
$central$;

select set_config('request.jwt.claims', '{"sub":"7c3296f4-13c7-42d1-89eb-72aecec905ba","role":"authenticated"}', true);
do $royal$
declare
  leaked uuid;
  rows_returned bigint;
begin
  begin
    select distinct e.client_id into leaked
      from public.events_normalized e
     where e.client_id is distinct from 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid
     limit 1;
    if leaked is not null then raise exception 'IMP216_ISOLATION: Royal recebeu %', leaked; end if;
  exception when insufficient_privilege then null;
  end;
  begin
    select count(*) into rows_returned
      from public.crm_board_counts('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid, current_date - 30, current_date, null, null, false, null);
    if rows_returned <> 0 then raise exception 'IMP216_ISOLATION: RPC de Central retornou % linhas para Royal', rows_returned; end if;
  exception when insufficient_privilege then null;
  end;
end
$royal$;

rollback;
