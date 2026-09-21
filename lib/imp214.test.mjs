import assert from 'node:assert/strict'
import test from 'node:test'

import { origemDoCard, temFiltro } from './imp214-rules.ts'

const FILTROS_VAZIOS = { de: '', ate: '', ownerRole: '', owner: '', origem: '' }

test('classifica card como anúncio quando qualquer identificador de anúncio existe', () => {
  assert.equal(origemDoCard({ conversion_source: null, ctwa_clid: null, meta_ad_id: 'ad-1' }), 'anuncio')
  assert.equal(origemDoCard({ conversion_source: 'meta', ctwa_clid: null, meta_ad_id: null }), 'anuncio')
  assert.equal(origemDoCard({ conversion_source: null, ctwa_clid: 'clid', meta_ad_id: null }), 'anuncio')
})

test('classifica card sem identificadores como orgânico', () => {
  assert.equal(origemDoCard({ conversion_source: null, ctwa_clid: null, meta_ad_id: null }), 'organico')
})

test('filtro vazio não ativa recorte e origem/dono ativam', () => {
  assert.equal(temFiltro(FILTROS_VAZIOS), false)
  assert.equal(temFiltro({ ...FILTROS_VAZIOS, origem: 'organico' }), true)
  assert.equal(temFiltro({ ...FILTROS_VAZIOS, ownerRole: 'sales', owner: 'none' }), true)
})
