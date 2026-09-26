import assert from 'node:assert/strict'
import test from 'node:test'

import { tabsVisiveisParaPapel } from './role-visibility.ts'

const todas = ['overview', 'crm', 'funnel', 'channels', 'meta', 'google', 'leads', 'events', 'diario']

test('gestão e atendimento de cliente novo veem o CRM', () => {
  assert.deepEqual(tabsVisiveisParaPapel('manager', todas), todas)
  assert.deepEqual(tabsVisiveisParaPapel('attendant', todas), ['crm', 'funnel', 'channels'])
})

test('viewer legado continua sem CRM', () => {
  assert.deepEqual(tabsVisiveisParaPapel('viewer', todas), todas.filter((tab) => tab !== 'crm'))
})

test('agência vê todas as abas', () => {
  assert.deepEqual(tabsVisiveisParaPapel('agency', todas), todas)
})

test('papel ausente ou desconhecido falha fechado', () => {
  assert.deepEqual(tabsVisiveisParaPapel(null, todas), [])
  assert.deepEqual(tabsVisiveisParaPapel('unexpected', todas), [])
})
