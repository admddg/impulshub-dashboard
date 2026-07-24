'use client'

import { useEffect, useState, useCallback } from 'react'
import {
  fetchOperationsFeed,
  type OpsSection, type EventLayer, type HealthStatus, type OpsFeed, type OpsRow,
} from '@/lib/agency'
import { getMyClients, type ClientAccess } from '@/lib/access'
import { getRanges, dataDeCorteLabel, type Period, type CustomRange } from '@/lib/utils'
import PeriodSelector from '@/components/PeriodSelector'
import DataTable, { type Column } from '@/components/DataTable'
import { quando, duracao, numero, ROTULO_SAUDE, TRACO } from '@/components/agencia/format'

const POR_PAGINA = 100

const STATUS: { id: HealthStatus; label: string }[] = [
  { id: 'ok', label: 'OK' },
  { id: 'pending', label: 'Em andamento' },
  { id: 'warning', label: 'Atenção' },
  { id: 'error', label: 'Erro' },
  { id: 'info', label: 'Ignorado' },
]

const CAMADAS: { id: EventLayer; label: string }[] = [
  { id: 'raw', label: 'Bruto' },
  { id: 'normalized', label: 'Normalizado' },
  { id: 'tracking', label: 'Tracking' },
  { id: 'n8n_tracking', label: 'Tracking n8n' },
]

function texto(v: string | null | undefined) {
  return v && v.trim() !== '' ? v : TRACO
}

function Saude({ s }: { s: HealthStatus }) {
  return <span className={`ag-health h-${s}`}>{ROTULO_SAUDE[s] ?? s}</span>
}

// As três telas (Onboarding, Tracking, Sync) consomem a MESMA RPC, mudando só
// p_section. Um componente com três configurações evita três implementações
// que divergem com o tempo.
export default function OperationsFeed({
  section, titulo, subtitulo, mostrarCamadas = false, periodoPadrao = '15d',
}: {
  section: OpsSection
  titulo: string
  subtitulo: string
  mostrarCamadas?: boolean
  periodoPadrao?: Period
}) {
  const [period, setPeriod] = useState<Period>(periodoPadrao)
  const [custom, setCustom] = useState<CustomRange | null>(null)
  const [camada, setCamada] = useState<EventLayer | null>(null)
  const [status, setStatus] = useState<HealthStatus | null>(null)
  const [clienteId, setClienteId] = useState<string | null>(null)
  const [busca, setBusca] = useState('')
  const [buscaAplicada, setBuscaAplicada] = useState('')
  const [pagina, setPagina] = useState(0)

  const [clientes, setClientes] = useState<ClientAccess[]>([])
  const [feed, setFeed] = useState<OpsFeed | null>(null)
  const [carregando, setCarregando] = useState(true)
  const [erro, setErro] = useState<string | null>(null)

  useEffect(() => { getMyClients().then(setClientes) }, [])

  useEffect(() => {
    const t = setTimeout(() => { setBuscaAplicada(busca); setPagina(0) }, 400)
    return () => clearTimeout(t)
  }, [busca])

  // Qualquer mudança de filtro volta para a primeira página — senão o usuário
  // fica olhando um offset que não existe mais no novo recorte.
  useEffect(() => { setPagina(0) }, [period, custom, camada, status, clienteId])

  const carregar = useCallback(() => {
    let vivo = true
    setCarregando(true)
    setErro(null)
    const { start, end } = getRanges(period, custom ?? undefined).current

    fetchOperationsFeed({
      section,
      eventLayer: camada,
      clientId: clienteId,
      start, end,
      status,
      search: buscaAplicada,
      limit: POR_PAGINA,
      offset: pagina * POR_PAGINA,
    }).then(({ data, error }) => {
      if (!vivo) return
      if (error) { setErro(error); setCarregando(false); return }
      setFeed(data)
      setCarregando(false)
    })
    return () => { vivo = false }
  }, [section, camada, clienteId, period, custom, status, buscaAplicada, pagina])

  useEffect(() => carregar(), [carregar])

  const s = feed?.summary
  const pg = feed?.pagination
  const linhas = feed?.rows ?? []

  const colunasComuns: Column<OpsRow>[] = [
    { key: 'quando', header: 'Quando', width: 110,
      render: (r) => <span className="cell-muted">{quando(r.event_at)}</span>,
      sortValue: (r) => r.event_at ?? '' },
    { key: 'cliente', header: 'Cliente', width: 140,
      render: (r) => <span className="cell-name">{texto(r.client_name)}</span>,
      sortValue: (r) => r.client_name ?? '' },
    { key: 'saude', header: 'Status',
      render: (r) => <Saude s={r.health_status} />,
      sortValue: (r) => r.health_status },
  ]

  const porSecao: Record<OpsSection, Column<OpsRow>[]> = {
    onboarding: [
      { key: 'wf', header: 'Workflow', width: 190,
        render: (r) => <span className="cell-name">{texto(r.workflow_name)}</span>,
        sortValue: (r) => r.workflow_name ?? '' },
      { key: 'dur', header: 'Duração', align: 'right',
        render: (r) => duracao(r.duration_ms), sortValue: (r) => r.duration_ms ?? -1 },
    ],
    events_tracking: [
      { key: 'evento', header: 'Evento',
        render: (r) => <span className="cell-strong">{texto(r.event_code)}</span>,
        sortValue: (r) => r.event_code ?? '' },
      { key: 'contato', header: 'Contato', width: 150,
        render: (r) => <span className="cell-name">{texto(r.contact_name)}</span>,
        sortValue: (r) => r.contact_name ?? '' },
      { key: 'plataforma', header: 'Plataforma',
        render: (r) => <span className="cell-muted">{texto(r.platform)}</span> },
      { key: 'rota', header: 'Rota',
        render: (r) => <span className="cell-muted">{texto(r.route)}</span> },
    ],
    syncs: [
      { key: 'wf', header: 'Workflow', width: 180,
        render: (r) => <span className="cell-name">{texto(r.workflow_name)}</span>,
        sortValue: (r) => r.workflow_name ?? '' },
      { key: 'cat', header: 'Tipo', render: (r) => <span className="cell-muted">{texto(r.workflow_category)}</span> },
      { key: 'proc', header: 'Processados', align: 'right',
        render: (r) => numero(r.items_processed), sortValue: (r) => r.items_processed ?? -1 },
      { key: 'falhos', header: 'Falhas', align: 'right',
        render: (r) => numero(r.items_failed), sortValue: (r) => r.items_failed ?? -1 },
      { key: 'dur', header: 'Duração', align: 'right',
        render: (r) => duracao(r.duration_ms), sortValue: (r) => r.duration_ms ?? -1 },
    ],
  }

  const colunas: Column<OpsRow>[] = [
    ...colunasComuns.slice(0, 2),
    ...porSecao[section],
    colunasComuns[2],
    { key: 'parouem', header: 'Parou em', width: 200,
      render: (r) => <span className="cell-muted cell-name" title={r.summary ?? r.stage ?? ''}>{texto(r.stage ?? r.summary)}</span> },
  ]

  const totalPaginas = pg ? Math.max(1, Math.ceil(pg.total / POR_PAGINA)) : 1

  return (
    <>
      <div className="pagehead tight">
        <div>
          <h1>{titulo}</h1>
          <div className="sub">{subtitulo} — Dados até {dataDeCorteLabel()}</div>
        </div>
        <PeriodSelector period={period} custom={custom} onChange={(p, c) => { setPeriod(p); setCustom(c ?? null) }} />
      </div>

      {s && (
        <div className="ag-summary">
          <button className={`ag-sum ${status === null ? 'active' : ''}`} onClick={() => setStatus(null)}>
            <span className="ag-sum-num">{numero(s.total)}</span>
            <span className="ag-sum-label">Total</span>
          </button>
          {STATUS.map((st) => (
            <button
              key={st.id}
              className={`ag-sum h-${st.id} ${status === st.id ? 'active' : ''}`}
              onClick={() => setStatus(status === st.id ? null : st.id)}
            >
              <span className="ag-sum-num">{numero(s[st.id])}</span>
              <span className="ag-sum-label">{st.label}</span>
            </button>
          ))}
          <div className="ag-sum-last">Último evento: {quando(s.last_event_at)}</div>
        </div>
      )}

      {mostrarCamadas && (
        <div className="tabs">
          <button className={`tab ${camada === null ? 'active' : ''}`} onClick={() => setCamada(null)}>Todas</button>
          {CAMADAS.map((c) => (
            <button key={c.id} className={`tab ${camada === c.id ? 'active' : ''}`} onClick={() => setCamada(c.id)}>
              {c.label}
            </button>
          ))}
        </div>
      )}

      <div className="ag-toolbar">
        <div className="ag-search">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
            <circle cx="11" cy="11" r="8" /><path d="m21 21-4.35-4.35" />
          </svg>
          <input
            type="search"
            placeholder="Buscar por cliente, contato, evento, workflow ou ID"
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
          />
        </div>
        <div className="ag-toolbar-right">
          <select className="select-native" value={clienteId ?? 'all'}
            onChange={(e) => setClienteId(e.target.value === 'all' ? null : e.target.value)}>
            <option value="all">Todos os clientes</option>
            {clientes.map((c) => <option key={c.client_id} value={c.client_id}>{c.client_name}</option>)}
          </select>
        </div>
      </div>

      {carregando && <div className="state"><div className="spinner" />Carregando…</div>}

      {!carregando && erro && (
        <div className="state" style={{ flexDirection: 'column', gap: 12 }}>
          <span style={{ color: 'var(--ink-soft)', fontSize: 14 }}>Não foi possível carregar o feed.</span>
          <button className="sortbtn" style={{ border: '1px solid var(--line)' }} onClick={carregar}>Tentar novamente</button>
        </div>
      )}

      {!carregando && !erro && linhas.length === 0 && (
        <div className="table-empty">Nada registrado com esses filtros no período.</div>
      )}

      {!carregando && !erro && linhas.length > 0 && (
        <>
          <DataTable columns={colunas} rows={linhas} />
          {pg && (
            <div className="pager">
              <div className="pager-info">
                {pg.offset + 1}–{pg.offset + pg.returned} de {numero(pg.total)}
              </div>
              <div className="pager-btns">
                <button className="pager-page" disabled={pagina === 0} onClick={() => setPagina((p) => Math.max(0, p - 1))}>
                  Anterior
                </button>
                <span className="pager-info">{pagina + 1} / {totalPaginas}</span>
                <button className="pager-page" disabled={!pg.has_more} onClick={() => setPagina((p) => p + 1)}>
                  Próxima
                </button>
              </div>
            </div>
          )}
        </>
      )}
    </>
  )
}
