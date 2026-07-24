'use client'

import { useEffect, useState, useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import { fetchWindowed, splitByDate } from '@/lib/data'
import { num, brl, int, getRanges, type Period, type CustomRange } from '@/lib/utils'
import DataTable, { type Column } from '@/components/DataTable'
import { LineTimeChart, ColumnChart } from '@/components/Charts'
import CohortNote from '@/components/CohortNote'

// ─── tipos ────────────────────────────────────────────────────────────────────

type CampRow = {
  group_name: string
  spend: number; impressions: number; clicks: number
  crm_leads: number; crm_agendados: number
  // Indicadores prontos do banco. NULL tem significado (não dá pra calcular)
  // e vira "—" na tela, nunca R$ 0,00.
  cpl: number | null
  cost_per_agendado: number | null
}

type KwRow = {
  keyword_text: string; campaign_name: string; ad_group_name: string
  keyword_match_type: string; keyword_status: string
  impressions: number; clicks: number; cost: number
}

function dm(iso: string) { const p = iso.split('-'); return `${p[2]}/${p[1]}` }

// ─── helpers (contrato V2) ────────────────────────────────────────────────────

// Formatador puro: o valor já vem calculado pela RPC.
function moneyOrDash(v: number | null) {
  return v === null ? <span className="cell-muted">—</span> : `R$ ${brl(v, 2)}`
}

// ─── componente ───────────────────────────────────────────────────────────────

export default function GoogleTab({
  clientId, period, custom,
}: { clientId: string; period: Period; periodLabel: string; custom: CustomRange | null }) {

  const [loading, setLoading] = useState(true)
  const [camps, setCamps] = useState<CampRow[]>([])
  const [timeline, setTimeline] = useState<any[]>([])
  const [keywords, setKeywords] = useState<KwRow[]>([])

  const [loadError, setLoadError] = useState(false)

  const load = useCallback(() => {
    setLoading(true)
    setLoadError(false)
    const { start, end } = getRanges(period, custom ?? undefined).current

    Promise.all([
      supabase.rpc('get_google_ads_summary_v2', {
        p_client_id: clientId, p_start_date: start, p_end_date: end, p_dimension: 'campaign',
      }),
      fetchWindowed('v_google_ads_v2', 'date, cost, impressions, clicks',
        period, clientId, 'date', custom ?? undefined),
      fetchWindowed('v_google_keywords_v2',
        'date, keyword_text, campaign_name, ad_group_name, keyword_match_type, keyword_status, impressions, clicks, cost',
        period, clientId, 'date', custom ?? undefined),
    ]).then(([campRes, media, kw]) => {
      if (campRes.error) {
        console.error('[Impuls] google summary:', campRes.error.message)
        setLoadError(true)
        setLoading(false)
        return
      }

      setCamps(((campRes.data ?? []) as any[]).map((r) => ({
        group_name: r.group_name ?? '(sem nome)',
        spend: num(r.spend), impressions: num(r.impressions), clicks: num(r.clicks),
        crm_leads: num(r.crm_leads ?? 0), crm_agendados: num(r.crm_agendados ?? 0),
        cpl: r.cpl === null || r.cpl === undefined ? null : num(r.cpl),
        cost_per_agendado: r.cost_per_agendado === null || r.cost_per_agendado === undefined
          ? null : num(r.cost_per_agendado),
      })).sort((a, b) => b.spend - a.spend))

      const mediaCur = splitByDate(media.rows, media.current, media.previous).cur
      const byDay = new Map<string, { impr: number; clicks: number }>()
      for (const r of mediaCur) {
        const d = byDay.get(r.date) ?? { impr: 0, clicks: 0 }
        d.impr += num(r.impressions); d.clicks += num(r.clicks)
        byDay.set(r.date, d)
      }
      setTimeline(
        [...byDay.entries()].sort((a, b) => a[0].localeCompare(b[0]))
          .map(([date, v]) => ({ label: dm(date), Impressões: v.impr, Cliques: v.clicks }))
      )

      const kmap = new Map<string, KwRow>()
      for (const r of kw.rows) {
        const key = `${r.campaign_name}|${r.ad_group_name}|${r.keyword_text}`
        const a = kmap.get(key) ?? {
          keyword_text: r.keyword_text, campaign_name: r.campaign_name,
          ad_group_name: r.ad_group_name, keyword_match_type: r.keyword_match_type,
          keyword_status: r.keyword_status, impressions: 0, clicks: 0, cost: 0,
        }
        a.impressions += num(r.impressions); a.clicks += num(r.clicks); a.cost += num(r.cost)
        kmap.set(key, a)
      }
      setKeywords([...kmap.values()].sort((a, b) => b.clicks - a.clicks))
      setLoading(false)
    })
  }, [clientId, period, custom])

  useEffect(() => { load() }, [load])

  // ── colunas campanhas ──────────────────────────────────────────────────────

  const campCols: Column<CampRow>[] = [
    { key: 'name', header: 'Campanha', width: 220,
      render: (r) => <span className="cell-name" title={r.group_name}>{r.group_name}</span>,
      sortValue: (r) => r.group_name },
    { key: 'spend', header: 'Investido', align: 'right',
      render: (r) => `R$ ${brl(r.spend)}`, sortValue: (r) => r.spend },
    { key: 'impr', header: 'Impressões', align: 'right',
      render: (r) => int(r.impressions), sortValue: (r) => r.impressions },
    { key: 'clicks', header: 'Cliques', align: 'right',
      render: (r) => int(r.clicks), sortValue: (r) => r.clicks },
    { key: 'leads', header: 'Leads', align: 'right',
      render: (r) => int(r.crm_leads), sortValue: (r) => r.crm_leads },
    { key: 'agend', header: 'Agendamentos', align: 'right',
      render: (r) => int(r.crm_agendados), sortValue: (r) => r.crm_agendados },
    { key: 'cpl', header: 'CPL', align: 'right',
      render: (r) => moneyOrDash(r.cpl),
      sortValue: (r) => r.cpl ?? -1 },
    { key: 'cpag', header: 'CPag', align: 'right',
      render: (r) => moneyOrDash(r.cost_per_agendado),
      sortValue: (r) => r.cost_per_agendado ?? -1 },
  ]

  // ── colunas keywords ───────────────────────────────────────────────────────

  const kwCols: Column<KwRow>[] = [
    { key: 'kw', header: 'Palavra-chave', width: 200,
      render: (r) => <span className="cell-strong cell-name" title={r.keyword_text}>{r.keyword_text}</span>,
      sortValue: (r) => r.keyword_text },
    { key: 'match', header: 'Tipo', render: (r) => <span className="cell-muted">{r.keyword_match_type}</span> },
    { key: 'status', header: 'Status', render: (r) => <span className="cell-muted">{r.keyword_status}</span> },
    { key: 'impr', header: 'Impressões', align: 'right',
      render: (r) => int(r.impressions), sortValue: (r) => r.impressions },
    { key: 'clicks', header: 'Cliques', align: 'right',
      render: (r) => int(r.clicks), sortValue: (r) => r.clicks },
    { key: 'ctr', header: 'CTR', align: 'right',
      render: (r) => r.impressions > 0 ? `${((r.clicks / r.impressions) * 100).toLocaleString('pt-BR', { maximumFractionDigits: 1 })}%` : '—',
      sortValue: (r) => r.impressions > 0 ? r.clicks / r.impressions : 0 },
    { key: 'cpc', header: 'CPC', align: 'right',
      render: (r) => r.clicks > 0 ? `R$ ${brl(r.cost / r.clicks, 2)}` : '—',
      sortValue: (r) => r.clicks > 0 ? r.cost / r.clicks : 0 },
    { key: 'cost', header: 'Custo', align: 'right',
      render: (r) => `R$ ${brl(r.cost)}`, sortValue: (r) => r.cost },
  ]

  if (loading) return <div className="state"><div className="spinner" />Carregando Google Ads…</div>

  if (loadError) return (
    <div className="state" style={{ flexDirection: 'column', gap: 12 }}>
      <span style={{ color: 'var(--ink-soft)', fontSize: 14 }}>
        Não foi possível carregar os dados. Pode ter sido um timeout no período selecionado.
      </span>
      <button className="sortbtn" style={{ border: '1px solid var(--line)' }} onClick={load}>
        Tentar novamente
      </button>
    </div>
  )

  return (
    <>
      <CohortNote period={period} />

      <div className="grid-2">
        <div className="block">
          <div className="block-head">
            <span className="block-title">Impressões e cliques</span>
            <span className="block-sub">Por dia — mídia da plataforma</span>
          </div>
          <LineTimeChart data={timeline} series={[
            { key: 'Impressões', name: 'Impressões', color: '#94d2bd' },
            { key: 'Cliques', name: 'Cliques', color: '#5fae95' },
          ]} />
        </div>
        <div className="block">
          <div className="block-head">
            <span className="block-title">Cliques por dia</span>
            <span className="block-sub">Evolução no período</span>
          </div>
          <ColumnChart
            data={timeline.map((r) => ({ label: r.label, value: r.Cliques }))}
            fmt={(v) => int(v)}
            color="#5fae95"
          />
        </div>
      </div>

      <div className="block-head" style={{ marginBottom: 12 }}>
        <span className="block-title">Campanhas</span>
        <span className="block-sub">Leads e agendamentos por safra de lead</span>
      </div>
      <DataTable columns={campCols} rows={camps} initialSort={{ key: 'spend', dir: 'desc' }} />

      <div className="block-head" style={{ marginBottom: 12, marginTop: 8 }}>
        <span className="block-title">Palavras-chave</span>
        <span className="block-sub">Termos configurados nas campanhas</span>
      </div>
      <DataTable columns={kwCols} rows={keywords} initialSort={{ key: 'clicks', dir: 'desc' }} />

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
          <circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" />
        </svg>
        Leads e Agendamentos vêm do CRM por coorte. Registros sem ID técnico aparecem como "Conta não identificada" ou "Campanha não identificada" — não são removidos dos totais.
      </div>
    </>
  )
}
