'use client'

import { useEffect, useState, useMemo } from 'react'
import { fetchAll } from '@/lib/data'
import { channelBucket, channelColor, entradaBucket, getRanges, type Period, type CustomRange } from '@/lib/utils'
import DataTable, { type Column } from '@/components/DataTable'

type LeadRow = {
  contact_id: string
  full_name: string | null
  phone: string | null
  channel_source: string | null
  lead_entrada: string | null
  etapa: string
  etapa_ordem: number
  data_entrada: string | null
}

const ETAPAS = ['Todos', 'Lead', 'Primeira conversa', 'Agendado', 'Ganho', 'Perdido']

function fmtData(iso: string | null) {
  if (!iso) return '—'
  const d = new Date(iso)
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: '2-digit' })
}

function etapaBadgeClass(etapa: string) {
  switch (etapa) {
    case 'Ganho': return 'scale'
    case 'Perdido': return 'pause'
    case 'Agendado': return 'watch'
    default: return 'keep'
  }
}

export default function LeadsTab({ period, custom }: { period: Period; custom: CustomRange | null }) {
  const [loading, setLoading] = useState(true)
  const [rows, setRows] = useState<LeadRow[]>([])
  const [filtro, setFiltro] = useState('Todos')

  const range = useMemo(() => getRanges(period, custom ?? undefined).current, [period, custom])

  useEffect(() => {
    let alive = true
    setLoading(true)
    fetchAll('v_client_leads_by_stage', 'contact_id, full_name, phone, channel_source, lead_entrada, etapa, etapa_ordem, data_entrada')
      .then(({ rows: data }) => {
        if (!alive) return
        setRows(data as LeadRow[])
        setLoading(false)
      })
    return () => { alive = false }
  }, [])

  // filtra por data de entrada dentro do período
  const inPeriod = useMemo(() => rows.filter((r) => {
    if (!r.data_entrada) return false
    const d = r.data_entrada.slice(0, 10)
    return d >= range.start && d <= range.end
  }), [rows, range])

  // contagem por etapa pros pills (dentro do período)
  const counts = useMemo(() => {
    const c: Record<string, number> = { Todos: inPeriod.length }
    for (const r of inPeriod) c[r.etapa] = (c[r.etapa] ?? 0) + 1
    return c
  }, [inPeriod])

  const filtered = useMemo(() => {
    const base = filtro === 'Todos' ? inPeriod : inPeriod.filter((r) => r.etapa === filtro)
    return base.slice().sort((a, b) => (b.data_entrada ?? '').localeCompare(a.data_entrada ?? ''))
  }, [inPeriod, filtro])

  const cols: Column<LeadRow>[] = [
    { key: 'full_name', header: 'Nome', render: (r) => <span className="cell-strong cell-name" title={r.full_name ?? ''}>{r.full_name || '—'}</span>, sortValue: (r) => r.full_name ?? '', width: 180 },
    { key: 'phone', header: 'Telefone', render: (r) => r.phone || <span className="cell-muted">—</span> },
    { key: 'entrada', header: 'Entrada', render: (r) => <span className="cell-muted">{entradaBucket(r.lead_entrada)}</span>, sortValue: (r) => entradaBucket(r.lead_entrada) },
    { key: 'channel', header: 'Origem', render: (r) => <span className="badge keep" style={{ background: `${channelColor(r.channel_source)}18`, color: channelColor(r.channel_source) }}>{channelBucket(r.channel_source)}</span>, sortValue: (r) => channelBucket(r.channel_source) },
    { key: 'etapa', header: 'Etapa', render: (r) => <span className={`badge ${etapaBadgeClass(r.etapa)}`}>{r.etapa}</span>, sortValue: (r) => r.etapa_ordem },
    { key: 'data', header: 'Cadastro', align: 'right', render: (r) => <span className="cell-muted">{fmtData(r.data_entrada)}</span>, sortValue: (r) => r.data_entrada ?? '' },
  ]

  if (loading) return <div className="state"><div className="spinner" />Carregando leads…</div>

  return (
    <>
      <div className="stage-pills">
        {ETAPAS.map((e) => (
          <button key={e} className={`stage-pill ${filtro === e ? 'active' : ''}`} onClick={() => setFiltro(e)}>
            {e} <span className="cnt">{counts[e] ?? 0}</span>
          </button>
        ))}
      </div>

      <DataTable columns={cols} rows={filtered} initialSort={{ key: 'data', dir: 'desc' }} />

      <div className="muted-note">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10" /><path d="M12 16v-4M12 8h.01" /></svg>
        Cada pessoa aparece na etapa mais avançada que atingiu. Use os filtros para ver quem está parado em cada fase e priorizar o atendimento.
      </div>
    </>
  )
}
