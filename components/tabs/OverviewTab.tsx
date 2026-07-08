'use client'

import { useEffect, useState } from 'react'
import { fetchWindowed, splitByDate } from '@/lib/data'
import { num, brl, int, type Period, type CustomRange } from '@/lib/utils'
import KpiCard from '@/components/KpiCard'
import { LineTimeChart } from '@/components/Charts'

type Totals = { spend: number; leads: number; agendados: number; ganhos: number; receita: number }
const EMPTY: Totals = { spend: 0, leads: 0, agendados: 0, ganhos: 0, receita: 0 }

function agg(rows: any[]): Totals {
  return rows.reduce<Totals>((a, r) => ({
    spend: a.spend + num(r.spend),
    leads: a.leads + num(r.crm_leads),
    agendados: a.agendados + num(r.crm_agendados),
    ganhos: a.ganhos + num(r.crm_ganhos),
    receita: a.receita + num(r.receita),
  }), { ...EMPTY })
}

// formata 'YYYY-MM-DD' -> 'DD/MM'
function dm(iso: string) { const [, m, d] = iso.split('-'); return `${d}/${m}` }

export default function OverviewTab({ period, periodLabel, custom }: { period: Period; periodLabel: string; custom: CustomRange | null }) {
  const [loading, setLoading] = useState(true)
  const [cur, setCur] = useState<Totals>(EMPTY)
  const [prev, setPrev] = useState<Totals>(EMPTY)
  const [timeline, setTimeline] = useState<any[]>([])

  useEffect(() => {
    let alive = true
    setLoading(true)
    fetchWindowed(
      'v_client_performance_daily',
      'date, spend, crm_leads, crm_agendados, crm_ganhos, receita',
      period,
      'date',
      custom ?? undefined
    ).then(({ rows, current, previous }) => {
      if (!alive) return
      const { cur: c, prev: p } = splitByDate(rows, current, previous)
      setCur(agg(c)); setPrev(agg(p))

      // série diária do período atual, ordenada por data
      const byDate = c
        .slice()
        .sort((a, b) => a.date.localeCompare(b.date))
        .map((r) => {
          const leads = num(r.crm_leads)
          const spend = num(r.spend)
          return {
            label: dm(r.date),
            Leads: leads,
            CPL: leads > 0 ? Math.round((spend / leads) * 100) / 100 : 0,
          }
        })
      setTimeline(byDate)
      setLoading(false)
    })
    return () => { alive = false }
  }, [period, custom])

  const cpl = cur.leads > 0 ? cur.spend / cur.leads : null
  const cplPrev = prev.leads > 0 ? prev.spend / prev.leads : null
  const cac = cur.ganhos > 0 ? cur.spend / cur.ganhos : null
  const cacPrev = prev.ganhos > 0 ? prev.spend / prev.ganhos : null
  const roas = cur.spend > 0 ? cur.receita / cur.spend : null
  const roasPrev = prev.spend > 0 ? prev.receita / prev.spend : null

  if (loading) return <div className="state"><div className="spinner" />Carregando dados…</div>

  return (
    <>
      <div className="kpi-grid">
        <KpiCard primary label="Investimento" prefix="R$" value={brl(cur.spend)} current={cur.spend} previous={prev.spend} prevLabel={`vs. ${periodLabel}`} invert />
        <KpiCard label="Leads" value={int(cur.leads)} current={cur.leads} previous={prev.leads} prevLabel={`vs. ${periodLabel}`} />
        <KpiCard label="Agendamentos" value={int(cur.agendados)} current={cur.agendados} previous={prev.agendados} prevLabel={`vs. ${periodLabel}`} />
        <KpiCard label="Receita" prefix="R$" value={brl(cur.receita)} current={cur.receita} previous={prev.receita} prevLabel={`vs. ${periodLabel}`} />
      </div>

      <div className="kpi-grid kpi-sub">
        <KpiCard small label="Ganhos" value={int(cur.ganhos)} current={cur.ganhos} previous={prev.ganhos} prevLabel={`vs. ${periodLabel}`} />
        <KpiCard small label="CPL real" prefix="R$" value={cpl !== null ? brl(cpl, 2) : '—'} current={cpl ?? 0} previous={cplPrev ?? 0} prevLabel="vs. ant." invert />
        <KpiCard small label="CAC" prefix="R$" value={cac !== null ? brl(cac, 0) : '—'} current={cac ?? 0} previous={cacPrev ?? 0} prevLabel="vs. ant." invert />
        <KpiCard small label="ROAS real" suffix="x" value={roas !== null ? roas.toLocaleString('pt-BR', { minimumFractionDigits: 1, maximumFractionDigits: 1 }) : '—'} current={roas ?? 0} previous={roasPrev ?? 0} prevLabel="vs. ant." />
      </div>

      <div className="block">
        <div className="block-head">
          <span className="block-title">Evolução no período</span>
          <span className="block-sub">Leads e CPL por dia</span>
        </div>
        <LineTimeChart
          data={timeline}
          series={[
            { key: 'Leads', name: 'Leads', color: '#00313d' },
            { key: 'CPL', name: 'CPL (R$)', color: '#5fae95' },
          ]}
        />
      </div>

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        Valores aparecem como "—" quando não há dados suficientes no período. Resultados vêm do seu CRM, não das plataformas.
      </div>
    </>
  )
}
