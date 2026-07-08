'use client'

import { supabase } from '@/lib/supabase'
import { getRanges, type Period, type CustomRange } from '@/lib/utils'

// Busca linhas de uma view no intervalo do período atual + anterior.
// Usado pelas views que têm coluna de data (funil, canais, meta/google diário).
export async function fetchWindowed(
  view: string,
  columns: string,
  period: Period,
  dateCol: string = 'date',
  custom?: CustomRange
) {
  const { current, previous } = getRanges(period, custom)
  const { data, error } = await supabase
    .from(view)
    .select(columns)
    .gte(dateCol, previous.start)
    .lte(dateCol, current.end)

  if (error) {
    console.error(`Erro em ${view}:`, error.message)
    return { rows: [] as any[], current, previous, error }
  }
  return { rows: (data ?? []) as any[], current, previous, error: null }
}

// Busca linhas de uma view SEM coluna de data (campanha/criativo já agregados).
// Traz tudo (a RLS filtra por cliente).
export async function fetchAll(view: string, columns: string) {
  const { data, error } = await supabase.from(view).select(columns)
  if (error) {
    console.error(`Erro em ${view}:`, error.message)
    return { rows: [] as any[], error }
  }
  return { rows: (data ?? []) as any[], error: null }
}

// Separa linhas em atual/anterior por coluna de data.
export function splitByDate(rows: any[], current: any, previous: any, dateCol = 'date') {
  const cur = rows.filter((r) => r[dateCol] >= current.start && r[dateCol] <= current.end)
  const prev = rows.filter((r) => r[dateCol] >= previous.start && r[dateCol] <= previous.end)
  return { cur, prev }
}
