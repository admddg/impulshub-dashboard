import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const migration = readFileSync(new URL('../supabase/migrations/20261006000000_onboarding_crm_sync.sql', import.meta.url), 'utf8').toLowerCase()
const rollback = readFileSync(new URL('../supabase/migrations/20261006000000_onboarding_crm_sync.rollback.sql', import.meta.url), 'utf8').toLowerCase()

test('migration backfills and synchronizes onboarding entities idempotently', () => {
  assert.match(migration, /insert into crm\.tenants[\s\S]*on conflict \(id\) do update/)
  assert.match(migration, /insert into crm\.profiles[\s\S]*from auth\.users[\s\S]*on conflict \(id\) do update/)
  assert.match(migration, /insert into crm\.tenant_memberships[\s\S]*on conflict \(tenant_id, profile_id\) do update/)
  assert.match(migration, /create trigger crm_sync_tenant_after_client_insert/)
  assert.match(migration, /create trigger crm_sync_profile_after_auth_insert/)
  assert.match(migration, /create trigger crm_sync_membership_after_client_user_change/)
  assert.match(migration, /when 'viewer' then 'viewer'/)
  assert.match(migration, /lower\(cu\.role\) <> 'viewer'/)
})

test('migration preserves product role authority and maps onboarding roles', () => {
  assert.match(migration, /when 'agency' then 'admin'/)
  assert.match(migration, /when 'attendant' then 'attendant'/)
  assert.match(migration, /when 'manager' then 'manager'/)
  assert.doesNotMatch(migration, /update public\.client_users[\s\S]*set role/)
  assert.doesNotMatch(migration, /update crm\.tenant_memberships[\s\S]*set role = 'manager'/)
})

test('rollback removes only automation and explicitly documents retained backfill', () => {
  assert.match(rollback, /drop trigger if exists crm_sync_tenant_after_client_insert/)
  assert.match(rollback, /drop trigger if exists crm_sync_profile_after_auth_insert/)
  assert.match(rollback, /drop trigger if exists crm_sync_membership_after_client_user_change/)
  assert.match(rollback, /drop function if exists crm\.sync_tenant_from_client\(\)/)
  assert.match(rollback, /crm\.tenant_memberships backfill rows/)
  assert.doesNotMatch(rollback, /delete from crm\./)
})
