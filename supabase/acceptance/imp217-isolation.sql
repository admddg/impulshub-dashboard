-- IMP-217 tenant isolation; transaction ends ROLLBACK.
-- Uses the same authenticated-user shape as imp213-isolation.sql.
begin;
set local statement_timeout = '8s';
set local role authenticated;

select set_config('request.jwt.claims', '{"sub":"bb04435c-fabb-4ba8-b5b5-e0175d9ca17d","role":"authenticated"}', true);
do $central$
declare
  leaked uuid;
  row_count bigint;
begin
  begin
    select distinct e.client_id into leaked
      from public.events_normalized e
     where e.client_id is distinct from '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid
     limit 1;
    if leaked is not null then
      raise exception 'IMP217_ISOLATION: Central recebeu %', leaked;
    end if;
  exception when insufficient_privilege then null;
  end;

  begin
    select count(*) into row_count
      from public.crm_register_won(
        '00000000-0000-0000-0000-000000000000'::uuid,
        'IMP217 isolamento', 0, 100, 'BRL');
    if row_count <> 0 then
      raise exception 'IMP217_ISOLATION: crm_register_won retornou % linhas', row_count;
    end if;
  exception when insufficient_privilege then null;
       when others then
         if sqlstate not in ('P0001', '42501') then raise; end if;
  end;
end
$central$;

select set_config('request.jwt.claims', '{"sub":"7c3296f4-13c7-42d1-89eb-72aecec905ba","role":"authenticated"}', true);
do $royal$
declare
  leaked uuid;
  row_count bigint;
begin
  begin
    select distinct e.client_id into leaked
      from public.events_normalized e
     where e.client_id is distinct from 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid
     limit 1;
    if leaked is not null then
      raise exception 'IMP217_ISOLATION: Royal recebeu %', leaked;
    end if;
  exception when insufficient_privilege then null;
  end;

  begin
    select count(*) into row_count
      from public.crm_register_won(
        '00000000-0000-0000-0000-000000000000'::uuid,
        'IMP217 isolamento', 0, 100, 'BRL');
    if row_count <> 0 then
      raise exception 'IMP217_ISOLATION: crm_register_won retornou % linhas', row_count;
    end if;
  exception when insufficient_privilege then null;
       when others then
         if sqlstate not in ('P0001', '42501') then raise; end if;
  end;
end
$royal$;

rollback;
