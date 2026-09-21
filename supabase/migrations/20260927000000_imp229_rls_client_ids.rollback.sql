-- IMP-229 rollback: restaura as policies originais registradas antes da migration.
-- Executável dentro de uma transação; valide em staging antes de usar.

begin;
set local lock_timeout = '5s';

alter policy meta_ads_daily_select_by_client_user
  on public.meta_ads_daily
  using (private.user_can_access_client(client_id));

alter policy google_ads_campaign_daily_select_by_client
  on public.google_ads_campaign_daily
  using (private.user_can_access_client(client_id));

alter policy google_ads_keywords_daily_select_by_client_user
  on public.google_ads_keywords_daily
  using (private.user_can_access_client(client_id));

alter policy google_ads_daily_select_by_client_user
  on public.google_ads_daily
  using (private.user_can_access_client(client_id));

alter policy events_normalized_select_by_client_user
  on public.events_normalized
  using (private.user_can_access_client(client_id));

drop function private.my_client_ids();

do $rollback_gate$
declare
  remaining_policies integer;
begin
  select count(*) into remaining_policies
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
      and pg_get_expr(p.polqual, p.polrelid) ilike '%user_can_access_client%'
  );

  if remaining_policies <> 0 then
    raise exception 'IMP229_ROLLBACK: % policies não restauradas', remaining_policies;
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'my_client_ids'
      and pg_get_function_identity_arguments(p.oid) = ''
  ) then
    raise exception 'IMP229_ROLLBACK: private.my_client_ids() ainda existe';
  end if;
end;
$rollback_gate$;

commit;
