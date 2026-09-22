-- IMP-218 isolation; the outer staging runner ends with ROLLBACK.
set local statement_timeout = '8s';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"bb04435c-fabb-4ba8-b5b5-e0175d9ca17d","role":"authenticated"}', true);

do $central$
declare leaked uuid; n bigint;
begin
  begin
    select distinct co.normalized_event_id into leaked
      from public.conversion_outbox co
      join public.events_normalized en on en.id=co.normalized_event_id
     where en.client_id is distinct from '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid limit 1;
    if leaked is not null then raise exception 'IMP218_ISOLATION: Central recebeu evento %', leaked; end if;
  exception when insufficient_privilege then null;
  end;
  begin
    select count(*) into n from public.crm_move_stage('30000000-0000-4000-8000-000000000008'::uuid,'agendado',1,'IMP218 isolamento');
    if n <> 0 then raise exception 'IMP218_ISOLATION: RPC cross-tenant retornou % linhas', n; end if;
  exception when insufficient_privilege then null;
       when others then if sqlstate not in ('P0001','42501') then raise; end if;
  end;
end
$central$;

select set_config('request.jwt.claims', '{"sub":"7c3296f4-13c7-42d1-89eb-72aecec905ba","role":"authenticated"}', true);
do $royal$
declare leaked uuid; n bigint;
begin
  begin
    select distinct co.normalized_event_id into leaked
      from public.conversion_outbox co
      join public.events_normalized en on en.id=co.normalized_event_id
     where en.client_id is distinct from 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid limit 1;
    if leaked is not null then raise exception 'IMP218_ISOLATION: Royal recebeu evento %', leaked; end if;
  exception when insufficient_privilege then null;
  end;
  begin
    select count(*) into n from public.crm_move_stage('30000000-0000-4000-8000-000000000008'::uuid,'agendado',1,'IMP218 isolamento');
    if n <> 0 then raise exception 'IMP218_ISOLATION: RPC cross-tenant retornou % linhas', n; end if;
  exception when insufficient_privilege then null;
       when others then if sqlstate not in ('P0001','42501') then raise; end if;
  end;
end
$royal$;
