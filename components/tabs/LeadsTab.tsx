'use client'

import { useEffect, useState, useMemo } from 'react'
import { supabase } from '@/lib/supabase'
import { getRanges, type Period, type CustomRange } from '@/lib/utils'
import DataTable, { type Column } from '@/components/DataTable'

type LeadRow = {
  contact_id: string; full_name: string | null; phone: string | null
  attribution_platform: string | null; lead_origem: string | null
  etapa: string; etapa_ordem: number; lead_date: string | null
}

const ETAPAS = ['Todos', 'Lead', 'Primeira conversa', 'Agendado', 'Ganho', 'Perdido']
const ETAPAS_REAIS = ['Lead', 'Primeira conversa', 'Agendado', 'Ganho', 'Perdido']
const PAGE_SIZE = 50
const COLS = 'contact_id, full_name, phone, attribution_platform, lead_origem, etapa, etapa_ordem, lead_date'

function fmtData(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: '2-digit' })
}

function etapaBadgeClass(etapa: string) {
  switch (etapa) {
    case 'Ganho': return 'scale'; case 'Perdido': return 'pause'
    case 'Agendado': return 'watch'; default: return 'keep'
  }
}

function platformColor(p: string | null) {
  if (p === 'Meta Ads') return '#00313d'    // petrol
  if (p === 'Google Ads') return '#5fae95'  // mint-deep
  if (p === 'Conflito') return '#546069'    // ink-soft
  return '#8794a0'                          // ink-faint (Não atribuído)
}

export default function LeadsTab({ clientId, period, custom }: {
  clientId: string; period: Period; custom: CustomRange | null
}) {
  const [loading, setLoading] = useState(true)
  const [rows, setRows] = useState<LeadRow[]>([])
  const [filtro, setFiltro] = useState('Todos')
  const [page, setPage] = useState(0)
  const [totalCount, setTotalCount] = useState(0)
  const [counts, setCounts] = useState<Record<string, number>>({})

  const range = useMemo(() => getRanges(period, custom ?? undefined).current, [period, custom])
  const [startISO, endISO] = useMemo(() => {
    const end = new Date(range.end + 'T00:00:00')
    end.setDate(end.getDate() + 1)
    return [range.start, end.toISOString().slice(0, 10)]
  }, [range])

  useEffect(() => { setPage(0) }, [clientId, startISO, endISO, filtro])

  // pills calculados no banco — nunca dependem da página
  useEffect(() => {
    let alive = true
    Promise.all(ETAPAS_REAIS.map((etapa) =>
      supabase.from('v_client_leads_by_stage_v2')
        .select('*', { count: 'exact', head: true })
        .eq('client_id', clientId).eq('etapa', etapa)
        .gte('lead_date', startISO).lt('lead_date', endISO)
    )).then((results) => {
      if (!alive) return
      const c: Record<string, number> = {}
      let todos = 0
      results.forEach((r, i) => { const n = r.count ?? 0; c[ETAPAS_REAIS[i]] = n; todos += n })
      c.Todos = todos
      setCounts(c)
    })
    return () => { alive = false }
  }, [clientId, startISO, endISO])

  // linhas paginadas — só busca o necessário
  useEffect(() => {
    let alive = true
    setLoading(true)
    let q = supabase.from('v_client_leads_by_stage_v2')
      .select(COLS, { count: 'exact' })
      .eq('client_id', clientId)
      .gte('lead_date', startISO).lt('lead_date', endISO)
    if (filtro !== 'Todos') q = q.eq('etapa', filtro)
    q = q.order('lead_date', { ascending: false }).range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1)
    q.then(({ data, count, error }) => {
      if (!alive) return
      if (error) console.error('Erro em v_client_leads_by_stage_v2:', error.message)
      setRows((data ?? []) as LeadRow[])
      setTotalCount(count ?? 0)
      setLoading(false)
    })
    return () => { alive = false }
  }, [clientId, startISO, endISO, filtro, page])

  const totalPaginas = Math.max(1, Math.ceil(totalCount / PAGE_SIZE))
  const de = totalCount === 0 ? 0 : page * PAGE_SIZE + 1
  const ate = Math.min(totalCount, (page + 1) * PAGE_SIZE)

  const cols: Column<LeadRow>[] = [
    { key: 'full_name', header: 'Nome', render: (r) => <span className="cell-strong cell-name" title={r.full_name ?? ''}>{r.full_name || '—'}</span>, sortValue: (r) => r.full_name ?? '', width: 180 },
    { key: 'phone', header: 'Telefone', render: (r) => r.phone || <span className="cell-muted">—</span> },
    { key: 'attribution', header: 'Plataforma atribuída', render: (r) => <span className="badge keep" style={{ background: `${platformColor(r.attribution_platform)}18`, color: platformColor(r.attribution_platform) }}>{r.attribution_platform || 'Não atribuído'}</span>, sortValue: (r) => r.attribution_platform ?? '' },
    { key: 'origem', header: 'Origem informada', render: (r) => <span className="cell-muted">{r.lead_origem || '—'}</span>, sortValue: (r) => r.lead_origem ?? '' },
    { key: 'etapa', header: 'Etapa', render: (r) => <span className={`badge ${etapaBadgeClass(r.etapa)}`}>{r.etapa}</span>, sortValue: (r) => r.etapa_ordem },
    { key: 'data', header: 'Cadastro', align: 'right', render: (r) => <span className="cell-muted">{fmtData(r.lead_date)}</span>, sortValue: (r) => r.lead_date ?? '' },
  ]

  return (
    <>
      <div className="stage-pills">
        {ETAPAS.map((e) => (
          <button key={e} className={`stage-pill ${filtro === e ? 'active' : ''}`} onClick={() => setFiltro(e)}>
            {e} <span className="cnt">{counts[e] ?? 0}</span>
          </button>
        ))}
      </div>

      {loading ? <div className="state"><div className="spinner" />Carregando leads…</div> : (
        <>
          <DataTable columns={cols} rows={rows} initialSort={{ key: 'data', dir: 'desc' }} />
          <div className="pager">
            <span className="pager-info">{totalCount > 0 ? `${de}–${ate} de ${totalCount.toLocaleString('pt-BR')}` : 'Nenhum resultado'}</span>
            <div className="pager-btns">
              <button className="sortbtn" disabled={page === 0} onClick={() => setPage((p) => Math.max(0, p - 1))}>← Anterior</button>
              <span className="pager-page">Página {page + 1} de {totalPaginas}</span>
              <button className="sortbtn" disabled={page + 1 >= totalPaginas} onClick={() => setPage((p) => p + 1)}>Próxima →</button>
            </div>
          </div>
        </>
      )}

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        "Plataforma atribuída" é a metodologia técnica oficial. "Origem informada" é o campo bruto do CRM. Cada pessoa aparece na etapa mais avançada que atingiu.
      </div>
    </>
  )
}
