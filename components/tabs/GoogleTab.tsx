'use client'

import { useEffect, useState } from 'react'
import { fetchWindowed, fetchAll, splitByDate } from '@/lib/data'
import { num, brl, int, type Period, type CustomRange } from '@/lib/utils'
import DataTable, { type Column } from '@/components/DataTable'
import { LineTimeChart, ColumnChart } from '@/components/Charts'

type GRow = { campaign_name: string; spend: number; impressions: number; clicks: number; crm_leads: number; google_conversions: number }
type KwRow = {
  keyword_text: string; campaign_name: string; ad_group_name: string; keyword_match_type: string; keyword_status: string
  impressions: number; clicks: number; cost: number; ctr_percent: number; cpc: number; conversions: number
}

function dm(iso: string) { const p = iso.split('-'); return `${p[2]}/${p[1]}` }

export default function GoogleTab({ period, custom }: { period: Period; periodLabel: string; custom: CustomRange | null }) {
  const [loading, setLoading] = useState(true)
  const [rows, setRows] = useState<GRow[]>([])
  const [timeline, setTimeline] = useState<any[]>([])
  const [convEvo, setConvEvo] = useState<{ label: string; value: number }[]>([])
  const [keywords, setKeywords] = useState<KwRow[]>([])
  const [totalConv, setTotalConv] = useState(0)
  const [totalLeads, setTotalLeads] = useState(0)

  useEffect(() => {
    let alive = true
    setLoading(true)
    Promise.all([
      fetchWindowed('v_google_campaign_daily', 'date, campaign_name, spend, impressions, clicks, crm_leads, google_conversions', period, 'date', custom ?? undefined),
      fetchWindowed('v_google_ads_keywords_daily', 'date, keyword_text, campaign_name, ad_group_name, keyword_match_type, keyword_status, impressions, clicks, cost, ctr_percent, cpc, conversions', period, 'date', custom ?? undefined),
    ]).then(([camp, kw]) => {
      if (!alive) return
      const cur = splitByDate(camp.rows, camp.current, camp.previous).cur

      // tabela campanhas
      const map = new Map<string, GRow>()
      let convSum = 0, leadSum = 0
      for (const r of cur) {
        const key = r.campaign_name ?? '(sem nome)'
        const a = map.get(key) ?? { campaign_name: key, spend: 0, impressions: 0, clicks: 0, crm_leads: 0, google_conversions: 0 }
        a.spend += num(r.spend); a.impressions += num(r.impressions); a.clicks += num(r.clicks); a.crm_leads += num(r.crm_leads); a.google_conversions += num(r.google_conversions)
        map.set(key, a)
        convSum += num(r.google_conversions); leadSum += num(r.crm_leads)
      }
      setRows([...map.values()].sort((a, b) => b.spend - a.spend))
      setTotalConv(convSum); setTotalLeads(leadSum)

      // gráfico linha por dia
      const byDay = new Map<string, { impressions: number; clicks: number; leads: number; conv: number }>()
      for (const r of cur) {
        const d = byDay.get(r.date) ?? { impressions: 0, clicks: 0, leads: 0, conv: 0 }
        d.impressions += num(r.impressions); d.clicks += num(r.clicks); d.leads += num(r.crm_leads); d.conv += num(r.google_conversions)
        byDay.set(r.date, d)
      }
      const ordered = [...byDay.entries()].sort((a, b) => a[0].localeCompare(b[0]))
      setTimeline(ordered.map(([date, v]) => ({ label: dm(date), Impressões: v.impressions, Cliques: v.clicks, Leads: v.leads })))
      setConvEvo(ordered.map(([date, v]) => ({ label: dm(date), value: v.conv })))

      // keywords agregadas — usa TODO o range retornado (não divide em atual/anterior,
      // pois keyword é referência, não métrica de comparação temporal)
      const kmap = new Map<string, KwRow>()
      for (const r of kw.rows) {
        const key = `${r.campaign_name}|${r.ad_group_name}|${r.keyword_text}`
        const a = kmap.get(key) ?? { keyword_text: r.keyword_text, campaign_name: r.campaign_name, ad_group_name: r.ad_group_name, keyword_match_type: r.keyword_match_type, keyword_status: r.keyword_status, impressions: 0, clicks: 0, cost: 0, ctr_percent: 0, cpc: 0, conversions: 0 }
        a.impressions += num(r.impressions); a.clicks += num(r.clicks); a.cost += num(r.cost); a.conversions += num(r.conversions)
        kmap.set(key, a)
      }
      // recalcula ctr/cpc agregados
      const kws = [...kmap.values()].map((k) => ({ ...k, ctr_percent: k.impressions > 0 ? (k.clicks / k.impressions) * 100 : 0, cpc: k.clicks > 0 ? k.cost / k.clicks : 0 }))
      setKeywords(kws.sort((a, b) => b.clicks - a.clicks))
      setLoading(false)
    })
    return () => { alive = false }
  }, [period, custom])

  const campCols: Column<GRow>[] = [
    { key: 'campaign_name', header: 'Campanha', render: (r) => <span className="cell-name" title={r.campaign_name}>{r.campaign_name}</span>, sortValue: (r) => r.campaign_name, width: 240 },
    { key: 'spend', header: 'Investido', align: 'right', render: (r) => `R$ ${brl(r.spend)}`, sortValue: (r) => r.spend },
    { key: 'impr', header: 'Impr.', align: 'right', render: (r) => int(r.impressions), sortValue: (r) => r.impressions },
    { key: 'clicks', header: 'Cliques', align: 'right', render: (r) => int(r.clicks), sortValue: (r) => r.clicks },
    { key: 'conv', header: 'Conv. Google', align: 'right', render: (r) => int(r.google_conversions), sortValue: (r) => r.google_conversions },
    { key: 'leads', header: 'Leads CRM', align: 'right', render: (r) => int(r.crm_leads), sortValue: (r) => r.crm_leads },
    { key: 'cpl', header: 'CPL', align: 'right', render: (r) => r.crm_leads > 0 ? `R$ ${brl(r.spend / r.crm_leads, 2)}` : <span className="cell-muted">—</span>, sortValue: (r) => r.crm_leads > 0 ? r.spend / r.crm_leads : 0 },
  ]

  const kwCols: Column<KwRow>[] = [
    { key: 'keyword_text', header: 'Palavra-chave', render: (r) => <span className="cell-strong cell-name" title={r.keyword_text}>{r.keyword_text}</span>, sortValue: (r) => r.keyword_text, width: 200 },
    { key: 'match', header: 'Tipo', render: (r) => <span className="cell-muted">{r.keyword_match_type}</span> },
    { key: 'status', header: 'Status', render: (r) => <span className="cell-muted">{r.keyword_status}</span> },
    { key: 'impr', header: 'Impr.', align: 'right', render: (r) => int(r.impressions), sortValue: (r) => r.impressions },
    { key: 'clicks', header: 'Cliques', align: 'right', render: (r) => int(r.clicks), sortValue: (r) => r.clicks },
    { key: 'ctr', header: 'CTR', align: 'right', render: (r) => `${r.ctr_percent.toLocaleString('pt-BR', { maximumFractionDigits: 1 })}%`, sortValue: (r) => r.ctr_percent },
    { key: 'cpc', header: 'CPC', align: 'right', render: (r) => r.cpc > 0 ? `R$ ${brl(r.cpc, 2)}` : '—', sortValue: (r) => r.cpc },
    { key: 'cost', header: 'Custo', align: 'right', render: (r) => `R$ ${brl(r.cost)}`, sortValue: (r) => r.cost },
  ]

  if (loading) return <div className="state"><div className="spinner" />Carregando Google Ads…</div>

  return (
    <>
      <div className="grid-2">
        <div className="block">
          <div className="block-head"><span className="block-title">Impressões, cliques e leads</span><span className="block-sub">Por dia</span></div>
          <LineTimeChart data={timeline} series={[
            { key: 'Impressões', name: 'Impressões', color: '#94d2bd' },
            { key: 'Cliques', name: 'Cliques', color: '#5fae95' },
            { key: 'Leads', name: 'Leads', color: '#00313d' },
          ]} />
        </div>
        <div className="block">
          <div className="block-head"><span className="block-title">Conversões Google por dia</span><span className="block-sub">Evolução no período</span></div>
          <ColumnChart data={convEvo} fmt={(v) => int(v)} color="#5fae95" />
        </div>
      </div>

      <div className="block-head" style={{ marginBottom: 12 }}><span className="block-title">Campanhas</span></div>
      <DataTable columns={campCols} rows={rows} initialSort={{ key: 'spend', dir: 'desc' }} />

      <div className="block-head" style={{ marginBottom: 12, marginTop: 8 }}><span className="block-title">Palavras-chave</span><span className="block-sub">Termos configurados nas campanhas</span></div>
      <DataTable columns={kwCols} rows={keywords} initialSort={{ key: 'clicks', dir: 'desc' }} />

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        "Conv. Google" é o que a plataforma reporta; "Leads CRM" é o que virou contato real no seu funil.
      </div>
    </>
  )
}
