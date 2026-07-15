'use client'

import { useEffect, useState } from 'react'
import { fetchWindowed, splitByDate } from '@/lib/data'
import { num, int, brl, type Period, type CustomRange } from '@/lib/utils'
import DataTable, { type Column } from '@/components/DataTable'
import { LineTimeChart } from '@/components/Charts'
import DailyPulseNote from '@/components/DailyPulseNote'

type DayRow = {
  date: string
  leads: number; conversas: number; agendados: number; ganhos: number; perdidos: number
  receita: number; investido: number
}

function dm(iso: string) { const p = iso.split('-'); return `${p[2]}/${p[1]}` }
function fmtDataLonga(iso: string) {
  const [y, m, d] = iso.split('-')
  return new Date(Number(y), Number(m) - 1, Number(d)).toLocaleDateString('pt-BR', { day: '2-digit', month: 'short', weekday: 'short' })
}

export default function DiarioTab({ clientId, period, custom }: { clientId: string; period: Period; custom: CustomRange | null }) {
  const [loading, setLoading] = useState(true)
  const [rows, setRows] = useState<DayRow[]>([])
  const [timeline, setTimeline] = useState<any[]>([])

  useEffect(() => {
    let alive = true
    setLoading(true)

    Promise.all([
      // eventos já agregados por dia NO BANCO — sem coorte, sem risco de
      // estourar limite de linhas (era o bug: buscar evento a evento e
      // agregar no navegador truncava silenciosamente em clientes com
      // volume alto)
      fetchWindowed('v_client_daily_pulse', 'date, leads, conversas, agendados, ganhos, perdidos, receita', period, clientId, 'date', custom ?? undefined),
      // investimento por dia (spend não é afetado pela coorte — é o gasto real do dia)
      fetchWindowed('v_meta_account_daily', 'date, spend', period, clientId, 'date', custom ?? undefined),
      fetchWindowed('v_google_campaign_daily', 'date, spend', period, clientId, 'date', custom ?? undefined),
    ]).then(([ev, meta, google]) => {
      if (!alive) return

      const evCur = splitByDate(ev.rows, ev.current, ev.previous).cur
      const metaCur = splitByDate(meta.rows, meta.current, meta.previous).cur
      const googleCur = splitByDate(google.rows, google.current, google.previous).cur

      const map = new Map<string, DayRow>()
      const ensure = (date: string) => {
        let r = map.get(date)
        if (!r) { r = { date, leads: 0, conversas: 0, agendados: 0, ganhos: 0, perdidos: 0, receita: 0, investido: 0 }; map.set(date, r) }
        return r
      }

      for (const e of evCur) {
        const r = ensure(e.date)
        r.leads += num(e.leads); r.conversas += num(e.conversas); r.agendados += num(e.agendados)
        r.ganhos += num(e.ganhos); r.perdidos += num(e.perdidos); r.receita += num(e.receita)
      }
      for (const m of metaCur) ensure(m.date).investido += num(m.spend)
      for (const g of googleCur) ensure(g.date).investido += num(g.spend)

      const ordered = [...map.values()].sort((a, b) => b.date.localeCompare(a.date))
      setRows(ordered)
      setTimeline(
        [...map.values()]
          .sort((a, b) => a.date.localeCompare(b.date))
          .map((r) => ({ label: dm(r.date), Leads: r.leads, Agendados: r.agendados }))
      )
      setLoading(false)
    })

    return () => { alive = false }
  }, [clientId, period, custom])

  const cols: Column<DayRow>[] = [
    { key: 'date', header: 'Dia', render: (r) => <span className="cell-strong">{fmtDataLonga(r.date)}</span>, sortValue: (r) => r.date, width: 130 },
    { key: 'leads', header: 'Leads', align: 'right', render: (r) => int(r.leads), sortValue: (r) => r.leads },
    { key: 'conversas', header: '1ª conversa', align: 'right', render: (r) => int(r.conversas), sortValue: (r) => r.conversas },
    { key: 'agendados', header: 'Agendados', align: 'right', render: (r) => int(r.agendados), sortValue: (r) => r.agendados },
    { key: 'ganhos', header: 'Ganhos', align: 'right', render: (r) => int(r.ganhos), sortValue: (r) => r.ganhos },
    { key: 'perdidos', header: 'Perdidos', align: 'right', render: (r) => int(r.perdidos), sortValue: (r) => r.perdidos },
    { key: 'receita', header: 'Receita', align: 'right', render: (r) => r.receita > 0 ? `R$ ${brl(r.receita)}` : <span className="cell-muted">—</span>, sortValue: (r) => r.receita },
    { key: 'investido', header: 'Investido', align: 'right', render: (r) => r.investido > 0 ? `R$ ${brl(r.investido)}` : <span className="cell-muted">—</span>, sortValue: (r) => r.investido },
    { key: 'cpl', header: 'CPL', align: 'right', render: (r) => r.leads > 0 && r.investido > 0 ? `R$ ${brl(r.investido / r.leads, 2)}` : <span className="cell-muted">—</span>, sortValue: (r) => r.leads > 0 ? r.investido / r.leads : 0 },
    { key: 'cpag', header: 'CPag', align: 'right', render: (r) => r.agendados > 0 && r.investido > 0 ? `R$ ${brl(r.investido / r.agendados, 2)}` : <span className="cell-muted">—</span>, sortValue: (r) => r.agendados > 0 ? r.investido / r.agendados : 0 },
  ]

  if (loading) return <div className="state"><div className="spinner" />Carregando dados diários…</div>

  return (
    <>
      <DailyPulseNote />
      <div className="block">
        <div className="block-head">
          <span className="block-title">Leads e agendamentos por dia</span>
          <span className="block-sub">Pulso diário — sem coorte</span>
        </div>
        <LineTimeChart
          data={timeline}
          series={[
            { key: 'Leads', name: 'Leads', color: '#00313d' },
            { key: 'Agendados', name: 'Agendados', color: '#5fae95' },
          ]}
        />
      </div>

      <DataTable columns={cols} rows={rows} initialSort={{ key: 'date', dir: 'desc' }} />
    </>
  )
}
