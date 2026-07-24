'use client'

import { supabase } from '@/lib/supabase'
import { getRanges, type Period, type CustomRange } from '@/lib/utils'

// O PostgREST corta a resposta em ~1.000 linhas sem devolver erro. O sintoma é
// número errado, silenciosamente. Este arquivo é a única porta de entrada de
// linha crua no app, então a proteção mora aqui: paginamos explicitamente e
// conferimos o total contra o count do servidor.
const TAMANHO_PAGINA = 1000

// Teto de segurança. Se uma view estourar isso, o certo é agregar no banco,
// não puxar mais página. O log avisa para tratarmos na origem.
const MAXIMO_DE_LINHAS = 50000

// Busca linhas de uma view no intervalo do período atual + anterior,
// FILTRANDO pelo cliente da URL (clientId). Com multi-cliente, a RLS deixa
// passar todos os clientes permitidos, então o filtro explícito é o que isola.
export async function fetchWindowed(
  view: string,
  columns: string,
  period: Period,
  clientId: string,
  dateCol: string = 'date',
  custom?: CustomRange
) {
  const { current, previous } = getRanges(period, custom)
  const rows: any[] = []
  let inicio = 0
  let totalNoServidor: number | null = null

  for (;;) {
    const { data, error, count } = await supabase
      .from(view)
      .select(columns, { count: 'exact' })
      .eq('client_id', clientId)
      .gte(dateCol, previous.start)
      .lte(dateCol, current.end)
      // Ordem estável é obrigatória: sem ela o .range() pode repetir ou pular
      // linhas entre páginas.
      .order(dateCol, { ascending: true })
      .range(inicio, inicio + TAMANHO_PAGINA - 1)

    if (error) {
      console.error(`[Impuls] ${view}: ${error.message}`)
      return { rows: [] as any[], current, previous, error, total: null as number | null }
    }

    if (count !== null && count !== undefined) totalNoServidor = count
    const pagina = data ?? []
    rows.push(...pagina)

    if (pagina.length < TAMANHO_PAGINA) break

    inicio += TAMANHO_PAGINA
    if (rows.length >= MAXIMO_DE_LINHAS) {
      console.error(
        `[Impuls] ${view}: passou de ${MAXIMO_DE_LINHAS} linhas no período. ` +
        `Esta fonte precisa ser agregada no banco, não paginada no navegador.`
      )
      break
    }
  }

  // Rede de proteção: se o que chegou não bate com o que o servidor diz existir,
  // o número na tela está errado. Melhor gritar no console do que exibir calado.
  if (totalNoServidor !== null && rows.length !== totalNoServidor) {
    console.error(
      `[Impuls] ${view}: recebi ${rows.length} linhas de ${totalNoServidor} existentes. ` +
      `O número exibido está incompleto.`
    )
  }

  return { rows, current, previous, error: null, total: totalNoServidor }
}

// Separa linhas em atual/anterior por coluna de data.
export function splitByDate(rows: any[], current: any, previous: any, dateCol = 'date') {
  const cur = rows.filter((r) => r[dateCol] >= current.start && r[dateCol] <= current.end)
  const prev = rows.filter((r) => r[dateCol] >= previous.start && r[dateCol] <= previous.end)
  return { cur, prev }
}
