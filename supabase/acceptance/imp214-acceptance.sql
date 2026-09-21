\set ON_ERROR_STOP on
-- IMP-214: aceite de dois donos, elegibilidade, origem, filtros e isolamento.
-- Executar somente dentro da transação de prova; termina com ROLLBACK.

begin;
set local statement_timeout = '8s';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"d036c4d6-0969-4175-b917-ff7e4dd3b376","role":"authenticated"}', true);

-- Estrutura e contrato público.
do $structure$
declare n bigint;
begin
  select count(*) into n from information_schema.columns
   where table_schema = 'crm' and table_name = 'tenant_memberships'
     and column_name = 'is_assignable';
  if n <> 1 then raise exception 'IMP214_STRUCTURE: is_assignable ausente'; end if;
  select count(*) into n from information_schema.columns
   where table_schema = 'crm' and table_name = 'opportunities'
     and column_name in ('crc_owner_profile_id','sales_owner_profile_id');
  if n <> 2 then raise exception 'IMP214_STRUCTURE: colunas de dono ausentes'; end if;
  if exists (select 1 from information_schema.columns where table_schema='crm' and table_name='opportunities' and column_name='owner_profile_id') then
    raise exception 'IMP214_STRUCTURE: owner_profile_id antigo ainda existe';
  end if;
  if not exists (select 1 from pg_constraint where conname='opportunities_tenant_crc_owner_profile_id_fkey')
     or not exists (select 1 from pg_constraint where conname='opportunities_tenant_sales_owner_profile_id_fkey') then
    raise exception 'IMP214_STRUCTURE: FKs compostas ausentes';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
                  where ns.nspname='public' and p.proname='crm_set_owner'
                    and pg_get_function_identity_arguments(p.oid)='p_opportunity_id uuid, p_role text, p_owner_profile_id uuid') then
    raise exception 'IMP214_STRUCTURE: assinatura nova de crm_set_owner ausente';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
                  where ns.nspname='public' and p.proname='crm_board_counts'
                    and pg_get_function_identity_arguments(p.oid) like 'p_client_id uuid, p_opened_from date, p_opened_to date, p_owner_role text%') then
    raise exception 'IMP214_STRUCTURE: assinatura nova de crm_board_counts ausente';
  end if;
end;
$structure$;

-- Todos os donos existentes continuam no mesmo tenant, ativos e assignable.
do $owners$
declare bad bigint;
begin
  select count(*) into bad
    from crm.opportunities o
   where (o.crc_owner_profile_id is not null and not exists (
            select 1 from crm.tenant_memberships tm where tm.tenant_id=o.tenant_id and tm.profile_id=o.crc_owner_profile_id and tm.status='active' and tm.is_assignable))
      or (o.sales_owner_profile_id is not null and not exists (
            select 1 from crm.tenant_memberships tm where tm.tenant_id=o.tenant_id and tm.profile_id=o.sales_owner_profile_id and tm.status='active' and tm.is_assignable));
  if bad <> 0 then raise exception 'IMP214_OWNERS: % donos inválidos', bad; end if;
  if exists (select 1 from public.v_crm_owners_v1 where not is_assignable) then
    raise exception 'IMP214_OWNERS: view devolveu membro não assignable';
  end if;
end;
$owners$;

-- A origem vem dos campos canônicos e nunca de heurística do frontend.
do $origin$
declare bad bigint;
begin
  select count(*) into bad from public.v_crm_cards_v1 c
   join crm.opportunities o on o.id=c.opportunity_id
  where c.origem <> case when o.conversion_source is not null or o.ctwa_clid is not null or o.meta_ad_id is not null then 'anuncio' else 'organico' end;
  if bad <> 0 then raise exception 'IMP214_ORIGIN: % cards com origem divergente', bad; end if;
end;
$origin$;

-- Agência consegue atribuir ambos os papéis a uma membership assignable do mesmo tenant.
do $positive$
declare opp uuid; member uuid; got bigint;
begin
  select o.id into opp from crm.opportunities o where o.tenant_id='19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid and o.status='open' limit 1;
  select tm.profile_id into member from crm.tenant_memberships tm where tm.tenant_id='19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid and tm.status='active' and tm.is_assignable limit 1;
  if opp is null or member is null then raise exception 'IMP214_FIXTURE: Central sem oportunidade ou assignable'; end if;
  select count(*) into got from public.crm_set_owner(opp, 'crc', member);
  if got <> 1 then raise exception 'IMP214_POSITIVE: CRC não retornou card'; end if;
  select count(*) into got from public.crm_set_owner(opp, 'sales', member);
  if got <> 1 then raise exception 'IMP214_POSITIVE: Vendas não retornou card'; end if;
  if not exists (select 1 from public.v_crm_cards_v1 where opportunity_id=opp and crc_owner_profile_id=member and sales_owner_profile_id=member) then
    raise exception 'IMP214_POSITIVE: donos não foram persistidos no card';
  end if;
  perform public.crm_set_owner(opp, 'crc', null);
  perform public.crm_set_owner(opp, 'sales', null);
end;
$positive$;

-- Cross-tenant, perfil não assignable e perfil inativo devem falhar.
do $negative$
declare royal_opp uuid; central_member uuid; royal_viewer uuid; inactive_profile uuid; inactive_membership uuid; msg text;
begin
  select id into royal_opp from crm.opportunities where tenant_id='fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid and status='open' limit 1;
  select profile_id into central_member from crm.tenant_memberships where tenant_id='19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid and status='active' and is_assignable limit 1;
  select profile_id into royal_viewer from crm.tenant_memberships where tenant_id='fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid and status='active' and role='viewer' limit 1;
  begin perform public.crm_set_owner(royal_opp, 'crc', central_member); raise exception 'IMP214_NEGATIVE: cross-tenant aceito'; exception when others then if position('CRM_INVALID_OWNER' in sqlerrm)=0 then raise; end if; end;
  begin perform public.crm_set_owner(royal_opp, 'crc', royal_viewer); raise exception 'IMP214_NEGATIVE: não-assignable aceito'; exception when others then if position('CRM_INVALID_OWNER' in sqlerrm)=0 then raise; end if; end;

  set local role postgres;
  select p.id into inactive_profile from crm.profiles p where not exists (select 1 from crm.tenant_memberships tm where tm.tenant_id='fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid and tm.profile_id=p.id) limit 1;
  if inactive_profile is null then raise exception 'IMP214_FIXTURE: perfil livre ausente'; end if;
  insert into crm.tenant_memberships(tenant_id, profile_id, role, status) values ('fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid, inactive_profile, 'attendant', 'suspended') returning id into inactive_membership;
  set local role authenticated;
  begin perform public.crm_set_owner(royal_opp, 'sales', inactive_profile); raise exception 'IMP214_NEGATIVE: inativo aceito'; exception when others then if position('CRM_INVALID_OWNER' in sqlerrm)=0 then raise; end if; end;
end;
$negative$;

-- Contagens e cards seguem iguais para cada filtro de origem e dono.
do $counts$
declare expected bigint; actual bigint; role_code text; origin_code text; profile_id uuid;
begin
  foreach origin_code in array array[null::text, 'anuncio', 'organico'] loop
    select count(*) into expected from public.v_crm_cards_v1 c where c.client_id='19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid and (origin_code is null or c.origem=origin_code);
    select coalesce(sum(opportunities),0) into actual from public.crm_board_counts('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid,null,null,null,null,false,origin_code);
    if expected <> actual then raise exception 'IMP214_COUNTS: origem % expected %, actual %', origin_code, expected, actual; end if;
  end loop;
  select profile_id into profile_id from crm.tenant_memberships where tenant_id='19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid and is_assignable limit 1;
  foreach role_code in array array['crc','sales'] loop
    select count(*) into expected from public.v_crm_cards_v1 c where c.client_id='19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid and (case role_code when 'crc' then c.crc_owner_profile_id else c.sales_owner_profile_id end)=profile_id;
    select coalesce(sum(opportunities),0) into actual from public.crm_board_counts('19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid,null,null,role_code,profile_id,false,null);
    if expected <> actual then raise exception 'IMP214_COUNTS: papel % expected %, actual %', role_code, expected, actual; end if;
  end loop;
end;
$counts$;

-- Isolamento: Central attendant vê Central; Royal viewer não vê Central.
select set_config('request.jwt.claims', '{"sub":"bb04435c-fabb-4ba8-b5b5-e0175d9ca17d","role":"authenticated"}', true);
do $central$
declare bad bigint;
begin
  select count(*) into bad from public.v_crm_cards_v1 where client_id <> '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid;
  if bad <> 0 then raise exception 'IMP214_ISOLATION: Central viu % cards de outro tenant', bad; end if;
  select count(*) into bad from public.v_crm_owners_v1 where client_id <> '19c9d8c6-1a6d-499b-95fd-cc23d1cd555b'::uuid;
  if bad <> 0 then raise exception 'IMP214_ISOLATION: Central viu % donos de outro tenant', bad; end if;
end;
$central$;
select set_config('request.jwt.claims', '{"sub":"7c3296f4-13c7-42d1-89eb-72aecec905ba","role":"authenticated"}', true);
do $royal$
declare bad bigint;
begin
  select count(*) into bad from public.v_crm_cards_v1 where client_id <> 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid;
  if bad <> 0 then raise exception 'IMP214_ISOLATION: Royal viu % cards de outro tenant', bad; end if;
  select count(*) into bad from public.v_crm_owners_v1 where client_id <> 'fa6fc071-7529-4317-93cb-9b0bfea3bca3'::uuid;
  if bad <> 0 then raise exception 'IMP214_ISOLATION: Royal viu % donos de outro tenant', bad; end if;
end;
$royal$;

rollback;
