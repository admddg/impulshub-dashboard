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

commit;
