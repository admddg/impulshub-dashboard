'use client'

import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { num, brl, int, getRanges, type Period, type CustomRange } from '@/lib/utils'
import KpiCard from '@/components/KpiCard'
import { LineTimeChart } from '@/components/Charts'

type Overview = {
  investment: number | null; investment_is_complete: boolean | null
  leads: number; paid_attributed_leads: number
  primeiras_conversas: number; agendados: number
  crm_ganhos: number
  acquisition_buying_contacts: number; acquisition_sales: number; cohort_total_sales: number
  acquisition_revenue: number | null; acquisition_revenue_is_complete: boolean | null
  closed_sales: number; closed_revenue: number | null; closed_revenue_is_complete: boolean | null
  cpl_paid: number | null; cac_acquisition: number | null; roas_acquisition: number | null
}

const EMPTY: Overview = {
  investment: null, investment_is_complete: null,
  leads: 0, paid_attributed_leads: 0, primeiras_conversas: 0, agendados: 0,
  crm_ganhos: 0, acquisition_buying_contacts: 0, acquisition_sales: 0, cohort_total_sales: 0,
  acquisition_revenue: null, acquisition_revenue_is_complete: null,
  closed_sales: 0, closed_revenue: null, closed_revenue_is_complete: null,
  cpl_paid: null, cac_acquisition: null, roas_acquisition: null,
}

function toOverview(r: any): Overview {
  return {
    investment: r.investment !== null ? num(r.investment) : null,
    investment_is_complete: r.investment_is_complete ?? null,
    leads: num(r.leads), paid_attributed_leads: num(r.paid_attributed_leads),
    primeiras_conversas: num(r.primeiras_conversas), agendados: num(r.agendados),
    crm_ganhos: num(r.crm_ganhos),
    acquisition_buying_contacts: num(r.acquisition_buying_contacts),
    acquisition_sales: num(r.acquisition_sales), cohort_total_sales: num(r.cohort_total_sales),
    acquisition_revenue: r.acquisition_revenue !== null ? num(r.acquisition_revenue) : null,
    acquisition_revenue_is_complete: r.acquisition_revenue_is_complete ?? null,
    closed_sales: num(r.closed_sales),
    closed_revenue: r.closed_revenue !== null ? num(r.closed_revenue) : null,
    closed_revenue_is_complete: r.closed_revenue_is_complete ?? null,
    cpl_paid: r.cpl_paid !== null ? num(r.cpl_paid) : null,
    cac_acquisition: r.cac_acquisition !== null ? num(r.cac_acquisition) : null,
    roas_acquisition: r.roas_acquisition !== null ? num(r.roas_acquisition) : null,
  }
}

function dm(iso: string) { const [, m, d] = iso.split('-'); return `${d}/${m}` }

// "—" para ausência — sem textos longos na UI
const dash = '—'
function moneyOrDash(v: number | null, complete: boolean | null = true): string {
  if (v === null || complete === false) return dash
  return brl(v)  // sem "R$" — prefix do KpiCard já cuida disso
}
function ratioOrDash(v: number | null, complete: boolean | null = true): string {
  if (v === null || complete === false) return dash
  return v.toLocaleString('pt-BR', { minimumFractionDigits: 1, maximumFractionDigits: 2 })
}
function moneySmall(v: number | null): string {
  return v !== null ? brl(v, 2) : dash
}

export default function OverviewTab({ clientId, period, periodLabel, custom }: {
  clientId: string; period: Period; periodLabel: string; custom: CustomRange | null
}) {
  const [loading, setLoading] = useState(true)
  const [cur, setCur] = useState<Overview>(EMPTY)
  const [prev, setPrev] = useState<Overview>(EMPTY)
  const [timeline, setTimeline] = useState<any[]>([])

  useEffect(() => {
    let alive = true
    setLoading(true)
    const { current, previous } = getRanges(period, custom ?? undefined)

    // Otimização de performance: busca período atual e gráfico diário em paralelo,
    // e só depois (se ainda vivo) busca o período anterior para os comparativos.
    // Isso permite renderizar os cards principais mais rápido, sem travar na
    // segunda chamada de overview que é só para os deltas.
    Promise.all([
      supabase.rpc('get_client_overview_v2', {
        p_client_id: clientId, p_start_date: current.start, p_end_date: current.end,
      }),
      supabase.from('v_client_performance_daily_v2')
        .select('date, cohort_leads, cohort_paid_attributed_leads, reported_spend, spend_is_complete')
        .eq('client_id', clientId).gte('date', current.start).lte('date', current.end),
    ]).then(([curRes, dailyRes]) => {
      if (!alive) return
      if (curRes.error) console.error('[Impuls] overview atual:', curRes.error.message)
      if (dailyRes.error) console.error('[Impuls] performance daily:', dailyRes.error.message)

      setCur(curRes.data?.[0] ? toOverview(curRes.data[0]) : EMPTY)

      setTimeline(
        ((dailyRes.data ?? []) as any[])
          .slice().sort((a, b) => a.date.localeCompare(b.date))
          .map((r) => {
            const paidLeads = num(r.cohort_paid_attributed_leads)
            const spend = num(r.reported_spend)
            return {
              label: dm(r.date), Leads: num(r.cohort_leads),
              CPL: r.spend_is_complete && paidLeads > 0 ? Math.round(spend / paidLeads * 100) / 100 : 0,
            }
          })
      )
      setLoading(false)

      // Busca período anterior em segundo plano — só para os deltas
      supabase.rpc('get_client_overview_v2', {
        p_client_id: clientId, p_start_date: previous.start, p_end_date: previous.end,
      }).then(({ data, error }) => {
        if (!alive) return
        if (error) console.error('[Impuls] overview anterior:', error.message)
        if (data?.[0]) setPrev(toOverview(data[0]))
      })
    })

    return () => { alive = false }
  }, [clientId, period, custom])

  if (loading) return <div className="state"><div className="spinner" />Carregando dados…</div>

  return (
    <>
      <div className="kpi-grid">
        <KpiCard primary label="Investimento" prefix="R$"
          value={moneyOrDash(cur.investment, cur.investment_is_complete)}
          current={cur.investment ?? 0} previous={prev.investment ?? 0}
          prevLabel={`vs. ${periodLabel}`} invert />
        <KpiCard label="Leads" value={int(cur.leads)}
          current={cur.leads} previous={prev.leads} prevLabel={`vs. ${periodLabel}`} />
        <KpiCard label="Agendamentos" value={int(cur.agendados)}
          current={cur.agendados} previous={prev.agendados} prevLabel={`vs. ${periodLabel}`} />
        <KpiCard label="Receita" prefix="R$"
          value={moneyOrDash(cur.acquisition_revenue, cur.acquisition_revenue_is_complete)}
          current={cur.acquisition_revenue ?? 0} previous={prev.acquisition_revenue ?? 0}
          prevLabel={`vs. ${periodLabel}`} />
      </div>

      <div className="kpi-grid kpi-sub">
        <KpiCard small label="Ganhos" value={int(cur.crm_ganhos)}
          current={cur.crm_ganhos} previous={prev.crm_ganhos} prevLabel={`vs. ${periodLabel}`} />
        <KpiCard small label="CPL pago" prefix="R$"
          value={moneySmall(cur.cpl_paid)}
          current={cur.cpl_paid ?? 0} previous={prev.cpl_paid ?? 0} prevLabel="vs. ant." invert />
        <KpiCard small label="CAC" prefix="R$"
          value={moneySmall(cur.cac_acquisition)}
          current={cur.cac_acquisition ?? 0} previous={prev.cac_acquisition ?? 0} prevLabel="vs. ant." invert />
        <KpiCard small label="ROAS" suffix="x"
          value={ratioOrDash(cur.roas_acquisition, cur.acquisition_revenue_is_complete)}
          current={cur.roas_acquisition ?? 0} previous={prev.roas_acquisition ?? 0} prevLabel="vs. ant." />
      </div>

      <div className="block">
        <div className="block-head">
          <span className="block-title">Evolução no período</span>
          <span className="block-sub">Leads e CPL por dia</span>
        </div>
        <LineTimeChart data={timeline} series={[
          { key: 'Leads', name: 'Leads', color: '#00313d' },
          { key: 'CPL', name: 'CPL (R$)', color: '#5fae95' },
        ]} />
      </div>

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
          <circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" />
        </svg>
        Ganhos é uma métrica de jornada por contato. Receita e ROAS mostram "—" quando há vendas sem valor preenchido no CRM.
      </div>
    </>
  )
}
