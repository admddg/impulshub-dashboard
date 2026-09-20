import assert from 'node:assert/strict'
import test from 'node:test'

import { parseValorMonetarioBR, valorMonetarioRpcEhValido } from './crm-money.ts'

const validos = [
  ['', null],
  ['   ', null],
  ['1234', 1234],
  ['1234,56', 1234.56],
  ['1.234,56', 1234.56],
]

for (const [entrada, esperado] of validos) {
  test(`aceita valor pt-BR ${JSON.stringify(entrada)}`, () => {
    assert.deepEqual(parseValorMonetarioBR(entrada), { ok: true, valor: esperado })
  })
}

const invalidos = [
  '1234.56', '1.2.3', 'abc', 'Infinity', 'NaN', '0', '0,00', '-1', '-1,50',
  '9007199254740993',
  '90.071.992.547.409,91',
  '70.368.744.177.664,01',
]

for (const entrada of invalidos) {
  test(`rejeita valor inválido ${JSON.stringify(entrada)}`, () => {
    const resultado = parseValorMonetarioBR(entrada)
    assert.equal(resultado.ok, false)
    if (!resultado.ok) assert.match(resultado.mensagem, /valor/i)
  })
}

test('a fronteira RPC aceita somente null ou valores em centavos exatos', () => {
  assert.equal(valorMonetarioRpcEhValido(null), true)
  assert.equal(valorMonetarioRpcEhValido(1234.56), true)
  assert.equal(valorMonetarioRpcEhValido(0.29), true)
  assert.equal(valorMonetarioRpcEhValido(999999999999.99), true)

  assert.equal(valorMonetarioRpcEhValido(0), false)
  assert.equal(valorMonetarioRpcEhValido(-1), false)
  assert.equal(valorMonetarioRpcEhValido(Number.NaN), false)
  assert.equal(valorMonetarioRpcEhValido(Number.POSITIVE_INFINITY), false)
  assert.equal(valorMonetarioRpcEhValido(0.001), false)
  assert.equal(valorMonetarioRpcEhValido(1.001), false)
  assert.equal(valorMonetarioRpcEhValido(1.005), false)
  assert.equal(valorMonetarioRpcEhValido(1234.567), false)
  assert.equal(valorMonetarioRpcEhValido(999999999999.99 + 0.01), false)
  assert.equal(valorMonetarioRpcEhValido(90071992547409.9), false)
})
