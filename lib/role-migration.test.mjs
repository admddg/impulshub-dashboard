import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const migrationPath = new URL('../supabase/migrations/20260928000000_imp213_role_visibility.sql', import.meta.url)
const sql = readFileSync(migrationPath, 'utf8').toLowerCase()

const qualified = (kind, name) => new RegExp(
  `create or replace ${kind} "?public"?\\."?${name}"?`,
)

const guardedRpcs = [
  'get_client_overview_v2',
  'get_meta_ads_summary_v2',
  'get_google_ads_summary_v2',
]

const guardedFinancialViews = [
  'v_ads_spend_daily',
  'v_channel_performance_daily',
  'v_client_daily_pulse',
  'v_client_performance_daily',
  'v_client_performance_daily_v2',
  'v_crm_card_history_v1',
  'v_crm_events_daily_v2',
  'v_crm_events_enriched',
  'v_crm_events_feed_v2',
  'v_crm_funnel_daily',
  'v_crm_opportunities',
  'v_crm_opportunities_v2',
  'v_crm_sales_daily_v2',
  'v_crm_sales_v2',
  'v_google_ads_keywords_daily',
  'v_google_ads_v2',
  'v_google_campaign_daily',
  'v_google_campaign_performance',
  'v_google_keywords_v2',
  'v_meta_account_daily',
  'v_meta_ads_v2',
  'v_meta_campaign_daily',
  'v_meta_campaign_performance',
  'v_meta_creative_daily',
  'v_meta_creative_performance',
]

test('migration centraliza autoridade financeira em helper security definer', () => {
  assert.match(sql, /create or replace function private\.can_view_client_financials/)
  assert.match(sql, /security definer/)
  assert.match(sql, /set search_path = ''/)
  assert.match(sql, /cu\.role = any \(array\['agency', 'owner', 'admin', 'manager', 'viewer'\]\)/)
})

test('migration protege as três RPCs sem mover seus OIDs', () => {
  for (const fn of guardedRpcs) assert.match(sql, qualified('function', fn))
  assert.doesNotMatch(sql, /alter function [^;]+ set schema/)
})

test('migration filtra todo o catálogo de views financeiras sem mover OIDs', () => {
  for (const view of guardedFinancialViews) {
    assert.match(sql, qualified('view', view), `${view} sem filtro financeiro`)
  }
  assert.doesNotMatch(sql, /alter view [^;]+ set schema/)
  assert.match(sql, /security_barrier"?\s*=\s*'?true'?/)
})

test('migration fecha tabelas financeiras na fronteira mais baixa', () => {
  for (const policy of [
    'meta_ads_daily_select_by_client_user',
    'google_ads_daily_select_by_client_user',
    'google_ads_campaign_daily_select_by_client',
    'google_ads_keywords_daily_select_by_client_user',
  ]) {
    assert.match(sql, new RegExp(`alter policy "?${policy}"?`))
  }

  for (const table of [
    'external_meta_ads_raw', 'external_ga4_raw', 'external_hotmart_raw', 'stevo_events_raw',
  ]) {
    assert.match(sql, new RegExp(`revoke all on table public\\.${table}`))
  }
})

test('events_normalized expõe somente colunas operacionais a authenticated', () => {
  assert.match(sql, /revoke all on table public\.events_normalized from public, anon, authenticated/)
  const grant = sql.match(/grant select \(([\s\S]*?)\) on table public\.events_normalized to authenticated/)
  assert.ok(grant)
  for (const forbidden of [
    'budget_status', 'budget_value', 'closed_value', 'payment_method',
    'normalized_payload', 'valor_ganho', 'forma_ganho', 'payload',
  ]) {
    assert.doesNotMatch(grant[1], new RegExp(`\\b${forbidden}\\b`))
  }
})

test('migration mantém execução pública fechada e autenticada explícita', () => {
  assert.match(sql, /revoke all on function "?public"?\."?get_client_overview_v2"?[\s\S]*from public/)
  assert.match(sql, /grant execute on function "?public"?\."?get_client_overview_v2"?[\s\S]*to authenticated/)
  assert.match(sql, /grant execute on function private\.can_view_client_financials\(uuid\) to authenticated/)
})

test('migration não promove viewers nem altera memberships operacionais', () => {
  assert.doesNotMatch(sql, /update public\.client_users[\s\S]*set role = 'manager'/)
  assert.doesNotMatch(sql, /update crm\.tenant_memberships[\s\S]*set role = 'manager'/)
})

test('histórico continua legível para membro e mascara somente campos financeiros', () => {
  assert.match(sql, /where gated\.client_id in \(select client_id from private\.my_client_ids\(\)\)/)
  assert.match(sql, /case when co\.tenant_id in \(select client_id from private\.financial_client_ids\(\)\) then co\.value else null::numeric end/)
  assert.match(sql, /case when co\.tenant_id in \(select client_id from private\.financial_client_ids\(\)\) then co\.value_status else null::text end/)
  assert.match(sql, /case when co\.tenant_id in \(select client_id from private\.financial_client_ids\(\)\) then co\.currency else null::text end/)
  assert.match(sql, /case when m\.kind = 'revenue'[\s\S]*then null::text else m\.evidence end/)
})
