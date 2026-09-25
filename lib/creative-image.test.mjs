import assert from 'node:assert/strict'
import test from 'node:test'

import {
  creativeImageStatusLabel,
  diagnoseCreativeUrl,
  creativeImageSourcesKey,
  initialCreativeImageState,
  nextCreativeImageState,
} from './creative-image.ts'

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

test('continua após duas fontes inválidas até encontrar a terceira válida', () => {
  const expired = 'https://scontent.xx.fbcdn.net/expired.jpg?oe=6553F100&oh=redacted'
  const sources = [expired, 'not-a-url', 'https://example.test/valid.jpg']

  assert.deepEqual(nextCreativeImageState(sources, 0, 1_700_000_000), {
    index: 2,
    status: 'available',
  })
})

test('reinicia índice e status quando a lista vazia é preenchida', () => {
  assert.deepEqual(initialCreativeImageState([], 1_700_000_000), {
    index: 0,
    status: 'missing',
  })
  assert.deepEqual(initialCreativeImageState(['https://example.test/valid.jpg'], 1_700_000_000), {
    index: 0,
    status: 'available',
  })
})

test('troca de fontes produz uma identidade nova mesmo mantendo a posição', () => {
  assert.notEqual(
    creativeImageSourcesKey(['https://example.test/old.jpg'], 'client-a:month'),
    creativeImageSourcesKey(['https://example.test/new.jpg'], 'client-a:month'),
  )
  assert.notEqual(
    creativeImageSourcesKey(['https://example.test/same.jpg'], 'client-a:month'),
    creativeImageSourcesKey(['https://example.test/same.jpg'], 'client-b:month'),
  )
  assert.deepEqual(initialCreativeImageState(['https://example.test/new.jpg'], 1_700_000_000), {
    index: 0,
    status: 'available',
  })
})
