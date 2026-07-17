'use client'

import { useEffect, useState } from 'react'
import { fetchWindowed, splitByDate } from '@/lib/data'
import { num, int, brl, type Period, type CustomRange } from '@/lib/utils'
import DataTable, { type Column } from '@/components/DataTable'
import { LineTimeChart } from '@/components/Charts'

type DayRow = {
  date: string
  leads: number; conversas: number; agendados: number; ganhos: number; perdidos: number
  vendas_fechadas: number; receita: number | null; receita_completa: boolean
  investido: number; investido_completo: boolean
}

function dm(iso: string) { const p = iso.split('-'); return `${p[2]}/${p[1]}` }
function fmtDataLonga(iso: string) {
  const [y, m, d] = iso.split('-')
  return new Date(Number(y), Number(m) - 1, Number(d)).toLocaleDateString('pt-BR', { day: '2-digit', month: 'short', weekday: 'short' })
}

const EVENT_MAP: Record<string, keyof Pick<DayRow, 'leads' | 'conversas' | 'agendados' | 'ganhos' | 'perdidos'>> = {
  lead: 'leads', primeira_conversa: 'conversas', agendado: 'agendados', ganho: 'ganhos', perdido: 'perdidos',
}

export default function DiarioTab({ clientId, period, custom }: {
  clientId: string; period: Period; custom: CustomRange | null
}) {
  const [loading, setLoading] = useState(true)
  const [rows, setRows] = useState<DayRow[]>([])
  const [timeline, setTimeline] = useState<any[]>([])

  useEffect(() => {
    let alive = true
    setLoading(true)
    Promise.all([
      fetchWindowed('v_crm_events_daily_v2', 'date, event_code, event_count', period, clientId, 'date', custom ?? undefined),
      fetchWindowed('v_client_performance_daily_v2', 'date, reported_spend, spend_is_complete, closed_sales, closed_confirmed_revenue, closed_revenue_is_complete', period, clientId, 'date', custom ?? undefined),
    ]).then(([ev, perf]) => {
      if (!alive) return
      const evCur = splitByDate(ev.rows, ev.current, ev.previous).cur
      const perfCur = splitByDate(perf.rows, perf.current, perf.previous).cur

      const map = new Map<string, DayRow>()
      const ensure = (date: string) => {
        let r = map.get(date)
        if (!r) { r = { date, leads: 0, conversas: 0, agendados: 0, ganhos: 0, perdidos: 0, vendas_fechadas: 0, receita: null, receita_completa: false, investido: 0, investido_completo: true }; map.set(date, r) }
        return r
      }
      for (const e of evCur) { const key = EVENT_MAP[e.event_code]; if (key) ensure(e.date)[key] += num(e.event_count) }
      for (const p of perfCur) {
        const r = ensure(p.date)
        r.investido = num(p.reported_spend); r.investido_completo = p.spend_is_complete !== false
        r.vendas_fechadas = num(p.closed_sales); r.receita_completa = p.closed_revenue_is_complete === true
        r.receita = r.receita_completa ? num(p.closed_confirmed_revenue) : null
      }
      const ordered = [...map.values()].sort((a, b) => b.date.localeCompare(a.date))
      setRows(ordered)
      setTimeline([...map.values()].sort((a, b) => a.date.localeCompare(b.date)).map((r) => ({ label: dm(r.date), Leads: r.leads, Agendados: r.agendados })))
      setLoading(false)
    })
    return () => { alive = false }
  }, [clientId, period, custom])

  const cols: Column<DayRow>[] = [
    { key: 'date', header: 'Dia', render: (r) => <span className="cell-strong">{fmtDataLonga(r.date)}</span>, sortValue: (r) => r.date, width: 130 },
    { key: 'leads', header: 'Leads', align: 'right', render: (r) => int(r.leads), sortValue: (r) => r.leads },
    { key: 'conversas', header: '1ª conversa', align: 'right', render: (r) => int(r.conversas), sortValue: (r) => r.conversas },
    { key: 'agendados', header: 'Agendados', align: 'right', render: (r) => int(r.agendados), sortValue: (r) => r.agendados },
    { key: 'ganhos', header: 'Ganhos (evento)', align: 'right', tooltip: 'Marcações de ganho recebidas no dia pelo CRM.', render: (r) => int(r.ganhos), sortValue: (r) => r.ganhos },
    { key: 'vendas', header: 'Vendas fechadas', align: 'right', tooltip: 'Oportunidades oficiais ganhas neste dia.', render: (r) => int(r.vendas_fechadas), sortValue: (r) => r.vendas_fechadas },
    { key: 'receita', header: 'Receita', align: 'right', render: (r) => r.receita !== null ? `R$ ${brl(r.receita)}` : <span className="cell-muted" title="Venda sem valor preenchido no CRM">Valor não informado</span>, sortValue: (r) => r.receita ?? -1 },
    { key: 'investido', header: 'Investido', align: 'right', render: (r) => r.investido > 0 ? `R$ ${brl(r.investido)}` : <span className="cell-muted">—</span>, sortValue: (r) => r.investido },
    { key: 'cpl', header: 'CPL', align: 'right', render: (r) => r.leads > 0 && r.investido > 0 ? `R$ ${brl(r.investido / r.leads, 2)}` : <span className="cell-muted">—</span>, sortValue: (r) => r.leads > 0 ? r.investido / r.leads : 0 },
    { key: 'cpag', header: 'CPag', align: 'right', render: (r) => r.agendados > 0 && r.investido > 0 ? `R$ ${brl(r.investido / r.agendados, 2)}` : <span className="cell-muted">—</span>, sortValue: (r) => r.agendados > 0 ? r.investido / r.agendados : 0 },
  ]

  if (loading) return <div className="state"><div className="spinner" />Carregando dados diários…</div>

  return (
    <>
      <div className="muted-note" style={{ marginBottom: 16 }}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        <strong style={{ fontWeight: 600 }}>Esta aba é diferente do restante do dashboard:</strong> cada evento conta no dia em que <em>aconteceu de verdade</em>, sem coorte. É uma visão de acompanhamento do dia a dia — não para avaliar o resultado maduro de uma campanha (use as outras abas para isso).
      </div>
      <div className="block">
        <div className="block-head"><span className="block-title">Leads e agendamentos por dia</span><span className="block-sub">Pulso diário — sem coorte</span></div>
        <LineTimeChart data={timeline} series={[{ key: 'Leads', name: 'Leads', color: '#00313d' }, { key: 'Agendados', name: 'Agendados', color: '#5fae95' }]} />
      </div>
      <DataTable columns={cols} rows={rows} initialSort={{ key: 'date', dir: 'desc' }} />
      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        "Valor não informado" não é R$ 0 — é venda sem valor preenchido no CRM. "Ganhos (evento)" e "Vendas fechadas" podem diferir: um é marcação de CRM, o outro é oportunidade oficial.
      </div>
    </>
  )
}
