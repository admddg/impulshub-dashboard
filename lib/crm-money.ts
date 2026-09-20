export type ValorMonetarioBR =
  | { ok: true; valor: number | null }
  | { ok: false; mensagem: string }

const FORMATO_MONETARIO_BR = /^(?:\d+|[1-9]\d{0,2}(?:\.\d{3})+)(?:,\d{1,2})?$/
const MAX_CENTAVOS_EXATOS = 99_999_999_999_999
const MAX_VALOR_EXATO = MAX_CENTAVOS_EXATOS / 100

export function valorMonetarioRpcEhValido(valor: number | null): boolean {
  if (valor === null) return true
  if (!Number.isFinite(valor) || valor <= 0 || valor > MAX_VALOR_EXATO) return false

  const centavos = valor * 100
  const centavosInteiros = Math.round(centavos)
  const toleranciaBinaria = Number.EPSILON * Math.max(1, Math.abs(centavos))

  return Math.abs(centavos - centavosInteiros) <= toleranciaBinaria
}

/**
 * Interpreta somente valores monetários no formato brasileiro.
 * Campo vazio representa valor ainda pendente; ponto nunca é separador decimal.
 */
export function parseValorMonetarioBR(entrada: string): ValorMonetarioBR {
  const texto = entrada.trim()

  if (texto === '') return { ok: true, valor: null }

  if (!FORMATO_MONETARIO_BR.test(texto)) {
    return {
      ok: false,
      mensagem: 'Informe um valor válido, como 1234,56 ou 1.234,56.',
    }
  }

  const [inteiros, decimais = ''] = texto.replace(/\./g, '').split(',')
  const centavos = Number(inteiros + decimais.padEnd(2, '0'))
  if (!Number.isSafeInteger(centavos) || centavos <= 0 || centavos > MAX_CENTAVOS_EXATOS) {
    return {
      ok: false,
      mensagem: 'O valor deve ser maior que zero, ter no máximo duas casas decimais e ficar na faixa suportada.',
    }
  }

  return { ok: true, valor: centavos / 100 }
}
