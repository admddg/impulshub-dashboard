import test from 'node:test'
import assert from 'node:assert/strict'
import { EMPTY_ONBOARDING_FORM, onboardingPayload, validateOnboarding } from './onboarding.ts'

test('onboarding requires one user of each operational profile', () => {
  const form = { ...EMPTY_ONBOARDING_FORM, users: [{ name: 'Ana', email: 'ana@example.com', role: 'gestao' }] }
  assert.ok(validateOnboarding(form).some((error) => error.includes('Atendimento')))
})

test('onboarding accepts complete legal intake and preserves no secrets', () => {
  const form = {
    ...EMPTY_ONBOARDING_FORM,
    clientName: 'Clínica Nova', slug: 'clinica-nova', legalName: 'Clínica Nova LTDA', cnpj: '00.000.000/0001-00',
    legalEmail: 'financeiro@clinica-nova.com', addressLine: 'Rua A', addressNumber: '10', neighborhood: 'Centro',
    city: 'São Paulo', state: 'sp', postalCode: '01000-000',
    users: [{ name: 'Ana', email: 'ana@example.com', role: 'gestao' }, { name: 'Bia', email: 'bia@example.com', role: 'atendimento' }],
  }
  assert.deepEqual(validateOnboarding(form), [])
  const payload = onboardingPayload(form)
  assert.equal(payload.p_state, 'SP')
  assert.equal('password' in payload, false)
  assert.equal('token' in payload, false)
})
