import assert from 'node:assert/strict'
import test from 'node:test'

import { tabsVisiveisParaPapel } from './role-visibility.ts'

const todas = ['overview', 'crm', 'funnel', 'channels', 'meta', 'google', 'leads', 'events', 'diario']

test('atendente não vê o CRM enquanto a flag por cliente não existir', () => {
  assert.deepEqual(tabsVisiveisParaPapel('attendant', todas), ['funnel', 'channels'])
})

test('gestão da clínica e viewer legado veem tudo menos o CRM', () => {
  for (const role of ['owner', 'admin', 'manager', 'viewer']) {
    assert.deepEqual(tabsVisiveisParaPapel(role, todas), todas.filter((tab) => tab !== 'crm'))
  }
})

test('agência vê todas as abas', () => {
  assert.deepEqual(tabsVisiveisParaPapel('agency', todas), todas)
})

test('papel ausente ou desconhecido falha fechado', () => {
  assert.deepEqual(tabsVisiveisParaPapel(null, todas), [])
  assert.deepEqual(tabsVisiveisParaPapel('unexpected', todas), [])
})
