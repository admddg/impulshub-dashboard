-- IMP-229: arquivo de aplicação manual.
-- Executar somente após revisão e autorização de produção.

-- IMP-229: substitui a avaliação por linha da membership nas cinco RLS de leitura.
-- A migration é deliberadamente independente da IMP-213.

begin;
set local lock_timeout = '5s';

create or replace function private.my_client_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select cu.client_id
  from public.client_users cu
  where cu.user_id = (select auth.uid())
    and cu.is_active
$$;

revoke all on function private.my_client_ids() from public, anon;
grant execute on function private.my_client_ids() to authenticated;

alter policy meta_ads_daily_select_by_client_user
  on public.meta_ads_daily
  using (
    client_id in (
      select client_id
      from private.my_client_ids() as client_id
    )
  );

alter policy google_ads_campaign_daily_select_by_client
  on public.google_ads_campaign_daily
  using (
    client_id in (
      select client_id
      from private.my_client_ids() as client_id
    )
  );

alter policy google_ads_keywords_daily_select_by_client_user
  on public.google_ads_keywords_daily
  using (
    client_id in (
      select client_id
      from private.my_client_ids() as client_id
    )
  );

alter policy google_ads_daily_select_by_client_user
  on public.google_ads_daily
  using (
    client_id in (
      select client_id
      from private.my_client_ids() as client_id
    )
  );

alter policy events_normalized_select_by_client_user
  on public.events_normalized
  using (
    client_id in (
      select client_id
      from private.my_client_ids() as client_id
    )
  );

-- Gate: aborta antes do commit se qualquer fronteira ficar fora do helper.
do $gate$
declare
  missing_policies integer;
  unsafe_policies integer;
begin
  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'my_client_ids'
      and pg_get_function_identity_arguments(p.oid) = ''
      and p.provolatile = 's'
      and p.prosecdef
  ) then
    raise exception 'IMP229_GATE: private.my_client_ids() ausente ou insegura';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'user_can_access_client'
      and pg_get_function_identity_arguments(p.oid) = 'p_client_id uuid'
  ) then
    raise exception 'IMP229_GATE: private.user_can_access_client(uuid) ausente';
  end if;

  select count(*) into missing_policies
  from (values
    ('meta_ads_daily', 'meta_ads_daily_select_by_client_user'),
    ('google_ads_campaign_daily', 'google_ads_campaign_daily_select_by_client'),
    ('google_ads_keywords_daily', 'google_ads_keywords_daily_select_by_client_user'),
    ('google_ads_daily', 'google_ads_daily_select_by_client_user'),
    ('events_normalized', 'events_normalized_select_by_client_user')
  ) required(tablename, policyname)
  where not exists (
    select 1
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = required.tablename
      and p.polname = required.policyname
  );

  if missing_policies <> 0 then
    raise exception 'IMP229_GATE: % policies esperadas ausentes', missing_policies;
  end if;

  select count(*) into unsafe_policies
  from (values
    ('meta_ads_daily', 'meta_ads_daily_select_by_client_user'),
    ('google_ads_campaign_daily', 'google_ads_campaign_daily_select_by_client'),
    ('google_ads_keywords_daily', 'google_ads_keywords_daily_select_by_client_user'),
    ('google_ads_daily', 'google_ads_daily_select_by_client_user'),
    ('events_normalized', 'events_normalized_select_by_client_user')
  ) required(tablename, policyname)
  where not exists (
    select 1
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = required.tablename
      and p.polname = required.policyname
      and pg_get_expr(p.polqual, p.polrelid) ilike '%my_client_ids%'
  );

  if unsafe_policies <> 0 then
    raise exception 'IMP229_GATE: % policies sem my_client_ids()', unsafe_policies;
  end if;

  if has_function_privilege('anon', 'private.my_client_ids()', 'execute') then
    raise exception 'IMP229_GATE: anon pode executar private.my_client_ids()';
  end if;

  if not has_function_privilege('authenticated', 'private.my_client_ids()', 'execute') then
    raise exception 'IMP229_GATE: authenticated não pode executar private.my_client_ids()';
  end if;
end;
$gate$;

insert into supabase_migrations.schema_migrations (version, name)
values ('20260927000000', 'imp229_rls_client_ids')
on conflict (version) do nothing;

commit;
