import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import test from 'node:test'

const repoRoot = new URL('..', import.meta.url)
const sqlDirectories = ['supabase/migrations', 'supabase/acceptance']
const historicalFilesWithKnownBug = new Set([
  'supabase/migrations/20260928000000_imp213_role_visibility.sql',
  'supabase/migrations/20260928000000_imp213_role_visibility.rollback.sql',
  'supabase/acceptance/APLICAR-imp213.sql',
])
const helpersWithNamedTableColumns = new Set(['financial_client_ids'])

const unaliasedHelperSelect = /\bselect\s+client_id\s+from\s+private\.([a-z_][a-z0-9_]*)\s*\(\s*\)(?!\s+as\b)/gi

function stripSqlComments(sql) {
  return sql
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^\s*--.*$/gm, '')
}

function findUnaliasedHelperSelects(sql) {
  return [...stripSqlComments(sql).matchAll(unaliasedHelperSelect)]
    .filter((match) => !helpersWithNamedTableColumns.has(match[1].toLowerCase()))
    .map((match) => match[0])
}

function sqlFilesIn(directory) {
  return readdirSync(new URL(directory, repoRoot), { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.sql'))
    .map((entry) => join(directory, entry.name))
}

test('a varredura reproduz o bug e aceita o alias correto', () => {
  assert.deepEqual(
    findUnaliasedHelperSelects('select client_id from private.my_client_ids()'),
    ['select client_id from private.my_client_ids()'],
  )
  assert.deepEqual(findUnaliasedHelperSelects('select m from private.my_client_ids() as m'), [])
  assert.deepEqual(findUnaliasedHelperSelects('select client_id from private.financial_client_ids()'), [])
})

test('migrations e acceptances novas não usam helper setof sem alias', () => {
  const violations = []
  for (const directory of sqlDirectories) {
    for (const file of sqlFilesIn(directory)) {
      const relativeFile = relative(new URL('.', repoRoot).pathname, new URL(file, repoRoot).pathname)
        .replaceAll('\\', '/')
      if (historicalFilesWithKnownBug.has(relativeFile)) continue
      for (const match of findUnaliasedHelperSelects(readFileSync(new URL(file, repoRoot), 'utf8'))) {
        violations.push(`${relativeFile}: ${match}`)
      }
    }
  }
  assert.deepEqual(violations, [])
})
