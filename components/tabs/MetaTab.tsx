'use client'

import { useEffect, useState, useMemo } from 'react'
import { fetchWindowed, fetchAll, splitByDate } from '@/lib/data'
import { num, brl, int, hiResImg, type Period, type CustomRange } from '@/lib/utils'
import DataTable, { type Column } from '@/components/DataTable'
import { HBarChart } from '@/components/Charts'
import Lightbox from '@/components/Lightbox'
import CohortNote from '@/components/CohortNote'

type Sub = 'contas' | 'campanhas' | 'criativos' | 'anuncios'

type Row = {
  key: string; name: string; account_id: string
  spend: number; conversions: number; leads: number; agendados: number
}
type CreativeRow = {
  ad_name: string; headline: string | null; account_id: string
  creative_url: string | null; image_url: string | null; thumbnail_url: string | null; video_id: string | null
  spend: number; impressions: number; clicks: number; crm_leads: number; crm_agendados: number; crm_ganhos: number; receita: number
}

const money = (v: number) => `R$ ${brl(v)}`
const cpl = (r: Row) => r.leads > 0 ? `R$ ${brl(r.spend / r.leads, 2)}` : '—'
const cpag = (r: Row) => r.agendados > 0 ? `R$ ${brl(r.spend / r.agendados, 2)}` : '—'

export default function MetaTab({ clientId, period, custom }: { clientId: string; period: Period; periodLabel: string; custom: CustomRange | null }) {
  const [sub, setSub] = useState<Sub>('contas')
  const [loading, setLoading] = useState(true)
  const [accounts, setAccounts] = useState<Row[]>([])
  const [campsRaw, setCampsRaw] = useState<Row[]>([])
  const [creatives, setCreatives] = useState<CreativeRow[]>([])
  const [accountFilter, setAccountFilter] = useState<string>('all')      // campanhas
  const [accFilterCr, setAccFilterCr] = useState<string>('all')         // criativos
  const [accFilterAd, setAccFilterAd] = useState<string>('all')         // anúncios
  const [creativeSort, setCreativeSort] = useState<'spend' | 'leads' | 'agend' | 'receita'>('spend')
  const [zoom, setZoom] = useState<{ src: string; alt: string } | null>(null)

  useEffect(() => {
    let alive = true
    setLoading(true)
    Promise.all([
      fetchWindowed('v_meta_account_daily', 'date, account_id, account_name, spend, meta_conversions, crm_leads, crm_agendados', period, clientId, 'date', custom ?? undefined),
      fetchWindowed('v_meta_campaign_daily', 'date, account_id, account_name, campaign_id, campaign_name, spend, meta_conversions, crm_leads, crm_agendados', period, clientId, 'date', custom ?? undefined),
      fetchWindowed('v_meta_creative_daily', 'date, account_id, ad_id, ad_name, headline, creative_url, image_url, thumbnail_url, video_id, spend, impressions, clicks, meta_conversions, crm_leads, crm_agendados, crm_ganhos, receita', period, clientId, 'date', custom ?? undefined),
    ]).then(([acc, camp, cr]) => {
      if (!alive) return

      const accSplit = splitByDate(acc.rows, acc.current, acc.previous)
      const amap = new Map<string, Row>()
      for (const r of accSplit.cur) {
        const a = amap.get(r.account_id) ?? { key: r.account_id, name: r.account_name ?? r.account_id, account_id: r.account_id, spend: 0, conversions: 0, leads: 0, agendados: 0 }
        a.spend += num(r.spend); a.conversions += num(r.meta_conversions); a.leads += num(r.crm_leads); a.agendados += num(r.crm_agendados)
        amap.set(r.account_id, a)
      }
      setAccounts([...amap.values()].sort((a, b) => b.spend - a.spend))


      const cmap = new Map<string, Row>()
      for (const r of splitByDate(camp.rows, camp.current, camp.previous).cur) {
        const key = `${r.account_id}|${r.campaign_name}`
        const a = cmap.get(key) ?? { key, name: r.campaign_name ?? '(sem nome)', account_id: r.account_id, spend: 0, conversions: 0, leads: 0, agendados: 0 }
        a.spend += num(r.spend); a.conversions += num(r.meta_conversions); a.leads += num(r.crm_leads); a.agendados += num(r.crm_agendados)
        cmap.set(key, a)
      }
      setCampsRaw([...cmap.values()])

      // criativos: agrega por anúncio (ad_id) dentro do período atual selecionado
      const crCur = splitByDate(cr.rows, cr.current, cr.previous).cur
      const crMap = new Map<string, CreativeRow & { _lastDate: string }>()
      for (const r of crCur) {
        const key = r.ad_id ?? r.ad_name
        const acc = crMap.get(key)
        if (!acc || r.date > acc._lastDate) {
          // nome/imagem vêm sempre do registro mais recente do período
          crMap.set(key, {
            ad_name: r.ad_name ?? '(sem nome)', headline: r.headline, account_id: r.account_id,
            creative_url: r.creative_url, image_url: r.image_url, thumbnail_url: r.thumbnail_url, video_id: r.video_id,
            spend: acc ? acc.spend : 0, impressions: acc ? acc.impressions : 0, clicks: acc ? acc.clicks : 0,
            crm_leads: acc ? acc.crm_leads : 0, crm_agendados: acc ? acc.crm_agendados : 0,
            crm_ganhos: acc ? acc.crm_ganhos : 0, receita: acc ? acc.receita : 0,
            _lastDate: r.date,
          })
        }
        const a = crMap.get(key)!
        a.spend += num(r.spend); a.impressions += num(r.impressions); a.clicks += num(r.clicks)
        a.crm_leads += num(r.crm_leads); a.crm_agendados += num(r.crm_agendados)
        a.crm_ganhos += num(r.crm_ganhos); a.receita += num(r.receita)
      }
      setCreatives([...crMap.values()].map(({ _lastDate, ...rest }) => rest))
      setLoading(false)
    })
    return () => { alive = false }
  }, [clientId, period, custom])

  // contas para os seletores (nome por id)
  const accountOptions = accounts.map((a) => ({ id: a.account_id, name: a.name }))

  const camps = useMemo(() => {
    const f = accountFilter === 'all' ? campsRaw : campsRaw.filter((c) => c.account_id === accountFilter)
    return f.sort((a, b) => b.spend - a.spend)
  }, [campsRaw, accountFilter])

  const creativesFiltered = useMemo(() => {
    const f = accFilterCr === 'all' ? creatives : creatives.filter((c) => c.account_id === accFilterCr)
    const sorters: Record<string, (a: CreativeRow, b: CreativeRow) => number> = {
      spend: (a, b) => b.spend - a.spend,
      leads: (a, b) => b.crm_leads - a.crm_leads,
      agend: (a, b) => b.crm_agendados - a.crm_agendados,
      receita: (a, b) => b.receita - a.receita,
    }
    return [...f].sort(sorters[creativeSort])
  }, [creatives, accFilterCr, creativeSort])

  const anunciosFiltered = useMemo(() => {
    const f = accFilterAd === 'all' ? creatives : creatives.filter((c) => c.account_id === accFilterAd)
    return [...f].sort((a, b) => b.spend - a.spend)
  }, [creatives, accFilterAd])

  // melhor imagem: creative_url tratada (hi-res) > image_url > thumbnail tratada
  function bestImg(c: CreativeRow): string | null {
    return hiResImg(c.creative_url) || c.image_url || hiResImg(c.thumbnail_url)
  }

  function mixCols(firstHeader: string): Column<Row>[] {
    return [
      { key: 'name', header: firstHeader, render: (r) => <span className="cell-strong cell-name" title={r.name}>{r.name}</span>, sortValue: (r) => r.name, width: 220 },
      { key: 'spend', header: 'Investido', align: 'right', render: (r) => money(r.spend), sortValue: (r) => r.spend },
      { key: 'conversions', header: 'Conversões Meta', align: 'right', render: (r) => int(r.conversions), sortValue: (r) => r.conversions },
      { key: 'leads', header: 'Leads', align: 'right', render: (r) => int(r.leads), sortValue: (r) => r.leads },
      { key: 'cpl', header: 'CPL', align: 'right', render: (r) => cpl(r), sortValue: (r) => r.leads > 0 ? r.spend / r.leads : 0 },
      { key: 'agendados', header: 'Agendam.', align: 'right', render: (r) => int(r.agendados), sortValue: (r) => r.agendados },
      { key: 'cpag', header: 'CPag', align: 'right', render: (r) => cpag(r), sortValue: (r) => r.agendados > 0 ? r.spend / r.agendados : 0 },
    ]
  }

  function totalOf(rows: Row[], firstLabel: string) {
    const t = rows.reduce((a, r) => ({ spend: a.spend + r.spend, conversions: a.conversions + r.conversions, leads: a.leads + r.leads, agendados: a.agendados + r.agendados }), { spend: 0, conversions: 0, leads: 0, agendados: 0 })
    return {
      name: firstLabel, spend: money(t.spend), conversions: int(t.conversions), leads: int(t.leads),
      cpl: t.leads > 0 ? `R$ ${brl(t.spend / t.leads, 2)}` : '—',
      agendados: int(t.agendados), cpag: t.agendados > 0 ? `R$ ${brl(t.spend / t.agendados, 2)}` : '—',
    }
  }

  // colunas da aba Anúncios (indicadores por criativo)
  const adCols: Column<CreativeRow>[] = [
    { key: 'ad_name', header: 'Anúncio', render: (r) => <span className="cell-strong cell-name" title={r.ad_name}>{r.ad_name}</span>, sortValue: (r) => r.ad_name, width: 200 },
    { key: 'spend', header: 'Investido', align: 'right', render: (r) => money(r.spend), sortValue: (r) => r.spend },
    { key: 'ctr', header: 'CTR', align: 'right', render: (r) => r.impressions > 0 ? `${((r.clicks / r.impressions) * 100).toLocaleString('pt-BR', { maximumFractionDigits: 2 })}%` : '—', sortValue: (r) => r.impressions > 0 ? r.clicks / r.impressions : 0 },
    { key: 'cpc', header: 'CPC', align: 'right', render: (r) => r.clicks > 0 ? `R$ ${brl(r.spend / r.clicks, 2)}` : '—', sortValue: (r) => r.clicks > 0 ? r.spend / r.clicks : 0 },
    { key: 'leads', header: 'Leads', align: 'right', render: (r) => int(r.crm_leads), sortValue: (r) => r.crm_leads },
    { key: 'cpl', header: 'CPL', align: 'right', render: (r) => r.crm_leads > 0 ? `R$ ${brl(r.spend / r.crm_leads, 2)}` : '—', sortValue: (r) => r.crm_leads > 0 ? r.spend / r.crm_leads : 0 },
    { key: 'agend', header: 'Agendam.', align: 'right', render: (r) => int(r.crm_agendados), sortValue: (r) => r.crm_agendados },
    { key: 'cpag', header: 'CPag', align: 'right', render: (r) => r.crm_agendados > 0 ? `R$ ${brl(r.spend / r.crm_agendados, 2)}` : '—', sortValue: (r) => r.crm_agendados > 0 ? r.spend / r.crm_agendados : 0 },
  ]

  function AccountSelect({ value, onChange }: { value: string; onChange: (v: string) => void }) {
    if (accountOptions.length <= 1) return null
    return (
      <div className="subbar">
        <span className="subbar-label">Conta:</span>
        <select className="select-native" value={value} onChange={(e) => onChange(e.target.value)}>
          <option value="all">Todas as contas</option>
          {accountOptions.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
        </select>
      </div>
    )
  }

  return (
    <>
      <CohortNote />
      <div className="tabs" style={{ marginBottom: 16 }}>
        <button className={`tab ${sub === 'contas' ? 'active' : ''}`} onClick={() => setSub('contas')}>Contas de Anúncio</button>
        <button className={`tab ${sub === 'campanhas' ? 'active' : ''}`} onClick={() => setSub('campanhas')}>Campanhas</button>
        <button className={`tab ${sub === 'anuncios' ? 'active' : ''}`} onClick={() => setSub('anuncios')}>Anúncios</button>
        <button className={`tab ${sub === 'criativos' ? 'active' : ''}`} onClick={() => setSub('criativos')}>Criativos</button>
      </div>

      {loading ? (
        <div className="state"><div className="spinner" />Carregando Meta Ads…</div>
      ) : sub === 'contas' ? (
        <>
          <div className="block">
            <div className="block-head"><span className="block-title">Leads por conta</span><span className="block-sub">Leads do CRM atribuídos a cada conta</span></div>
            <HBarChart data={accounts.map((a) => ({ label: a.name, value: a.leads, color: '#00313d' }))} fmt={(v) => int(v)} height={Math.max(accounts.length * 42, 120)} />
          </div>
          <DataTable columns={mixCols('Conta de anúncio')} rows={accounts} initialSort={{ key: 'spend', dir: 'desc' }} totalRow={totalOf(accounts, 'Total')} />
        </>
      ) : sub === 'campanhas' ? (
        <>
          <AccountSelect value={accountFilter} onChange={setAccountFilter} />
          <DataTable columns={mixCols('Campanha')} rows={camps} initialSort={{ key: 'spend', dir: 'desc' }} totalRow={totalOf(camps, 'Total')} />
        </>
      ) : sub === 'anuncios' ? (
        <>
          <AccountSelect value={accFilterAd} onChange={setAccFilterAd} />
          <DataTable columns={adCols} rows={anunciosFiltered} initialSort={{ key: 'spend', dir: 'desc' }} />
        </>
      ) : (
        <>
          <div className="subbar" style={{ justifyContent: 'space-between' }}>
            <AccountSelect value={accFilterCr} onChange={setAccFilterCr} />
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <span className="subbar-label">Ordenar:</span>
              <div className="sortbtns">
                <button className={`sortbtn ${creativeSort === 'spend' ? 'active' : ''}`} onClick={() => setCreativeSort('spend')}>Investimento</button>
                <button className={`sortbtn ${creativeSort === 'leads' ? 'active' : ''}`} onClick={() => setCreativeSort('leads')}>Leads</button>
                <button className={`sortbtn ${creativeSort === 'agend' ? 'active' : ''}`} onClick={() => setCreativeSort('agend')}>Agendam.</button>
                <button className={`sortbtn ${creativeSort === 'receita' ? 'active' : ''}`} onClick={() => setCreativeSort('receita')}>Receita</button>
              </div>
            </div>
          </div>
          <div className="creative-grid">
            {creativesFiltered.length === 0 && <div className="table-empty" style={{ gridColumn: '1/-1' }}>Nenhum criativo no período.</div>}
            {creativesFiltered.map((c, i) => {
              const img = bestImg(c)
              return (
                <div className="creative" key={i}>
                  {img
                    ? <img className="creative-img" src={img} alt={c.ad_name} loading="lazy" onClick={() => setZoom({ src: img, alt: c.ad_name })} />
                    : <div className="creative-noimg">sem imagem</div>}
                  <div className="creative-body">
                    <div className="creative-adname">{c.ad_name}</div>
                    {c.headline && <div className="creative-headline">{c.headline}</div>}
                    <div className="creative-metrics">
                      <div className="creative-metric"><div className="m-label">Investido</div><div className="m-value">R$ {brl(c.spend)}</div></div>
                      <div className="creative-metric"><div className="m-label">Leads</div><div className="m-value">{int(c.crm_leads)}</div></div>
                      <div className="creative-metric"><div className="m-label">Agendam.</div><div className="m-value">{int(c.crm_agendados)}</div></div>
                      <div className="creative-metric"><div className="m-label">Receita</div><div className="m-value">{c.receita > 0 ? `R$ ${brl(c.receita)}` : '—'}</div></div>
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
        </>
      )}

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        "Conversões Meta" é da plataforma; "Leads" e "Agendam." vêm do CRM. Na aba Criativos, clique na imagem para ampliar.
      </div>

      {zoom && <Lightbox src={zoom.src} alt={zoom.alt} onClose={() => setZoom(null)} />}
    </>
  )
}
