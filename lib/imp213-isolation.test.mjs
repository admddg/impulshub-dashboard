import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import test from 'node:test'

const migrationsDir = new URL('../supabase/migrations/', import.meta.url)
const migrationFiles = readdirSync(migrationsDir)
  .filter((name) => /^20260928000001_.*\.sql$/.test(name) && !name.endsWith('.rollback.sql'))
  .map((name) => ({ name, sql: readFileSync(new URL(name, migrationsDir), 'utf8').toLowerCase() }))

const isolationSql = readFileSync(
  new URL('../supabase/acceptance/imp213-isolation.sql', import.meta.url),
  'utf8',
).toLowerCase()

const scalarFunctions = ['my_client_ids']
const withoutSqlComments = (text) => text
  .replace(/--[^\n\r]*/g, '')
  .replace(/\/\*[\s\S]*?\*\//g, '')

for (const { name, sql } of migrationFiles) {
  test(`${name} não trata SETOF uuid como registro nomeado`, () => {
    for (const fn of scalarFunctions) {
      const unaliasedSelect = new RegExp(
        `select\\s+client_id\\s+from\\s+private\\.${fn}\\s*\\(\\s*\\)`,
        'i',
      )
      const outerComparison = new RegExp(
        `\\b\\w+\\.client_id\\s*(?:=|in)\\s*\\(\\s*select\\s+client_id\\s+from\\s+private\\.${fn}\\s*\\(\\s*\\)`,
        'i',
      )
      assert.doesNotMatch(withoutSqlComments(sql), unaliasedSelect, `${name}: select escalar sem alias`)
      assert.doesNotMatch(withoutSqlComments(sql), outerComparison, `${name}: comparação externa correlacionada`)
    }
  })
}

test('aceite de isolamento cobre o card history e as 24 views financeiras', () => {
  const viewNames = [...isolationSql.matchAll(/'v_[a-z0-9_]+'/g)].map(([value]) => value.slice(1, -1))
  assert.equal(new Set(viewNames).size, 25)
  assert.match(isolationSql, /imp213_isolation/)
  assert.match(isolationSql, /select distinct client_id/)
  assert.match(isolationSql, /old filter was intentionally not executed/)
  assert.match(isolationSql, /select client_id from private\.my_client_ids\(\)/)
})

test('rollback documenta que a definição anterior vazava', () => {
  const rollback = readFileSync(
    new URL('../supabase/migrations/20260928000001_imp213_hotfix_card_history_tenant_filter.rollback.sql', import.meta.url),
    'utf8',
  ).toLowerCase()
  assert.match(rollback, /vazava/)
  assert.match(rollback, /nao reaplique/)
  assert.match(rollback, /select client_id from private\.my_client_ids\(\)/)
})
