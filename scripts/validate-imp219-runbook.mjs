import fs from 'node:fs'
import path from 'node:path'

const root = process.cwd()
const runbook = fs.readFileSync(path.join(root, 'docs', 'RUNBOOK-IMP-219-ATIVACAO-CANARIO.md'), 'utf8')
const task = fs.readFileSync(path.join(root, 'docs', 'task-files', 'TASK-IMP-219.md'), 'utf8')

const allowedCategories = new Set(['onboarding', 'events', 'dispatch', 'media_sync', 'backfill', 'other'])
const requiredCategories = [...allowedCategories]
const requiredTexts = [
  'begin read only', 'source_system = \'ghl\'', 'replay_decision',
  'conversion_outbox', 'events_normalized', 'platform', 'status', 'sent_at',
  'external_job_id', 'external_request_id', 'response', 'event_code × platform',
  "'lead'", "'primeira_conversa'", "'agendado'", "'ganho'", "'perdido'",
  "'meta'", "'google_ads'", 'MANUAL_EVIDENCE_REQUIRED',
  'ganho_contract_violations', 'valid_ganho_outbox_count_violations',
  'pending_ganho_outbox_count_violations', 'valid_ganho_platform_violations',
  'orphaned_outbox', 'ineligible_event_code', 'unsupported_platform',
  'duplicate', 'surplus', 'left join public.events_normalized',
]

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
  requirePattern(/rollback/i, 'rollback instruction')
  requireText("'replay_decision', 'ignore'")
  requireText('replay default', 'explicit replay default')
  requireText("'other', -- valor permitido", 'activation workflow category')

  for (const required of requiredTexts) requireText(required, `runbook contract ${required}`)
  requirePattern(/expected_pair[\s\S]*primeira_conversa[\s\S]*expected_outbox_rows\s*=\s*0/i, 'zero outbox ineligible expected rows')
  requirePattern(/\)\s+as exact_match/i, 'exact pair numeric assertion')
  requirePattern(/co\.created_at\s*>=\s*p\.start_at[\s\S]*co\.created_at\s*<\s*p\.end_at/i, 'whole outbox window')
  requirePattern(/value_status\s*=\s*'valid'[\s\S]*valor_ganho\s*>\s*0[\s\S]*currency\s*=\s*'BRL'/i, 'ganho value/currency executable contract')
  requireText('manual evidence missing:', 'exact manual evidence escape hatch')

  requireText('npm run validate:imp219', 'task validation command', task)
  requireText('INTO STRICT', 'task strict cardinality', task)
  return errors
}

const errors = collectErrors(runbook)

// Mutation checks prove the validator is fail-closed for the important regressions.
const mutations = [
  ['remove all left joins', (source) => source.replaceAll('left join public.events_normalized', 'join public.events_normalized')],
  ['remove replay ignore', (source) => source.replace("'replay_decision', 'ignore'", "'replay_decision', 'manual'")],
  ['remove surplus category', (source) => source.replaceAll('surplus', 'not-a-category')],
  ['add invalid workflow category', (source) => source.replace("'other', -- valor permitido", "'rogue', -- valor permitido")],
  ['break activation audit anchor', (source) => source.replace('insert into public.workflow_execution_logs', 'insert into public.workflow_execution_logs_broken')],
]
for (const [label, mutate] of mutations) {
  const mutated = mutate(runbook)
  if (mutated === runbook || collectErrors(mutated).length === 0) errors.push(`mutation check did not fail closed: ${label}`)
}

if (errors.length) {
  console.error(errors.join('\n'))
  process.exit(1)
}
console.log('IMP-219 static validation: PASS')
