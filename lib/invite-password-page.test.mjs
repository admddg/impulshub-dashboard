import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'

const pagePath = new URL('../app/definir-senha/page.tsx', import.meta.url)

async function pageSource() {
  return readFile(pagePath, 'utf8')
}

test('protects the password setup page with an authenticated session check', async () => {
  const source = await pageSource()

  assert.match(source, /supabase\.auth\.getSession\(\)/)
  assert.match(source, /!session\s*\)/)
  assert.match(source, /router\.replace\(['"]\/login['"]\)/)
})

test('updates the authenticated user password without logging credentials', async () => {
  const source = await pageSource()

  assert.match(source, /supabase\.auth\.updateUser\(\{\s*password\s*\}\)/)
  assert.doesNotMatch(source, /console\.(log|info|debug|error|warn)\s*\(/)
})

test('validates password confirmation locally and navigates after success', async () => {
  const source = await pageSource()

  assert.match(source, /password\.length\s*<\s*MIN_PASSWORD_LENGTH/)
  assert.match(source, /password\s*!==\s*confirmation/)
  assert.match(source, /router\.replace\(['"]\/dashboard['"]\)/)
})
