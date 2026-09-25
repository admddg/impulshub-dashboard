import assert from 'node:assert/strict'
import test from 'node:test'

import { creativeImageStatusLabel, diagnoseCreativeUrl } from './creative-image.ts'

test('separa URL ausente de URL válida', () => {
  assert.equal(diagnoseCreativeUrl(null, 1_700_000_000), 'missing')
  assert.equal(diagnoseCreativeUrl('https://example.test/creative.jpg', 1_700_000_000), 'available')
})

test('detecta expiração de URL assinada Meta sem editar a URL', () => {
  const url = 'https://scontent.xx.fbcdn.net/v/t1.1234/creative.jpg?stp=dst-jpg_s600x600&oe=6553F100&oh=redacted'
  assert.equal(diagnoseCreativeUrl(url, 1_700_000_000), 'expired')
})

test('não presume expiração quando a URL Meta não traz expiração válida', () => {
  const url = 'https://scontent.xx.fbcdn.net/v/t1.1234/creative.jpg?oh=redacted'
  assert.equal(diagnoseCreativeUrl(url, 1_700_000_000), 'available')
  assert.equal(diagnoseCreativeUrl('not-a-url', 1_700_000_000), 'inaccessible')
})

test('rótulos expõem a causa conhecida sem mascarar erro de carregamento', () => {
  assert.equal(creativeImageStatusLabel('missing'), 'URL ausente')
  assert.equal(creativeImageStatusLabel('expired'), 'URL expirada')
  assert.equal(creativeImageStatusLabel('inaccessible'), 'URL expirada/inacessível')
})