'use client'

import { useEffect, useState, useMemo } from 'react'
import { supabase } from '@/lib/supabase'
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
const ETAPAS_REAIS = ['Lead', 'Primeira conversa', 'Agendado', 'Ganho', 'Perdido']
const PAGE_SIZE = 50
const COLS = 'contact_id, full_name, phone, channel_source, lead_entrada, etapa, etapa_ordem, data_entrada'

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

export default function LeadsTab({ clientId, period, custom }: { clientId: string; period: Period; custom: CustomRange | null }) {
  const [loading, setLoading] = useState(true)
  const [rows, setRows] = useState<LeadRow[]>([])
  const [filtro, setFiltro] = useState('Todos')
  const [page, setPage] = useState(0)
  const [totalNaPagina, setTotalNaPagina] = useState(0)
  const [counts, setCounts] = useState<Record<string, number>>({})

  const range = useMemo(() => getRanges(period, custom ?? undefined).current, [period, custom])

  // intervalo exclusivo no fim do dia (data_entrada é timestamp, não só data)
  const [startISO, endExclusiveISO] = useMemo(() => {
    const end = new Date(range.end + 'T00:00:00')
    end.setDate(end.getDate() + 1)
    return [range.start, end.toISOString().slice(0, 10)]
  }, [range])

  // volta pra página 1 sempre que o período ou o filtro de etapa mudam
  useEffect(() => { setPage(0) }, [clientId, startISO, endExclusiveISO, filtro])

  // contagens dos pills — calculadas NO BANCO (count exact, head:true), nunca
  // dependem de quantas linhas vieram na página atual. Evita o mesmo bug de
  // truncamento que já corrigimos hoje: mesmo com filtro de data, uma
  // resposta com milhares de linhas ainda estoura o limite do Supabase —
  // por isso a contagem usa uma query própria, sem nunca puxar as linhas.
  useEffect(() => {
    let alive = true
    Promise.all(
      ETAPAS_REAIS.map((etapa) =>
        supabase.from('v_client_leads_by_stage')
          .select('*', { count: 'exact', head: true })
          .eq('client_id', clientId).eq('etapa', etapa)
          .gte('data_entrada', startISO).lt('data_entrada', endExclusiveISO)
      )
    ).then((results) => {
      if (!alive) return
      const c: Record<string, number> = {}
      let todos = 0
      results.forEach((r, i) => {
        const n = r.count ?? 0
        c[ETAPAS_REAIS[i]] = n
        todos += n
      })
      c.Todos = todos
      setCounts(c)
    })
    return () => { alive = false }
  }, [clientId, startISO, endExclusiveISO])

  // linhas da página atual — só busca o necessário (PAGE_SIZE linhas),
  // nunca a lista inteira. Imune a qualquer volume de contatos do cliente.
  useEffect(() => {
    let alive = true
    setLoading(true)

    let q = supabase.from('v_client_leads_by_stage')
      .select(COLS, { count: 'exact' })
      .eq('client_id', clientId)
      .gte('data_entrada', startISO).lt('data_entrada', endExclusiveISO)
    if (filtro !== 'Todos') q = q.eq('etapa', filtro)
    q = q.order('data_entrada', { ascending: false }).range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1)

    q.then(({ data, count, error }) => {
      if (!alive) return
      if (error) console.error('Erro em v_client_leads_by_stage:', error.message)
      setRows((data ?? []) as LeadRow[])
      setTotalNaPagina(count ?? 0)
      setLoading(false)
    })

    return () => { alive = false }
  }, [clientId, startISO, endExclusiveISO, filtro, page])

  const totalPaginas = Math.max(1, Math.ceil(totalNaPagina / PAGE_SIZE))
  const de = totalNaPagina === 0 ? 0 : page * PAGE_SIZE + 1
  const ate = Math.min(totalNaPagina, (page + 1) * PAGE_SIZE)

  const cols: Column<LeadRow>[] = [
    { key: 'full_name', header: 'Nome', render: (r) => <span className="cell-strong cell-name" title={r.full_name ?? ''}>{r.full_name || '—'}</span>, sortValue: (r) => r.full_name ?? '', width: 180 },
    { key: 'phone', header: 'Telefone', render: (r) => r.phone || <span className="cell-muted">—</span> },
    { key: 'entrada', header: 'Entrada', render: (r) => <span className="cell-muted">{entradaBucket(r.lead_entrada)}</span>, sortValue: (r) => entradaBucket(r.lead_entrada) },
    { key: 'channel', header: 'Origem', render: (r) => <span className="badge keep" style={{ background: `${channelColor(r.channel_source)}18`, color: channelColor(r.channel_source) }}>{channelBucket(r.channel_source)}</span>, sortValue: (r) => channelBucket(r.channel_source) },
    { key: 'etapa', header: 'Etapa', render: (r) => <span className={`badge ${etapaBadgeClass(r.etapa)}`}>{r.etapa}</span>, sortValue: (r) => r.etapa_ordem },
    { key: 'data', header: 'Cadastro', align: 'right', render: (r) => <span className="cell-muted">{fmtData(r.data_entrada)}</span>, sortValue: (r) => r.data_entrada ?? '' },
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

      {loading ? (
        <div className="state"><div className="spinner" />Carregando leads…</div>
      ) : (
        <>
          <DataTable columns={cols} rows={rows} initialSort={{ key: 'data', dir: 'desc' }} />

          <div className="pager">
            <span className="pager-info">
              {totalNaPagina > 0 ? `${de}–${ate} de ${totalNaPagina.toLocaleString('pt-BR')}` : 'Nenhum resultado'}
            </span>
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
        Cada pessoa aparece na etapa mais avançada que atingiu. Use os filtros para ver quem está parado em cada fase e priorizar o atendimento.
      </div>
    </>
  )
}
