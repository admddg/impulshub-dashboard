'use client'

import { useEffect, useState, useMemo, useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import { num, brl, int, hiResImg, getRanges, type Period, type CustomRange } from '@/lib/utils'
import DataTable, { type Column } from '@/components/DataTable'
import { HBarChart } from '@/components/Charts'
import Lightbox from '@/components/Lightbox'
import CohortNote from '@/components/CohortNote'

type Sub = 'contas' | 'campanhas' | 'anuncios' | 'criativos'

type Row = {
  group_id: string; group_name: string
  account_id: string; account_name: string
  spend: number; crm_leads: number; crm_agendados: number
  acquisition_revenue: number | null; acquisition_revenue_is_complete: boolean | null
  roas_acquisition: number | null
  // Indicadores calculados no banco. Nunca recalcular aqui: o banco devolve
  // NULL quando a conta não faz sentido (sem investimento, sem lead pago), e
  // esse NULL carrega informação — vira "—", não zero.
  cpl: number | null
  cost_per_agendado: number | null
  cac_acquisition: number | null
  ad_name: string | null; headline: string | null
  creative_url: string | null; image_url: string | null; thumbnail_url: string | null
}

type DimState = { data: Row[]; status: 'idle' | 'loading' | 'ok' | 'error' }
const EMPTY_DIM: DimState = { data: [], status: 'idle' }
const SUBS: Sub[] = ['contas', 'campanhas', 'anuncios', 'criativos']
const DIM_MAP: Record<Sub, string> = {
  contas: 'account', campanhas: 'campaign', anuncios: 'ad', criativos: 'creative',
}

// helpers
const dash = '—'
const money = (v: number) => `R$ ${brl(v)}`
// Formatador puro: recebe o valor já calculado pelo banco. NULL vira "—".
const moneyOrDash = (v: number | null) => v === null ? dash : `R$ ${brl(v, 2)}`
const receitaFmt = (v: number | null, ok: boolean | null) =>
  v === null || ok === false ? dash : `R$ ${brl(v)}`
const roasFmt = (v: number | null, ok: boolean | null) =>
  v === null || ok === false ? dash
    : v.toLocaleString('pt-BR', { minimumFractionDigits: 1, maximumFractionDigits: 2 }) + 'x'

function mapRow(r: any): Row {
  return {
    group_id: r.group_id ?? '', group_name: r.group_name ?? '(sem nome)',
    account_id: r.account_id ?? '', account_name: r.account_name ?? '',
    spend: num(r.spend), crm_leads: num(r.crm_leads), crm_agendados: num(r.crm_agendados),
    acquisition_revenue: r.acquisition_revenue !== null ? num(r.acquisition_revenue) : null,
    acquisition_revenue_is_complete: r.acquisition_revenue_is_complete ?? null,
    roas_acquisition: r.roas_acquisition !== null ? num(r.roas_acquisition) : null,
    cpl: r.cpl === null || r.cpl === undefined ? null : num(r.cpl),
    cost_per_agendado: r.cost_per_agendado === null || r.cost_per_agendado === undefined ? null : num(r.cost_per_agendado),
    cac_acquisition: r.cac_acquisition === null || r.cac_acquisition === undefined ? null : num(r.cac_acquisition),
    ad_name: r.ad_name ?? null, headline: r.headline ?? null,
    creative_url: r.creative_url ?? null, image_url: r.image_url ?? null,
    thumbnail_url: r.thumbnail_url ?? null,
  }
}

export default function MetaTab({ clientId, period, custom }: {
  clientId: string; period: Period; periodLabel: string; custom: CustomRange | null
}) {
  const [sub, setSub] = useState<Sub>('contas')
  const [dims, setDims] = useState<Record<Sub, DimState>>({
    contas: EMPTY_DIM, campanhas: EMPTY_DIM, anuncios: EMPTY_DIM, criativos: EMPTY_DIM,
  })
  const [accountFilter, setAccountFilter] = useState('all')
  const [creativeSort, setCreativeSort] = useState<'spend' | 'leads' | 'agend'>('spend')
  const [zoom, setZoom] = useState<{ src: string; alt: string } | null>(null)

  // Reseta tudo quando cliente ou período muda
  useEffect(() => {
    setDims({ contas: EMPTY_DIM, campanhas: EMPTY_DIM, anuncios: EMPTY_DIM, criativos: EMPTY_DIM })
    setAccountFilter('all')
  }, [clientId, period, custom])

  // Carrega uma dimensão sob demanda — guarda contra duplicação pelo status
  const loadDim = useCallback((dimension: Sub) => {
    setDims((prev) => {
      if (prev[dimension].status !== 'idle') return prev // já carregado ou em andamento
      return { ...prev, [dimension]: { data: [], status: 'loading' } }
    })
    const { start, end } = getRanges(period, custom ?? undefined).current
    supabase.rpc('get_meta_ads_summary_v2', {
      p_client_id: clientId, p_start_date: start, p_end_date: end,
      p_dimension: DIM_MAP[dimension],
    }).then(({ data, error }) => {
      if (error) {
        console.error('[Impuls] meta summary:', DIM_MAP[dimension], error.message)
        setDims((prev) => ({ ...prev, [dimension]: { data: [], status: 'error' } }))
        return
      }
      setDims((prev) => ({
        ...prev,
        [dimension]: { data: ((data ?? []) as any[]).map(mapRow), status: 'ok' },
      }))
    })
  }, [clientId, period, custom])

  // Carrega a sub-aba ativa (única fonte de trigger — sem duplicação)
  useEffect(() => { loadDim(sub) }, [sub, loadDim])

  const cur = dims[sub]

  const accountOptions = useMemo(() => {
    const seen = new Map<string, string>()
    SUBS.forEach((s) => dims[s].data.forEach((r) => {
      if (r.account_id) seen.set(r.account_id, r.account_name)
    }))
    return [...seen.entries()].map(([id, name]) => ({ id, name }))
  }, [dims])

  function filtered(rows: Row[]) {
    return accountFilter === 'all' ? rows : rows.filter((r) => r.account_id === accountFilter)
  }

  const creativesFiltered = useMemo(() => {
    const f = filtered(dims.criativos.data)
    const sorters = {
      spend: (a: Row, b: Row) => b.spend - a.spend,
      leads: (a: Row, b: Row) => b.crm_leads - a.crm_leads,
      agend: (a: Row, b: Row) => b.crm_agendados - a.crm_agendados,
    }
    return [...f].sort(sorters[creativeSort])
  }, [dims.criativos.data, accountFilter, creativeSort])

  function bestImg(r: Row) {
    return hiResImg(r.creative_url) || r.image_url || hiResImg(r.thumbnail_url)
  }

  function fullFunnelCols(firstHeader: string): Column<Row>[] {
    return [
      { key: 'name', header: firstHeader, width: 200,
        render: (r) => <span className="cell-strong cell-name" title={r.group_name}>{r.group_name}</span>,
        sortValue: (r) => r.group_name },
      { key: 'spend', header: 'Investido', align: 'right',
        render: (r) => money(r.spend), sortValue: (r) => r.spend },
      { key: 'leads', header: 'Leads', align: 'right',
        render: (r) => int(r.crm_leads), sortValue: (r) => r.crm_leads },
      { key: 'cpl', header: 'CPL', align: 'right',
        render: (r) => r.cpl === null ? <span className="cell-muted">—</span> : moneyOrDash(r.cpl),
        sortValue: (r) => r.cpl ?? -1 },
      { key: 'agend', header: 'Agendam.', align: 'right',
        render: (r) => int(r.crm_agendados), sortValue: (r) => r.crm_agendados },
      { key: 'cpag', header: 'CPag', align: 'right',
        render: (r) => r.cost_per_agendado === null ? <span className="cell-muted">—</span> : moneyOrDash(r.cost_per_agendado),
        sortValue: (r) => r.cost_per_agendado ?? -1 },
      { key: 'receita', header: 'Receita', align: 'right',
        tooltip: 'Receita de aquisição por coorte de lead',
        render: (r) => { const v = receitaFmt(r.acquisition_revenue, r.acquisition_revenue_is_complete); return v === dash ? <span className="cell-muted">—</span> : v },
        sortValue: (r) => r.acquisition_revenue ?? -1 },
      { key: 'roas', header: 'ROAS', align: 'right',
        render: (r) => { const v = roasFmt(r.roas_acquisition, r.acquisition_revenue_is_complete); return v === dash ? <span className="cell-muted">—</span> : v },
        sortValue: (r) => r.roas_acquisition ?? -1 },
    ]
  }

  function totalOf(rows: Row[], label: string) {
    const t = rows.reduce((a, r) => ({
      spend: a.spend + r.spend, leads: a.leads + r.crm_leads, agend: a.agend + r.crm_agendados,
    }), { spend: 0, leads: 0, agend: 0 })
    // Guarda igual à do banco: sem investimento ou sem denominador, não existe
    // indicador — exibe "—" em vez de um R$ 0,00 que comunicaria algo falso.
    const razao = (num: number, den: number) =>
      num > 0 && den > 0 ? `R$ ${brl(num / den, 2)}` : dash
    return {
      name: label, spend: money(t.spend), leads: int(t.leads),
      cpl: razao(t.spend, t.leads),
      agend: int(t.agend),
      cpag: razao(t.spend, t.agend),
      receita: dash, roas: dash,
    }
  }

  function AccountSelect() {
    if (accountOptions.length <= 1) return null
    return (
      <div className="subbar">
        <span className="subbar-label">Conta:</span>
        <select className="select-native" value={accountFilter}
          onChange={(e) => setAccountFilter(e.target.value)}>
          <option value="all">Todas as contas</option>
          {accountOptions.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
        </select>
      </div>
    )
  }

  function DimError({ dim }: { dim: Sub }) {
    return (
      <div className="state" style={{ flexDirection: 'column', gap: 12 }}>
        <span style={{ color: 'var(--ink-soft)', fontSize: 14 }}>
          Não foi possível carregar os dados. Tente novamente.
        </span>
        <button className="sortbtn" style={{ border: '1px solid var(--line)' }}
          onClick={() => setDims((prev) => ({ ...prev, [dim]: EMPTY_DIM }))}>
          Tentar novamente
        </button>
      </div>
    )
  }

  function TabContent() {
    if (cur.status === 'idle' || cur.status === 'loading')
      return <div className="state"><div className="spinner" />Carregando Meta Ads…</div>
    if (cur.status === 'error') return <DimError dim={sub} />

    const rows = filtered(cur.data).sort((a, b) => b.spend - a.spend)

    if (sub === 'contas') return (
      <>
        <div className="block">
          <div className="block-head">
            <span className="block-title">Leads por conta de anúncio</span>
            <span className="block-sub">Leads do CRM atribuídos a cada conta</span>
          </div>
          <HBarChart data={cur.data.map((r) => ({ label: r.group_name, value: r.crm_leads, color: '#00313d' }))}
            fmt={(v) => int(v)} height={Math.max(cur.data.length * 42, 100)} />
        </div>
        <DataTable columns={fullFunnelCols('Conta de anúncio')} rows={cur.data}
          initialSort={{ key: 'spend', dir: 'desc' }} totalRow={totalOf(cur.data, 'Total')} />
      </>
    )

    if (sub === 'campanhas') return (
      <>
        <AccountSelect />
        <DataTable columns={fullFunnelCols('Campanha')} rows={rows}
          initialSort={{ key: 'spend', dir: 'desc' }} totalRow={totalOf(rows, 'Total')} />
      </>
    )

    if (sub === 'anuncios') return (
      <>
        <AccountSelect />
        <DataTable columns={fullFunnelCols('Anúncio')} rows={rows}
          initialSort={{ key: 'spend', dir: 'desc' }} totalRow={totalOf(rows, 'Total')} />
      </>
    )

    // criativos
    return (
      <>
        <div className="subbar" style={{ justifyContent: 'space-between' }}>
          <AccountSelect />
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span className="subbar-label">Ordenar:</span>
            <div className="sortbtns">
              {(['spend', 'leads', 'agend'] as const).map((s) => (
                <button key={s} className={`sortbtn ${creativeSort === s ? 'active' : ''}`}
                  onClick={() => setCreativeSort(s)}>
                  {s === 'spend' ? 'Investimento' : s === 'leads' ? 'Leads' : 'Agendam.'}
                </button>
              ))}
            </div>
          </div>
        </div>
        <div className="creative-grid">
          {creativesFiltered.length === 0 && (
            <div className="table-empty" style={{ gridColumn: '1/-1' }}>Nenhum criativo no período.</div>
          )}
          {creativesFiltered.map((c, i) => {
            const img = bestImg(c)
            // Hierarquia oficial (contrato banco 16/07):
            // título    → ad_name || creative_name (group_name) || creative_id (group_id)
            // subtítulo → headline quando diferente do título
            const title = c.ad_name || c.group_name || c.group_id || 'Criativo sem nome'
            const subtitle = c.headline && c.headline !== title ? c.headline : null
            return (
              <div className="creative" key={i}>
                {img
                  ? <img className="creative-img" src={img} alt={title} loading="lazy"
                      onClick={() => setZoom({ src: img, alt: title })} />
                  : <div className="creative-noimg">sem imagem</div>}
                <div className="creative-body">
                  <div className="creative-adname">{title}</div>
                  {subtitle && <div className="creative-headline">{subtitle}</div>}
                  <div className="creative-metrics">
                    <div className="creative-metric"><div className="m-label">Investido</div><div className="m-value">{money(c.spend)}</div></div>
                    <div className="creative-metric"><div className="m-label">Leads</div><div className="m-value">{int(c.crm_leads)}</div></div>
                    <div className="creative-metric"><div className="m-label">Agendam.</div><div className="m-value">{int(c.crm_agendados)}</div></div>
                    <div className="creative-metric"><div className="m-label">Custo/Agend.</div><div className="m-value">{moneyOrDash(c.cost_per_agendado)}</div></div>
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      </>
    )
  }

  return (
    <>
      <CohortNote period={period} />
      <div className="tabs" style={{ marginBottom: 16 }}>
        {SUBS.map((s) => (
          <button key={s} className={`tab ${sub === s ? 'active' : ''}`} onClick={() => setSub(s)}>
            {s === 'contas' ? 'Contas de Anúncio' : s === 'campanhas' ? 'Campanhas' : s === 'anuncios' ? 'Anúncios' : 'Criativos'}
            {dims[s].status === 'loading' && <span style={{ marginLeft: 6, opacity: 0.5, fontSize: 11 }}>⟳</span>}
          </button>
        ))}
      </div>

      <TabContent />

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
          <circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" />
        </svg>
        Leads, Agendamentos, Receita e ROAS vêm do CRM por coorte de lead. "—" indica dado indisponível. Na aba Criativos, clique na imagem para ampliar.
      </div>

      {zoom && <Lightbox src={zoom.src} alt={zoom.alt} onClose={() => setZoom(null)} />}
    </>
  )
}
