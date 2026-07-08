'use client'

import { useEffect, useState } from 'react'
import { fetchWindowed, splitByDate } from '@/lib/data'
import { num, int, pct, type Period, type CustomRange } from '@/lib/utils'
import { FunnelChart } from '@/components/Charts'
import KpiCard from '@/components/KpiCard'

type F = { leads: number; conversas: number; agendados: number; ganhos: number; perdidos: number }
const EMPTY: F = { leads: 0, conversas: 0, agendados: 0, ganhos: 0, perdidos: 0 }

function agg(rows: any[]): F {
  return rows.reduce<F>((a, r) => ({
    leads: a.leads + num(r.crm_leads),
    conversas: a.conversas + num(r.crm_primeiras_conversas),
    agendados: a.agendados + num(r.crm_agendados),
    ganhos: a.ganhos + num(r.crm_ganhos),
    perdidos: a.perdidos + num(r.crm_perdidos),
  }), { ...EMPTY })
}

export default function FunnelTab({ period, periodLabel, custom }: { period: Period; periodLabel: string; custom: CustomRange | null }) {
  const [loading, setLoading] = useState(true)
  const [cur, setCur] = useState<F>(EMPTY)
  const [prev, setPrev] = useState<F>(EMPTY)

  useEffect(() => {
    let alive = true
    setLoading(true)
    // Atenção: esta view usa 'event_date' como coluna de data.
    fetchWindowed(
      'v_crm_funnel_daily',
      'event_date, crm_leads, crm_primeiras_conversas, crm_agendados, crm_ganhos, crm_perdidos',
      period,
      'event_date',
      custom ?? undefined
    ).then(({ rows, current, previous }) => {
      if (!alive) return
      const { cur: c, prev: p } = splitByDate(rows, current, previous, 'event_date')
      setCur(agg(c)); setPrev(agg(p))
      setLoading(false)
    })
    return () => { alive = false }
  }, [period, custom])

  if (loading) return <div className="state"><div className="spinner" />Carregando funil…</div>

  const stages = [
    { name: 'Leads', value: cur.leads },
    { name: 'Primeira conversa', value: cur.conversas },
    { name: 'Agendados', value: cur.agendados },
    { name: 'Ganhos', value: cur.ganhos },
  ]

  // taxas de conversão principais — atual e anterior (pra comparativo)
  const tLeadAgend = cur.leads > 0 ? (cur.agendados / cur.leads) * 100 : null
  const tLeadAgendPrev = prev.leads > 0 ? (prev.agendados / prev.leads) * 100 : null
  const tAgendGanho = cur.agendados > 0 ? (cur.ganhos / cur.agendados) * 100 : null
  const tAgendGanhoPrev = prev.agendados > 0 ? (prev.ganhos / prev.agendados) * 100 : null
  const tLeadGanho = cur.leads > 0 ? (cur.ganhos / cur.leads) * 100 : null
  const tLeadGanhoPrev = prev.leads > 0 ? (prev.ganhos / prev.leads) * 100 : null

  return (
    <>
      <div className="block">
        <div className="block-head">
          <span className="block-title">Funil comercial</span>
          <span className="block-sub">Do lead ao ganho · % = conversão da etapa anterior</span>
        </div>
        <FunnelChart stages={stages} />
      </div>

      <div className="kpi-grid kpi-sub">
        <KpiCard small label="Lead → Agendado" value={tLeadAgend !== null ? pct(tLeadAgend) : '—'} current={tLeadAgend ?? 0} previous={tLeadAgendPrev ?? 0} prevLabel={`vs. ${periodLabel}`} />
        <KpiCard small label="Agendado → Ganho" value={tAgendGanho !== null ? pct(tAgendGanho) : '—'} current={tAgendGanho ?? 0} previous={tAgendGanhoPrev ?? 0} prevLabel={`vs. ${periodLabel}`} />
        <KpiCard small label="Lead → Ganho" value={tLeadGanho !== null ? pct(tLeadGanho) : '—'} current={tLeadGanho ?? 0} previous={tLeadGanhoPrev ?? 0} prevLabel={`vs. ${periodLabel}`} />
        <KpiCard small label="Perdidos" value={int(cur.perdidos)} current={cur.perdidos} previous={prev.perdidos} prevLabel={`vs. ${periodLabel}`} invert />
      </div>

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        O gargalo é a etapa onde a queda percentual é maior. Foque nela para destravar mais vendas.
      </div>
    </>
  )
}
