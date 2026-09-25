import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const sql = fs.readFileSync(new URL('../supabase/migrations/20261005000000_internal_onboarding.sql', import.meta.url), 'utf8')

test('internal onboarding migration is agency-only and secret-free', () => {
  assert.match(sql, /security definer/)
  assert.match(sql, /cu\.role = 'agency'/)
  assert.match(sql, /grant execute on function public\.create_internal_onboarding[\s\S]*to authenticated/)
  assert.doesNotMatch(sql, /password|refresh_token|access_token|api_secret/i)
  assert.match(sql, /profile in \('gestao', 'atendimento'\)/)
  assert.match(sql, /pending_auth/)
  assert.match(sql, /internal_onboarding_audit/)
  assert.match(sql, /actor_id uuid not null references auth\.users/)
  assert.match(sql, /jsonb_array_length\(p_users\) > 50/)
})

test('invite function keeps the admin key server-side', () => {
  const fn = fs.readFileSync(new URL('../supabase/functions/invite-internal-onboarding/index.ts', import.meta.url), 'utf8')
  assert.match(fn, /SUPABASE_SERVICE_ROLE_KEY/)
  assert.doesNotMatch(fn, /NEXT_PUBLIC_SUPABASE_SERVICE_ROLE_KEY/)
  assert.match(fn, /auth\.admin\.inviteUserByEmail/)
})
