import fs from 'node:fs'
import path from 'node:path'

const root = process.cwd()
const runbookPath = path.join(root, 'docs', 'RUNBOOK-IMP-219-ATIVACAO-CANARIO.md')
const taskPath = path.join(root, 'docs', 'task-files', 'TASK-IMP-219.md')
const runbook = fs.readFileSync(runbookPath, 'utf8')
const task = fs.readFileSync(taskPath, 'utf8')

const errors = []
const requireText = (text, label, source = runbook) => {
  if (!source.includes(text)) errors.push(`${label}: missing ${JSON.stringify(text)}`)
}
const requirePattern = (pattern, label, source = runbook) => {
  if (!pattern.test(source)) errors.push(`${label}: pattern ${pattern} did not match`)
}

requireText("'other'", 'valid workflow category')
if (/workflow_category\s*,[\s\S]{0,200}\n\s*['"]ops['"]\s*,/i.test(runbook)) {
  errors.push('invalid workflow category ops is still present')
}
requirePattern(/update\s+public\.clients_base[\s\S]*?where[\s\S]*?crm_emits_conversions\s*=\s*false[\s\S]*?returning[\s\S]*?into\s+strict/i, 'fail-closed activation update')
requirePattern(/into\s+strict\s+v_returned/i, 'returned row capture')
requirePattern(/select[\s\S]*?into\s+strict\s+v_readback[\s\S]*?crm_emits_conversions\s*=\s*true/i, 'activation readback')
requirePattern(/select[\s\S]*?into\s+strict\s+v_readback[\s\S]*?crm_emits_conversions\s*=\s*false/i, 'abort readback')
requirePattern(/rollback/i, 'rollback instruction')
requirePattern(/v_readback\.id[\s\S]*?insert into public\.workflow_execution_logs/i, 'audit identity from readback')
const updatePosition = runbook.search(/update public\.clients_base/i)
const auditPosition = runbook.search(/insert into public\.workflow_execution_logs/i)
if (updatePosition < 0 || auditPosition < 0 || auditPosition < updatePosition) {
  errors.push('success audit must occur after activation update')
}
for (const required of [
  'begin read only',
  'source_system = \'ghl\'',
  'replay_decision',
  'conversion_outbox',
  'events_normalized',
  'platform',
  'status',
  'sent_at',
  'external_job_id',
  'external_request_id',
  'response',
  'event_code × platform',
  "'lead'",
  "'agendado'",
  "'ganho'",
  "'meta'",
  "'google_ads'",
]) requireText(required, `runbook contract ${required}`)
requirePattern(/exact_outbox_match\s*=\s*true/i, 'numeric exact outbox criterion')
requirePattern(/failed_rows\s*=\s*0/i, 'numeric failed criterion')
requireText('npm run validate:imp219', 'task validation command', task)
requireText('INTO STRICT', 'task strict cardinality', task)

if (errors.length) {
  console.error(errors.join('\n'))
  process.exit(1)
}
console.log('IMP-219 static validation: PASS')
