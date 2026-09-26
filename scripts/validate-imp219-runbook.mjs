import fs from 'node:fs'
import path from 'node:path'

const root = process.cwd()
const runbook = fs.readFileSync(path.join(root, 'docs', 'RUNBOOK-IMP-219-ATIVACAO-CANARIO.md'), 'utf8')
const task = fs.readFileSync(path.join(root, 'docs', 'task-files', 'TASK-IMP-219.md'), 'utf8')

const allowedCategories = new Set(['onboarding', 'events', 'dispatch', 'media_sync', 'backfill', 'other'])
const requiredCategories = [...allowedCategories]

function findSection(source, heading) {
  const start = source.indexOf(heading)
  if (start < 0) return ''
  const next = source.indexOf('\n## ', start + heading.length)
  return source.slice(start, next < 0 ? source.length : next)
}

function collectErrors(source) {
  const errors = []
  const requireText = (text, label, haystack = source) => {
    if (!haystack.includes(text)) errors.push(`${label}: missing ${JSON.stringify(text)}`)
  }
  const requirePattern = (pattern, label, haystack = source) => {
    if (!pattern.test(haystack)) errors.push(`${label}: pattern ${pattern} did not match`)
  }

  for (const category of requiredCategories) requireText(`'${category}'`, `allowed workflow category ${category}`)
  const allowedSetMatch = source.match(/workflow_category allowed set:\s*([\s\S]{0,160}?)(?=\n\s*'manual-|\n\s*'IMP-219)/i)
  if (allowedSetMatch) {
    const listed = [...allowedSetMatch[1].matchAll(/'([^']+)'/g)].map((match) => match[1])
    if (listed.length !== requiredCategories.length || listed.some((category) => !allowedCategories.has(category))) {
      errors.push(`workflow category allowed set is not exactly ${[...allowedCategories].join(', ')}`)
    }
  } else {
    errors.push('workflow category allowed set declaration is missing')
  }
  const categoryLiterals = [...source.matchAll(/workflow_category\s*,\s*\n\s*'([^']+)'\s*,/gi)].map((match) => match[1])
  for (const category of categoryLiterals) {
    if (!allowedCategories.has(category)) errors.push(`invalid workflow category ${category}`)
  }
  if (/workflow_category\s*,[\s\S]{0,200}\n\s*['"]ops['"]\s*,/i.test(source)) errors.push('invalid workflow category ops is still present')

  const activation = findSection(source, '## 2. Ativação atômica')
  if (!activation) errors.push('activation section is missing')
  requirePattern(/update\s+public\.clients_base[\s\S]*?where[\s\S]*?crm_emits_conversions\s*=\s*false[\s\S]*?returning[\s\S]*?into\s+strict/i, 'fail-closed activation update', activation)
  requirePattern(/into\s+strict\s+v_returned/i, 'returned row capture', activation)
  requirePattern(/select[\s\S]*?into\s+strict\s+v_readback[\s\S]*?crm_emits_conversions\s*=\s*true/i, 'activation readback', activation)
  requirePattern(/v_readback\.id[\s\S]*?insert into public\.workflow_execution_logs\b/i, 'audit identity from readback', activation)
  const updatePosition = activation.search(/update public\.clients_base/i)
  const readbackPosition = activation.search(/into\s+strict\s+v_readback/i)
  const auditPosition = activation.search(/insert into public\.workflow_execution_logs\b/i)
  if (updatePosition < 0 || readbackPosition < updatePosition || auditPosition < readbackPosition) {
    errors.push('activation ordering must be update -> readback -> audit inside section 2')
  }
  requirePattern(/select[\s\S]*?into\s+strict\s+v_readback[\s\S]*?crm_emits_conversions\s*=\s*false/i, 'abort readback', source)
  requirePattern(/rollback/i, 'rollback instruction')
  requireText("'replay_decision', 'ignore'")
  requireText('replay default', 'explicit replay default')
  requireText("'other', -- valor permitido", 'activation workflow category')

  for (const required of [
    'begin read only', 'source_system = \'ghl\'', 'replay_decision',
    'conversion_outbox', 'events_normalized', 'platform', 'status', 'sent_at',
    'external_job_id', 'external_request_id', 'response', 'event_code × platform',
    "'lead'", "'primeira_conversa'", "'agendado'", "'ganho'", "'perdido'",
    "'meta'", "'google_ads'", 'MANUAL_EVIDENCE_REQUIRED',
    'ganho_contract_violations', 'valid_ganho_outbox_count_violations',
    'pending_ganho_outbox_count_violations', 'valid_ganho_platform_violations',
    'orphaned_outbox', 'ineligible_event_code', 'unsupported_platform',
    'unsupported_event_code', 'duplicate', 'surplus', 'left join public.events_normalized',
  ]) requireText(required, `runbook contract ${required}`)

  const reconciliation = findSection(source, '## 5. Reconciliação pós-canário')
  requirePattern(/when ow\.normalized_event_id is null then 'orphaned_outbox'/i, 'main orphan branch', reconciliation)
  requirePattern(/when ow\.event_code not in \(select event_code from allowed_events\) then 'unsupported_event_code'/i, 'main unsupported event branch', reconciliation)
  requirePattern(/when ow\.platform not in \(select platform from supported_platforms\) then 'unsupported_platform'/i, 'main unsupported platform branch', reconciliation)
  requirePattern(/when ow\.event_code in \('primeira_conversa', 'perdido'\) then 'ineligible_event_code'/i, 'main ineligible branch', reconciliation)
  requirePattern(/when ow\.duplicate_count > 1 and ow\.duplicate_number > 1 then 'duplicate'/i, 'main duplicate branch', reconciliation)
  requirePattern(/when ow\.pair_outbox_rows > ow\.pair_eligible_events then 'surplus'/i, 'main surplus branch', reconciliation)
  requirePattern(/when en\.id is null then 'orphaned_outbox'/i, 'detailed orphan branch', reconciliation)
  requirePattern(/when co\.platform not in \('meta', 'google_ads'\) then 'unsupported_platform'/i, 'detailed unsupported platform branch', reconciliation)
  requirePattern(/when en\.event_code in \('primeira_conversa', 'perdido'\) then 'ineligible_event_code'/i, 'detailed ineligible branch', reconciliation)
  requirePattern(/when count\(\*\) over \(partition by co\.normalized_event_id, co\.platform\) > 1 then 'duplicate'/i, 'detailed duplicate branch', reconciliation)
  requirePattern(/when en\.event_code not in \('lead', 'agendado', 'ganho'\) then 'unsupported_event_code'/i, 'detailed unsupported event branch', reconciliation)
  requirePattern(/when count\(\*\) over \(partition by en\.event_code, co\.platform\)[\s\S]*>\s*coalesce\(ec\.eligible_events, 0\)[\s\S]*then 'surplus'/i, 'detailed surplus branch', reconciliation)
  requirePattern(/expected_report[\s\S]*null::text as row_category[\s\S]*row_report[\s\S]*c\.row_category[\s\S]*group by c\.event_code, c\.platform, c\.row_category/i, 'row_category preserved through report union', reconciliation)
  requirePattern(/cross join params p[\s\S]*where en\.client_id = p\.client_id/i, 'detailed report target-client scope', reconciliation)
  requirePattern(/outbox_window as \([\s\S]*?en\.client_id = p\.client_id[\s\S]*?en\.source_system = 'impuls_crm'[\s\S]*?where co\.created_at/i, 'main outbox target client and CRM scope', reconciliation)
  requirePattern(/classified as \([\s\S]*?cross join params p[\s\S]*?en\.client_id = p\.client_id[\s\S]*?en\.source_system = 'impuls_crm'/i, 'detailed report target client and CRM scope', reconciliation)
  requirePattern(/actual as \([\s\S]*?en\.client_id = '<client_id>'::uuid[\s\S]*?en\.source_system = 'impuls_crm'/i, 'numeric actual target client and CRM scope', reconciliation)
  requirePattern(/expected_report[\s\S]*case when e\.eligible then e\.eligible_events else 0 end as expected_outbox_rows/i, 'ineligible zero outbox expected rows', reconciliation)
  requirePattern(/outbox_window as \([\s\S]*?where co\.created_at\s*>=\s*p\.start_at[\s\S]*?and co\.created_at\s*<\s*p\.end_at/i, 'whole outbox window', reconciliation)
  requirePattern(/value_status\s*=\s*'valid'[\s\S]*valor_ganho\s*>\s*0[\s\S]*currency\s*=\s*'BRL'/i, 'ganho value/currency executable contract')
  requireText('manual evidence missing:', 'exact manual evidence escape hatch')

  requireText('npm run validate:imp219', 'task validation command', task)
  requireText('INTO STRICT', 'task strict cardinality', task)
  return errors
}

const errors = collectErrors(runbook)
const reconciliation = findSection(runbook, '## 5. Reconciliação pós-canário')

// These are executable mutations: each removes one safety invariant and must make
// the validator fail, rather than merely checking that a token exists somewhere.
const mutations = [
  ['remove executable surplus CASE', (source) => source.replace(/\s+when ow\.pair_outbox_rows > ow\.pair_eligible_events then 'surplus'/g, '')],
  ['remove detailed surplus CASE', (source) => source.replace(/\s+when count\(\*\) over \(partition by en\.event_code, co\.platform\)[\s\S]*?then 'surplus'/, '')],
  ['remove unsupported platform branch', (source) => source.replace(/\s+when ow\.platform not in \(select platform from supported_platforms\) then 'unsupported_platform'/g, '')],
  ['remove unsupported event branch', (source) => source.replace(/\s+when ow\.event_code not in \(select event_code from allowed_events\) then 'unsupported_event_code'/g, '')],
  ['remove detailed unsupported platform branch', (source) => source.replace(/\s+when co\.platform not in \('meta', 'google_ads'\) then 'unsupported_platform'/, '')],
  ['remove duplicate logic', (source) => source.replace(/\s+when ow\.duplicate_count > 1 and ow\.duplicate_number > 1 then 'duplicate'/g, '')],
  ['remove detailed duplicate logic', (source) => source.replace(/\s+when count\(\*\) over \(partition by co\.normalized_event_id, co\.platform\) > 1 then 'duplicate'/, '')],
  ['remove ineligible zero-row logic', (source) => source.replace('case when e.eligible then e.eligible_events else 0 end as expected_outbox_rows', 'e.eligible_events as expected_outbox_rows')],
  ['remove full-window upper predicate', (source) => source.replace(/\s+and co\.created_at < p\.end_at/g, '')],
  ['remove full-window lower predicate', (source) => source.replace(/\s+(?:where|and) co\.created_at >= p\.start_at/g, '')],
  ['remove main target client predicate', (source) => source.replace(/\s+and en\.client_id = p\.client_id/g, '')],
  ['remove main CRM source predicate', (source) => source.replace(/\s+and en\.source_system = 'impuls_crm'/g, '')],
  ['remove numeric actual CRM predicate', (source) => source.replace(/\s+and en\.source_system = 'impuls_crm'/g, '')],
  ['remove ganho positive predicate', (source) => source.replace('and valor_ganho > 0', 'and valor_ganho >= 0')],
]
for (const [label, mutate] of mutations) {
  const mutated = mutate(runbook)
  if (mutated === runbook || collectErrors(mutated).length === 0) errors.push(`mutation check did not fail closed: ${label}`)
}

if (!reconciliation) errors.push('reconciliation section is missing for mutation coverage')
if (errors.length) {
  console.error(errors.join('\n'))
  process.exit(1)
}
console.log(`IMP-219 static validation: PASS (${mutations.length} mutation checks)`)
