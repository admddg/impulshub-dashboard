'use client'

import { brl, int } from '@/lib/utils'

// NULL ≠ zero. Em todo o painel, valor indisponível é traço simples.
export const TRACO = '—'

// Dinheiro. Quando o banco marca a fonte como incompleta, também vira traço:
// exibir um total que sabidamente falta pedaço é pior do que não exibir.
export function dinheiro(v: number | null | undefined, completo?: boolean | null) {
  if (v === null || v === undefined) return TRACO
  if (completo === false) return TRACO
  return `R$ ${brl(v)}`
}

export function dinheiroPreciso(v: number | null | undefined) {
  if (v === null || v === undefined) return TRACO
  return `R$ ${brl(v, 2)}`
}

export function numero(v: number | null | undefined) {
  if (v === null || v === undefined) return TRACO
  return int(v)
}

export function multiplicador(v: number | null | undefined, completo?: boolean | null) {
  if (v === null || v === undefined) return TRACO
  if (completo === false) return TRACO
  return v.toLocaleString('pt-BR', { minimumFractionDigits: 1, maximumFractionDigits: 2 }) + 'x'
}

// ROAS no card grande: quando null por receita incompleta, o banco pediu o
// rótulo "Receita pendente" em vez do traço seco — comunica o motivo sem
// inventar número.
export function roasCard(v: number | null | undefined) {
  if (v === null || v === undefined) return null // sinaliza "pendente" para a UI
  return v.toLocaleString('pt-BR', { minimumFractionDigits: 1, maximumFractionDigits: 2 }) + 'x'
}

export function quando(iso: string | null | undefined) {
  if (!iso) return TRACO
  const d = new Date(iso)
  if (isNaN(d.getTime())) return TRACO
  return d.toLocaleString('pt-BR', {
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
    timeZone: 'America/Sao_Paulo',
  })
}

export function duracao(ms: number | null | undefined) {
  if (ms === null || ms === undefined) return TRACO
  if (ms < 1000) return `${ms}ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`
  const m = Math.floor(ms / 60000)
  const s = Math.round((ms % 60000) / 1000)
  return `${m}m ${s}s`
}

export const ROTULO_SAUDE: Record<string, string> = {
  ok: 'OK', info: 'Ignorado', pending: 'Em andamento', warning: 'Atenção', error: 'Erro',
}
